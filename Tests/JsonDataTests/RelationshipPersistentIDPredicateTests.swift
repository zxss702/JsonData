import Foundation
import XCTest
@testable import JsonDataCore

final class RelationshipPersistentIDPredicateTests: XCTestCase {
    func testReopenedFetchScopesRowsBeforeApplyingLimit() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let container = try makeContainer(in: directory)
        let writer = container.mainContext
        writer.autosaveEnabled = false
        let selected = RestoreConversation(name: "selected")
        let other = RestoreConversation(name: "other")
        writer.insert(selected)
        writer.insert(other)
        let wanted = RestoreEvent(conversation: selected, position: 1)
        let unrelated = RestoreEvent(conversation: other, position: 2)
        writer.insert(wanted)
        writer.insert(unrelated)
        try writer.save()

        let selectedID = selected.persistentModelID
        let predicate = #Predicate<RestoreEvent> {
            $0.conversation?.persistentModelID == selectedID
        }
        // The unannotated to-one property must not depend on inverse metadata.
        XCTAssertTrue(RestoreEvent._jsonDataRelationships.isEmpty)
        let reader = ModelContext(container)
        reader.autosaveEnabled = false
        var descriptor = FetchDescriptor<RestoreEvent>(
            predicate: predicate,
            sortBy: [SortDescriptor(\.position, order: .reverse)])
        descriptor.fetchLimit = 1
        XCTAssertEqual(try reader.fetchPersistentIdentifiers(descriptor), [wanted.persistentModelID])
        let rows = try reader.fetch(descriptor)
        XCTAssertEqual(rows.map(\.persistentModelID), [wanted.persistentModelID])
        XCTAssertEqual(rows.first?.kind, .model)
    }

    func testRelationshipIDRemainsInsideORAndNOTExpressions() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let container = try makeContainer(in: directory)
        let writer = container.mainContext
        writer.autosaveEnabled = false
        let selected = RestoreConversation(name: "selected")
        let other = RestoreConversation(name: "other")
        writer.insert(selected)
        writer.insert(other)
        let wanted = RestoreEvent(conversation: selected, position: 1)
        let unrelated = RestoreEvent(conversation: other, position: 2)
        let orphan = RestoreEvent(conversation: nil, position: 3)
        for event in [wanted, unrelated, orphan] { writer.insert(event) }
        try writer.save()

        let selectedID = selected.persistentModelID
        let reader = ModelContext(container)
        reader.autosaveEnabled = false
        let either = #Predicate<RestoreEvent> {
            $0.conversation?.persistentModelID == selectedID || $0.conversation?.persistentModelID == nil
        }
        XCTAssertEqual(
            Set(try reader.fetchPersistentIdentifiers(FetchDescriptor(predicate: either))),
            Set([wanted.persistentModelID, orphan.persistentModelID]))

        let notSelected = #Predicate<RestoreEvent> {
            !($0.conversation?.persistentModelID == selectedID)
        }
        // nil == a concrete ID is false; negating it must also retain the orphan.
        XCTAssertEqual(
            Set(try reader.fetchPersistentIdentifiers(FetchDescriptor(predicate: notSelected))),
            Set([unrelated.persistentModelID, orphan.persistentModelID]))

        let hasConversation = #Predicate<RestoreEvent> {
            $0.conversation?.persistentModelID != nil
        }
        XCTAssertEqual(
            Set(try reader.fetchPersistentIdentifiers(FetchDescriptor(predicate: hasConversation))),
            Set([wanted.persistentModelID, unrelated.persistentModelID]))
    }

    @MainActor
    func testObservationDoesNotDecodeAnotherConversationsRemovedEventType() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let container = try makeContainer(in: directory)
        let writer = container.mainContext
        writer.autosaveEnabled = false
        let selected = RestoreConversation(name: "new conversation")
        let other = RestoreConversation(name: "old conversation")
        writer.insert(selected)
        writer.insert(other)
        let wanted = RestoreEvent(conversation: selected, position: 1)
        // Simulate a type that an older writer persisted and the reader removed.
        let legacy = RestoreEvent(conversation: other, position: 2, kind: .removed)
        writer.insert(wanted)
        writer.insert(legacy)
        try writer.save()

        let reader = ModelContext(container)
        reader.autosaveEnabled = false
        // Keep the unrelated object cached. Before the fix, mergeObservedRows
        // copies its undecodable kind before the in-memory predicate runs.
        let cachedLegacy = try XCTUnwrap(reader.model(for: legacy.persistentModelID) as? RestoreEvent)
        let selectedID = selected.persistentModelID
        let descriptor = FetchDescriptor<RestoreEvent>(predicate: #Predicate<RestoreEvent> {
            $0.conversation?.persistentModelID == selectedID
        })
        let received = XCTestExpectation(description: "only the selected conversation is hydrated")
        var delivered = false
        let observation = reader.startObservation(
            descriptor,
            onError: { error in
                XCTFail("Observation failed: \(error)")
                received.fulfill()
            },
            onChange: { rows in
                guard !delivered else { return }
                delivered = true
                XCTAssertEqual(rows.map(\.persistentModelID), [wanted.persistentModelID])
                XCTAssertEqual(rows.first?.kind, .model)
                received.fulfill()
            })
        defer { observation.cancel() }
        let result = await XCTWaiter.fulfillment(of: [received], timeout: 3)
        XCTAssertEqual(result, .completed)
        withExtendedLifetime(cachedLegacy) {}
    }

    private func makeDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("RelationshipPersistentID-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func makeContainer(in directory: URL) throws -> ModelContainer {
        try ModelContainer(
            for: RestoreConversation.self, RestoreEvent.self,
            configurations: ModelConfiguration(url: directory.appendingPathComponent("db.sqlite")))
    }
}

@Model
private final class RestoreConversation {
    var name: String

    init(name: String) { self.name = name }
}

@Model
private final class RestoreEvent {
    var conversation: RestoreConversation? = nil
    var position: Int
    var kind: RestoreEventKind

    init(conversation: RestoreConversation?, position: Int, kind: RestoreEventKind = .model) {
        self.conversation = conversation
        self.position = position
        self.kind = kind
    }
}

private enum RestoreEventKind: String, Codable {
    case model
    case removed

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let value = try container.decode(String.self)
        guard value == Self.model.rawValue else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Event type removed by the reader")
        }
        self = .model
    }
}
