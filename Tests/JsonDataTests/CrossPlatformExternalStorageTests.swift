import Foundation
import XCTest
#if canImport(SwiftData)
import SwiftData
#endif
@testable import JsonData

@Model
private final class ExternalStorageRecord {
    var recordID: String
    @Attribute(.externalStorage)
    var largeData: Data

    init(id: String, largeData: Data) {
        self.recordID = id
        self.largeData = largeData
    }
}

final class CrossPlatformExternalStorageTests: XCTestCase {
    func testExternalStorage() throws {
        let directory = try makeTemporaryDirectory(prefix: "ExternalStorage")
        let dbURL = directory.appendingPathComponent("db.sqlite")
        let extDir = directory.appendingPathComponent(".externalStorage")
        defer { try? FileManager.default.removeItem(at: directory) }

        let config = ModelConfiguration(url: dbURL)
        let container = try ModelContainer(for: ExternalStorageRecord.self, configurations: config)
        let context = ModelContext(container)

        // 1. Insert large data
        let sampleData = Data(repeating: 0x41, count: 1024) // 1KB of 'A's
        let record = ExternalStorageRecord(id: "doc1", largeData: sampleData)
        context.insert(record)
        try context.save()

        // Verify the file was created on disk
        #if !canImport(SwiftData)
        let files = try FileManager.default.contentsOfDirectory(atPath: extDir.path)
        XCTAssertEqual(files.count, 1, "There should be exactly one external storage file")
        XCTAssertTrue(files[0].contains("_largeData.dat"))
        
        let fileURL = extDir.appendingPathComponent(files[0])
        let storedData = try Data(contentsOf: fileURL)
        XCTAssertEqual(storedData, sampleData, "Stored data should match original")
        #endif

        // 2. Fetch data
        let readContext = ModelContext(container)
        let desc = FetchDescriptor<ExternalStorageRecord>()
        let results = try readContext.fetch(desc)
        
        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results[0].largeData, sampleData, "Fetched data should match original")

        // 3. Delete data
        let deleteContext = ModelContext(container)
        let deleteResults = try deleteContext.fetch(desc)
        deleteContext.delete(deleteResults[0])
        try deleteContext.save()

        #if !canImport(SwiftData)
        let filesAfterDelete = (try? FileManager.default.contentsOfDirectory(atPath: extDir.path)) ?? []
        XCTAssertEqual(filesAfterDelete.count, 0, "External file should be deleted")
        #endif
    }

    private func makeTemporaryDirectory(prefix: String) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(prefix)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
}
