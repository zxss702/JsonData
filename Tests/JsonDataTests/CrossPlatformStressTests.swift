import Foundation
import XCTest



@testable import JsonDataCore

final class CrossPlatformStressTests: XCTestCase {
    func testBulkInsertAndFetchPerformance() throws {
        let directory = try makeTemporaryDirectory(prefix: "JsonDataStressTests")
        let dbURL = directory.appendingPathComponent("stress.sqlite")
        defer { try? FileManager.default.removeItem(at: directory) }

        let config = ModelConfiguration(url: dbURL)
        let container = try ModelContainer(for: StressRecord.self, configurations: config)
        let context = ModelContext(container)
        
        let recordCount = 5000 // For swift test stability, 5k is a solid number
        
        // 1. Bulk Insert
        let insertStart = Date()
        for i in 0..<recordCount {
            context.insert(StressRecord(index: i, title: "Item \(i)"))
        }
        try context.save()
        let insertEnd = Date()
        print("Bulk insert \(recordCount) items took \(insertEnd.timeIntervalSince(insertStart)) seconds")

        // 2. Fetch All
        let fetchContext = ModelContext(container)
        let fetchStart = Date()
        let allRecords = try fetchContext.fetch(FetchDescriptor<StressRecord>())
        let fetchEnd = Date()
        print("Fetch all \(recordCount) items took \(fetchEnd.timeIntervalSince(fetchStart)) seconds")
        
        XCTAssertEqual(allRecords.count, recordCount)
        
        // 3. Fetch with Predicate
        let predicateStart = Date()
        let descriptor = FetchDescriptor<StressRecord>(predicate: #Predicate { $0.index >= 4000 })
        let filteredRecords = try fetchContext.fetch(descriptor)
        let predicateEnd = Date()
        print("Fetch filtered items took \(predicateEnd.timeIntervalSince(predicateStart)) seconds")
        XCTAssertEqual(filteredRecords.count, 1000)
        
        // 4. Bulk Delete
        let deleteStart = Date()
        for record in allRecords {
            fetchContext.delete(record)
        }
        try fetchContext.save()
        let deleteEnd = Date()
        print("Bulk delete \(recordCount) items took \(deleteEnd.timeIntervalSince(deleteStart)) seconds")
        
        let finalCheck = try fetchContext.fetch(FetchDescriptor<StressRecord>())
        XCTAssertTrue(finalCheck.isEmpty)
    }

    private func makeTemporaryDirectory(prefix: String) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(prefix)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
}

@Model
private final class StressRecord {
    var index: Int
    var title: String

    init(index: Int, title: String) {
        self.index = index
        self.title = title
    }
}
