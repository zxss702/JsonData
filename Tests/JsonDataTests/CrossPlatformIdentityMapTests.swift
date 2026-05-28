import Foundation
import XCTest
#if canImport(SwiftData)
import SwiftData
#endif
@testable import JsonData

@Model
private final class IdentityMapTestRecord {
    var title: String

    init(title: String = "") {
        self.title = title
    }
}

final class CrossPlatformIdentityMapTests: XCTestCase {
    func testIdentityMapPreservesObjectReference() throws {
        let directory = try makeTemporaryDirectory(prefix: "IdentityMap")
        let dbURL = directory.appendingPathComponent("db.sqlite")
        defer { try? FileManager.default.removeItem(at: directory) }

        let config = ModelConfiguration(url: dbURL)
        let container = try ModelContainer(for: IdentityMapTestRecord.self, configurations: config)
        let context = ModelContext(container)

        let record = IdentityMapTestRecord(title: "Initial")
        context.insert(record)
        try context.save()

        let fetchDescriptor = FetchDescriptor<IdentityMapTestRecord>()
        let results1 = try context.fetch(fetchDescriptor)
        XCTAssertEqual(results1.count, 1)

        let results2 = try context.fetch(fetchDescriptor)
        XCTAssertEqual(results2.count, 1)

        // Identity map should ensure these are the exact same object in memory
        XCTAssertTrue(results1.first === results2.first)

        // Modify via one reference
        results1.first?.title = "Updated"
        try context.save()

        // The other reference should reflect the change
        XCTAssertEqual(results2.first?.title, "Updated")
    }

    private func makeTemporaryDirectory(prefix: String) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(prefix)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
}
