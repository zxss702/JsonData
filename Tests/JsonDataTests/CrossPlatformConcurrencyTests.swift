import Foundation
import XCTest



@testable import JsonDataCore

final class CrossPlatformConcurrencyTests: XCTestCase {
    func testConcurrentReadsAndWrites() throws {
        let directory = try makeTemporaryDirectory(prefix: "JsonDataConcurrencyTests")
        let dbURL = directory.appendingPathComponent("db.sqlite")
        defer { try? FileManager.default.removeItem(at: directory) }

        let config = ModelConfiguration(url: dbURL)
        let container = try ModelContainer(for: ConcurrencyRecord.self, configurations: config)
        
        // Populate initially
        let initContext = ModelContext(container)
        initContext.insert(ConcurrencyRecord(counter: 0))
        try initContext.save()
        
        let expectation = XCTestExpectation(description: "Concurrent operations completed")
        expectation.expectedFulfillmentCount = 10
        
        let dispatchQueue = DispatchQueue(label: "com.jsondata.test.concurrency", attributes: .concurrent)
        
        for i in 1...10 {
            dispatchQueue.async {
                do {
                    let context = ModelContext(container)
                    // Write
                    context.insert(ConcurrencyRecord(counter: i))
                    try context.save()
                    
                    // Read
                    let descriptor = FetchDescriptor<ConcurrencyRecord>()
                    let _ = try context.fetch(descriptor)
                } catch {
                    XCTFail("Concurrency error: \(error)")
                }
                expectation.fulfill()
            }
        }
        
        wait(for: [expectation], timeout: 10.0)
        
        // Verify final count
        let finalContext = ModelContext(container)
        let total = try finalContext.fetch(FetchDescriptor<ConcurrencyRecord>())
        XCTAssertEqual(total.count, 11) // 1 init + 10 async
    }

    private func makeTemporaryDirectory(prefix: String) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(prefix)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
}

@Model
private final class ConcurrencyRecord {
    var counter: Int

    init(counter: Int) {
        self.counter = counter
    }
}
