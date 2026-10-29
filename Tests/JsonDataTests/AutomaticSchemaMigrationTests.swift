import Foundation
import XCTest
import GRDB
@testable import JsonDataCore

final class AutomaticSchemaMigrationTests: XCTestCase {
    func testAddedPropertiesUseDeclaredDefaultsAndOriginalColumnNames() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("db.sqlite")
        try execute(at: url, sql: """
            CREATE TABLE MigrationDefaultsRow (_id TEXT PRIMARY KEY NOT NULL, oldName TEXT NOT NULL);
            INSERT INTO MigrationDefaultsRow VALUES ('old-id', 'existing');
            """)
        let container = try ModelContainer(
            for: MigrationDefaultsRow.self, MigrationRelatedRow.self,
            configurations: ModelConfiguration(url: url))
        let context = container.mainContext
        context.autosaveEnabled = false
        let row = try XCTUnwrap(context.fetch(FetchDescriptor<MigrationDefaultsRow>()).first)
        XCTAssertEqual(row.persistentModelID.id, "old-id")
        XCTAssertEqual(row.name, "existing")
        XCTAssertEqual(row.rank, 17)
        XCTAssertTrue(row.enabled)
        XCTAssertEqual(row.ratio, 1.5)
        XCTAssertEqual(row.tags, ["default tag"])
        XCTAssertNil(row.note)
        XCTAssertTrue(row.links.isEmpty)

        let inspection = try DatabaseQueue(path: url.path)
        try inspection.read { db in
            XCTAssertFalse(try db.columns(in: "MigrationDefaultsRow").contains { $0.name == "name" })
            let index = try XCTUnwrap(db.indexes(on: "MigrationDefaultsRow").first {
                $0.name == "idx_MigrationDefaultsRow_name"
            })
            XCTAssertEqual(index.columns, ["oldName"])
        }
        // Reopening must be idempotent and retain the migrated values.
        let reopened = try ModelContainer(
            for: MigrationDefaultsRow.self, MigrationRelatedRow.self,
            configurations: ModelConfiguration(url: url))
        XCTAssertEqual(try reopened.mainContext.fetch(FetchDescriptor<MigrationDefaultsRow>()).first?.rank, 17)
    }

    func testRelaxingOptionalityRemovesTheOldNotNullConstraint() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("db.sqlite")
        try execute(at: url, sql: """
            CREATE TABLE MigrationOptionalRow (_id TEXT PRIMARY KEY NOT NULL, value TEXT NOT NULL);
            INSERT INTO MigrationOptionalRow VALUES ('old-id', 'existing');
            """)
        let container = try ModelContainer(for: MigrationOptionalRow.self,
                                           configurations: ModelConfiguration(url: url))
        let context = container.mainContext
        context.autosaveEnabled = false
        context.insert(MigrationOptionalRow())
        try context.save()
        let inspection = try DatabaseQueue(path: url.path)
        try inspection.read { db in
            XCTAssertFalse(try XCTUnwrap(db.columns(in: "MigrationOptionalRow").first {
                $0.name == "value"
            }).isNotNull)
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM MigrationOptionalRow WHERE value IS NULL"), 1)
            XCTAssertEqual(try String.fetchOne(db, sql: "SELECT value FROM MigrationOptionalRow WHERE _id = 'old-id'"), "existing")
        }
    }

    func testTighteningOptionalityUsesTheDeclaredDefaultOnlyForNullValues() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("db.sqlite")
        try execute(at: url, sql: """
            CREATE TABLE MigrationTightenedRow (_id TEXT PRIMARY KEY NOT NULL, value TEXT);
            INSERT INTO MigrationTightenedRow VALUES ('null-id', NULL), ('kept-id', 'kept');
            """)
        _ = try ModelContainer(for: MigrationTightenedRow.self,
                               configurations: ModelConfiguration(url: url))
        let inspection = try DatabaseQueue(path: url.path)
        try inspection.read { db in
            XCTAssertEqual(try String.fetchOne(db, sql: "SELECT value FROM MigrationTightenedRow WHERE _id = 'null-id'"), "declared default")
            XCTAssertEqual(try String.fetchOne(db, sql: "SELECT value FROM MigrationTightenedRow WHERE _id = 'kept-id'"), "kept")
        }
    }

    func testMissingRequiredDefaultRollsBackAllTablesAndDoesNotCacheSuccess() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("db.sqlite")
        try execute(at: url, sql: """
            CREATE TABLE MigrationDefaultsRow (_id TEXT PRIMARY KEY NOT NULL, oldName TEXT NOT NULL);
            INSERT INTO MigrationDefaultsRow VALUES ('first', 'existing');
            CREATE TABLE MigrationRequiredRow (_id TEXT PRIMARY KEY NOT NULL, name TEXT NOT NULL);
            INSERT INTO MigrationRequiredRow VALUES ('second', 'existing');
            """)
        let context = try ModelContext(url: url)
        // A second attempt on the same context must retry and throw again,
        // rather than skipping a table cached before the failed transaction.
        for _ in 0..<2 {
            XCTAssertThrowsError(try context._bootstrapSchema([
                MigrationDefaultsRow.self, MigrationRequiredRow.self
            ])) { error in
                guard case JsonDataStoreError.schemaMigrationFailed(let model, _) = error else {
                    return XCTFail("Expected migration error, got \(error)")
                }
                XCTAssertEqual(model, "MigrationRequiredRow")
                XCTAssertNotNil((error as NSError).userInfo[NSUnderlyingErrorKey])
                XCTAssertTrue(error.localizedDescription.contains("requiredValue"))
            }
        }
        let inspection = try DatabaseQueue(path: url.path)
        try inspection.read { db in
            XCTAssertEqual(Set(try db.columns(in: "MigrationDefaultsRow").map(\.name)), Set(["_id", "oldName"]))
            XCTAssertEqual(Set(try db.columns(in: "MigrationRequiredRow").map(\.name)), Set(["_id", "name"]))
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM MigrationDefaultsRow"), 1)
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM MigrationRequiredRow"), 1)
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM sqlite_master WHERE name LIKE '_jsonData_migration_%'"), 0)
        }
    }

    func testAddingUniqueConstraintFailsWithoutDiscardingDuplicates() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("db.sqlite")
        try execute(at: url, sql: """
            CREATE TABLE MigrationUniqueRow (_id TEXT PRIMARY KEY NOT NULL, name TEXT NOT NULL);
            INSERT INTO MigrationUniqueRow VALUES ('one', 'duplicate'), ('two', 'duplicate');
            """)
        XCTAssertThrowsError(try ModelContainer(for: MigrationUniqueRow.self,
                                              configurations: ModelConfiguration(url: url)))
        let inspection = try DatabaseQueue(path: url.path)
        try inspection.read { db in
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM MigrationUniqueRow"), 2)
            XCTAssertFalse(try db.indexes(on: "MigrationUniqueRow").contains {
                $0.isUnique && $0.origin != .primaryKeyConstraint
            })
        }
    }

    @MainActor
    func testObservationReportsMigrationFailureThroughOnError() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("db.sqlite")
        try execute(at: url, sql: """
            CREATE TABLE MigrationRequiredRow (_id TEXT PRIMARY KEY NOT NULL, name TEXT NOT NULL);
            INSERT INTO MigrationRequiredRow VALUES ('old-id', 'existing');
            """)
        let context = try ModelContext(url: url)
        let failed = XCTestExpectation(description: "migration error delivered")
        let observation = context.startObservation(FetchDescriptor<MigrationRequiredRow>(),
            onError: { error in
                XCTAssertTrue(error.localizedDescription.contains("requiredValue"))
                failed.fulfill()
            }, onChange: { _ in XCTFail("An incompatible schema must not produce rows") })
        defer { observation.cancel() }
        let result = await XCTWaiter.fulfillment(of: [failed], timeout: 3)
        XCTAssertEqual(result, .completed)
    }

    func testIncompatibleStorageTypeThrowsWithoutCastingExistingValues() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("db.sqlite")
        try execute(at: url, sql: """
            CREATE TABLE MigrationRequiredRow (
                _id TEXT PRIMARY KEY NOT NULL, name TEXT NOT NULL, requiredValue TEXT NOT NULL
            );
            INSERT INTO MigrationRequiredRow VALUES ('old-id', 'existing', 'not a number');
            """)
        XCTAssertThrowsError(try ModelContainer(for: MigrationRequiredRow.self,
            configurations: ModelConfiguration(url: url))) { error in
                XCTAssertTrue(error.localizedDescription.contains("incompatible storage type"))
            }
        let inspection = try DatabaseQueue(path: url.path)
        try inspection.read { db in
            XCTAssertEqual(try String.fetchOne(db, sql: "SELECT requiredValue FROM MigrationRequiredRow"), "not a number")
        }
    }

    func testFailedSaveThrowsAndAutosaveRetainsErrorAndPendingChanges() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let container = try ModelContainer(for: MigrationRequiredRow.self,
            configurations: ModelConfiguration(url: directory.appendingPathComponent("db.sqlite")))
        let context = container.mainContext
        context.autosaveEnabled = false
        let invalid = MigrationRequiredRow()
        context.insert(invalid)
        XCTAssertThrowsError(try context.save())
        XCTAssertTrue(context.hasChanges)
        let failed = XCTestExpectation(description: "automatic save failure is reported")
        let token = NotificationCenter.default.addObserver(forName: ModelContext.autosaveDidFail,
            object: context, queue: nil) { notification in
                XCTAssertNotNil(notification.userInfo?["error"] as? Error)
                failed.fulfill()
            }
        defer { NotificationCenter.default.removeObserver(token) }
        context._performExitAutosave()
        XCTAssertNotNil(context.lastAutosaveError)
        XCTAssertTrue(context.hasChanges)
        wait(for: [failed], timeout: 1)
        // Correcting the pending model allows retry; the framework must neither
        // drop the failed change nor retain a stale automatic-save error.
        invalid.name = "repaired"
        invalid.requiredValue = 42
        context._performExitAutosave()
        XCTAssertNil(context.lastAutosaveError)
        XCTAssertFalse(context.hasChanges)
    }

    func testSavePropagatesTheOriginalEncodingError() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let container = try ModelContainer(for: MigrationEncodingRow.self,
            configurations: ModelConfiguration(url: directory.appendingPathComponent("db.sqlite")))
        let context = container.mainContext
        context.autosaveEnabled = false
        context.insert(MigrationEncodingRow(payload: MigrationEncodingValue()))
        XCTAssertThrowsError(try context.save()) { error in
            XCTAssertEqual((error as NSError).domain, "IntentionalEncodingFailure")
        }
        XCTAssertTrue(context.hasChanges)
    }

    private func execute(at url: URL, sql: String) throws {
        let queue = try DatabaseQueue(path: url.path)
        try queue.write { db in try db.execute(sql: sql) }
    }

    private func makeDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AutomaticMigration-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
}

@Model
private final class MigrationDefaultsRow {
    #Index<MigrationDefaultsRow>([\.name])
    @Attribute(originalName: "oldName") var name: String
    var rank: Int = 17
    var enabled: Bool = true
    var ratio: Double = 1.5
    var tags: [String] = ["default tag"]
    var note: String? = nil
    @Relationship(deleteRule: .nullify) var links: [MigrationRelatedRow]
}

@Model
private final class MigrationRelatedRow {
    var name: String = "related"
}

@Model
private final class MigrationRequiredRow {
    var name: String
    var requiredValue: Int
}

@Model
private final class MigrationOptionalRow {
    var value: String? = nil
}

@Model
private final class MigrationTightenedRow {
    var value: String = "declared default"
}

@Model
private final class MigrationUniqueRow {
    @Attribute(.unique) var name: String
}

@Model
private final class MigrationEncodingRow {
    var payload: MigrationEncodingValue

    init(payload: MigrationEncodingValue) { self.payload = payload }
}

private struct MigrationEncodingValue: Codable {
    func encode(to encoder: Encoder) throws {
        throw NSError(domain: "IntentionalEncodingFailure", code: 1)
    }
}
