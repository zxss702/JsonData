import Foundation
import XCTest
import GRDB
@testable import JsonDataCore

final class RemovedColumnPersistenceTests: XCTestCase {
    func testNewGroupAndEasyRecordsSaveAfterMessageHistoryMovesToARelationship() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("db.sqlite")
        try createOldStore(at: url)
        let container = try openContainer(at: url)
        let context = container.mainContext
        context.autosaveEnabled = false

        let group = RetiredColumnRecord(name: "new group")
        let easy = RetiredColumnRecord(name: "new easy", aiMessage: RetiredColumnMessage())
        context.insert(group)
        context.insert(easy)
        try context.save()
        XCTAssertFalse(context.hasChanges)

        // Read through a separately opened container, rather than the writer's
        // pending inserts or identity map, to verify durable rows and relations.
        let reader = try openContainer(at: url).mainContext
        reader.autosaveEnabled = false
        let selected = "new easy"
        let rows = try reader.fetch(FetchDescriptor<RetiredColumnRecord>(
            predicate: #Predicate<RetiredColumnRecord> { $0.name == selected }))
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows.first?.persistentModelID, easy.persistentModelID)
        XCTAssertEqual(rows.first?.aiMessage?.payload, "message history")
        XCTAssertEqual(try reader.fetchPersistentIdentifiers(FetchDescriptor<RetiredColumnRecord>()).count, 3)

        let inspection = try DatabaseQueue(path: url.path)
        try inspection.read { db in
            XCTAssertEqual(Set(try db.columns(in: "RetiredColumnRecord").map(\.name)),
                           Set(["_id", "name", "aiMessage"]))
            let oldName = try String.fetchOne(db, sql: "SELECT name FROM RetiredColumnRecord WHERE _id = 'old-id'")
            XCTAssertEqual(oldName, "old record")
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM RetiredColumnRecord"), 3)
        }
    }

    func testMissingCurrentRequiredFieldStillFailsToSave() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("db.sqlite")
        try createOldStore(at: url)
        let container = try openContainer(at: url)
        let context = container.mainContext
        context.autosaveEnabled = false
        // Migration removes old columns; it must not hide a missing current
        // required field. The save fails and the change stays pending.
        context.insert(RetiredColumnRecord())
        XCTAssertThrowsError(try context.save())
        XCTAssertTrue(context.hasChanges)
    }

    private func openContainer(at url: URL) throws -> ModelContainer {
        try ModelContainer(
            for: RetiredColumnRecord.self, RetiredColumnMessage.self,
            configurations: ModelConfiguration(url: url))
    }

    private func createOldStore(at url: URL) throws {
        let queue = try DatabaseQueue(path: url.path)
        try queue.write { db in
            try db.execute(sql: """
                CREATE TABLE RetiredColumnRecord (
                    _id TEXT PRIMARY KEY NOT NULL,
                    name TEXT NOT NULL,
                    aiMessages TEXT NOT NULL,
                    items TEXT NOT NULL,
                    "order" TEXT NOT NULL,
                    retiredCount INTEGER NOT NULL,
                    retiredRatio REAL NOT NULL,
                    retiredPayload BLOB NOT NULL,
                    retiredOptional TEXT,
                    retiredDefault TEXT DEFAULT 'database default'
                );
                INSERT INTO RetiredColumnRecord VALUES (
                    'old-id', 'old record', '["old message"]', '["old item"]', '["old order"]',
                    42, 1.5, x'0102', 'preserve optional', NULL
                );
                """)
        }
    }

    private func makeDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("RemovedColumnPersistence-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
}

@Model
private final class RetiredColumnRecord {
    var name: String
    @Relationship(deleteRule: .cascade) var aiMessage: RetiredColumnMessage? = nil

    init(name: String, aiMessage: RetiredColumnMessage? = nil) {
        self.name = name
        self.aiMessage = aiMessage
    }
}

@Model
private final class RetiredColumnMessage {
    var payload: String = "message history"
}
