import Foundation
import XCTest



@testable import JsonDataCore

@Model
private final class SortPageTestRecord {
    var name: String
    var index: Int

    init(name: String = "", index: Int = 0) {
        self.name = name
        self.index = index
    }
}

final class CrossPlatformSortAndPaginationTests: XCTestCase {
    func testSortAndPagination() throws {
        let directory = try makeTemporaryDirectory(prefix: "SortPage")
        let dbURL = directory.appendingPathComponent("db.sqlite")
        defer { try? FileManager.default.removeItem(at: directory) }

        let config = ModelConfiguration(url: dbURL)
        let container = try ModelContainer(for: SortPageTestRecord.self, configurations: config)
        let context = ModelContext(container)

        let items = [
            SortPageTestRecord(name: "A", index: 5),
            SortPageTestRecord(name: "B", index: 2),
            SortPageTestRecord(name: "C", index: 8),
            SortPageTestRecord(name: "D", index: 1),
            SortPageTestRecord(name: "E", index: 4)
        ]

        for item in items {
            context.insert(item)
        }
        try context.save()

        let readContext = ModelContext(container)

        // Test sorting ascending
        let desc1 = FetchDescriptor<SortPageTestRecord>(sortBy: [SortDescriptor(\.index)])
        let res1 = try readContext.fetch(desc1)
        XCTAssertEqual(res1.map { $0.index }, [1, 2, 4, 5, 8])

        // Test sorting descending
        let desc2 = FetchDescriptor<SortPageTestRecord>(sortBy: [SortDescriptor(\.index, order: .reverse)])
        let res2 = try readContext.fetch(desc2)
        XCTAssertEqual(res2.map { $0.index }, [8, 5, 4, 2, 1])

        // Test limit
        var desc3 = FetchDescriptor<SortPageTestRecord>(sortBy: [SortDescriptor(\.index)])
        desc3.fetchLimit = 2
        let res3 = try readContext.fetch(desc3)
        XCTAssertEqual(res3.map { $0.index }, [1, 2])

        // Test offset
        var desc4 = FetchDescriptor<SortPageTestRecord>(sortBy: [SortDescriptor(\.index)])
        desc4.fetchOffset = 2
        let res4 = try readContext.fetch(desc4)
        XCTAssertEqual(res4.map { $0.index }, [4, 5, 8])

        // Test limit and offset combined
        var desc5 = FetchDescriptor<SortPageTestRecord>(sortBy: [SortDescriptor(\.index)])
        desc5.fetchOffset = 1
        desc5.fetchLimit = 2
        let res5 = try readContext.fetch(desc5)
        XCTAssertEqual(res5.map { $0.index }, [2, 4])
    }

    private func makeTemporaryDirectory(prefix: String) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(prefix)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
}
