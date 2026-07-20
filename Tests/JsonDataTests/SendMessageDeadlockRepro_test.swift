import Foundation
import XCTest
@testable import JsonDataCore

// Reproduction of Logorythia "send message freezes" on Windows.
//
// Mirrors the real shape:
//  - A URL-backed ModelContainer whose mainContext is used on the main thread
//    (SwiftTUI @Query fetch + flushSwiftDataIfNeeded → mainContext.save()).
//  - A @ModelActor-style global actor (DatabaseActor) that shares the SAME
//    databaseQueue and performs the writes triggered by sendMessageToAI.
//  - A to-many relationship with an inverse (like broadcastEvents / userEvent),
//    mutated repeatedly, which triggers inverse sync + autosave on every append.
//  - A membership observation started on the main thread (like @Query).
//
// A watchdog thread force-exits the process if the run does not finish, so a
// deadlock surfaces as a clear non-zero exit instead of hanging the test host.

@Model
final class ReproRecord {
    var name: String = ""
    @Relationship(deleteRule: .cascade, inverse: \ReproEvent.record) var events: [ReproEvent]
    init(name: String = "", events: [ReproEvent] = []) {
        self.name = name
        self.events = events
    }
}

nonisolated(unsafe) var reproContainer: ModelContainer! = nil

@globalActor
@ModelActor
actor ReproDBActor: GlobalActor {
    static let shared: ReproDBActor = ReproDBActor(modelContainer: reproContainer)

    @ReproDBActor
    static func run<T: Sendable>(_ action: @ReproDBActor (ModelContext) throws -> T) rethrows -> T {
        let context = shared.modelExecutor.modelContext
        let result = try action(context)
        if context.hasChanges { try? context.save() }
        return result
    }

    @ReproDBActor
    @discardableResult
    static func run<T: Sendable>(id: PersistentIdentifier, _ action: @ReproDBActor (ReproRecord) throws -> T) rethrows -> T? {
        let context = shared.modelExecutor.modelContext
        guard let model = context.model(for: id) as? ReproRecord else { return nil }
        let result = try action(model)
        if context.hasChanges { try? context.save() }
        return result
    }
}

final class SendMessageDeadlockRepro_test: XCTestCase {
    func testConcurrentActorWritesAndMainFetchDoNotDeadlock() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SendMsgRepro-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let dbURL = directory.appendingPathComponent("db.sqlite")

        let container = try ModelContainer(
            for: ReproRecord.self, ReproEvent.self,
            configurations: ModelConfiguration(url: dbURL)
        )
        reproContainer = container

        // Watchdog: if we deadlock, don't hang the CI host forever.
        let watchdog = Thread {
            Thread.sleep(forTimeInterval: 25)
            FileHandle.standardError.write(Data("DEADLOCK: repro did not finish in 25s\n".utf8))
            exit(97)
        }
        watchdog.start()

        // Simulate @Query on the main thread as faithfully as possible:
        //  - membership observation whose onChange re-fetches + refreshCachedModels
        //  - a contextDidChange NotificationCenter observer that also re-fetches
        //  - a full-model observation (startObservation) like some views use
        let mainContext = container.mainContext
        nonisolated(unsafe) var cachedIDs: [PersistentIdentifier] = []
        let cancellable = await MainActor.run {
            mainContext.startMembershipObservation(
                FetchDescriptor<ReproRecord>(),
                onError: { _ in },
                onChange: { _ in
                    Task { @MainActor in
                        let items = (try? mainContext.fetch(FetchDescriptor<ReproRecord>())) ?? []
                        cachedIDs = items.map(\.persistentModelID)
                        mainContext.refreshCachedModels(ids: cachedIDs)
                        // Mirror @Query reading event rows + faulting relationship.
                        for r in items { _ = r.events.count }
                    }
                }
            )
        }
        defer { cancellable.cancel() }

        // NOTE: startObservation (full observe) intentionally omitted — the app's
        // @Query only uses startMembershipObservation. This isolates whether the
        // membership + refreshCachedModels + relationship-read path alone deadlocks.
        let noteToken = NotificationCenter.default.addObserver(
            forName: ModelContext.contextDidChange, object: nil, queue: .main
        ) { _ in
            Task { @MainActor in
                _ = try? mainContext.fetch(FetchDescriptor<ReproEvent>())
            }
        }
        defer { NotificationCenter.default.removeObserver(noteToken) }

        // Simulate sendMessageToAI: create a record from the actor.
        let recordID = await ReproDBActor.run { context -> PersistentIdentifier in
            let record = ReproRecord(name: "chat")
            context.insert(record)
            try? context.save()
            return record.persistentModelID
        }

        // Concurrently: actor keeps appending events (writes) like
        // r.userEvent.append(...) / r.broadcastEvents.append(...); main keeps
        // fetching + saving (like flushSwiftDataIfNeeded + @Query render).
        async let writer: Void = {
            for i in 0..<50 {
                await ReproDBActor.run(id: recordID) { (r: ReproRecord) in
                    r.events.append(ReproEvent(content: "event-\(i)"))
                    r.name = "chat-\(i)"
                }
            }
        }()

        async let mainSide: Void = {
            for _ in 0..<50 {
                await MainActor.run {
                    _ = try? mainContext.fetch(FetchDescriptor<ReproRecord>())
                    if mainContext.hasChanges { try? mainContext.save() }
                }
                try? await Task.sleep(for: .milliseconds(2))
            }
        }()

        _ = await writer
        _ = await mainSide

        // Final consistency check on the main thread.
        let count = await MainActor.run {
            (try? mainContext.fetch(FetchDescriptor<ReproEvent>()))?.count ?? -1
        }
        XCTAssertGreaterThanOrEqual(count, 0)
    }
}
