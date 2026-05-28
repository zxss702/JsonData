import Foundation
import XCTest



@testable import JsonDataCore

@Model
private final class UniqueConstraintTestRecord {
    @Attribute(.unique) var uniqueKey: String
    var counter: Int

    init(uniqueKey: String = "", counter: Int = 0) {
        self.uniqueKey = uniqueKey
        self.counter = counter
    }
}

final class CrossPlatformUniqueConstraintTests: XCTestCase {
    func testUniqueConstraintUpsert() throws {
        let directory = try makeTemporaryDirectory(prefix: "UniqueConstraint")
        let dbURL = directory.appendingPathComponent("db.sqlite")
        defer { try? FileManager.default.removeItem(at: directory) }

        let config = ModelConfiguration(url: dbURL)
        let container = try ModelContainer(for: UniqueConstraintTestRecord.self, configurations: config)
        let context = ModelContext(container)

        let record1 = UniqueConstraintTestRecord(uniqueKey: "KeyA", counter: 1)
        context.insert(record1)
        try context.save()

        let record2 = UniqueConstraintTestRecord(uniqueKey: "KeyA", counter: 2)
        context.insert(record2)
        try context.save()

        let readContext = ModelContext(container)
        let all = try readContext.fetch(FetchDescriptor<UniqueConstraintTestRecord>())
        
        XCTAssertEqual(all.count, 1)
        XCTAssertEqual(all.first?.uniqueKey, "KeyA")
        // SwiftData typically performs an upsert, meaning the latest insert overrides.
        XCTAssertEqual(all.first?.counter, 2)
    }

    private func makeTemporaryDirectory(prefix: String) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(prefix)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
}
