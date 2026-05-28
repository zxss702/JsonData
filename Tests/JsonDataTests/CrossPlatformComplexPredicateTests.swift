import Foundation
import XCTest



@testable import JsonDataCore

final class CrossPlatformComplexPredicateTests: XCTestCase {
    func testComplexLogicalCombinations() throws {
        let directory = try makeTemporaryDirectory(prefix: "JsonDataComplexPredicateTests")
        let dbURL = directory.appendingPathComponent("db.sqlite")
        defer { try? FileManager.default.removeItem(at: directory) }

        let config = ModelConfiguration(url: dbURL)
        let container = try ModelContainer(for: ComplexPredicateRecord.self, configurations: config)
        let context = ModelContext(container)
        
        context.insert(ComplexPredicateRecord(name: "Apple", count: 10, isActive: true))
        context.insert(ComplexPredicateRecord(name: "Banana", count: 20, isActive: false))
        context.insert(ComplexPredicateRecord(name: "Apricot", count: 30, isActive: true))
        context.insert(ComplexPredicateRecord(name: "Orange", count: 40, isActive: true))
        
        try context.save()
        
        // Test AND / OR combination
        let descriptor1 = FetchDescriptor<ComplexPredicateRecord>(
            predicate: #Predicate { ($0.name.starts(with: "Ap") && $0.isActive) || $0.count == 40 }
        )
        let results1 = try context.fetch(descriptor1)
        XCTAssertEqual(results1.count, 3) // Apple, Apricot, Orange
        
        // Test String operations
        let descriptor2 = FetchDescriptor<ComplexPredicateRecord>(
            predicate: #Predicate { $0.name.contains("ana") }
        )
        let results2 = try context.fetch(descriptor2)
        XCTAssertEqual(results2.count, 1)
        XCTAssertEqual(results2.first?.name, "Banana")
        
        // Test Nested logic
        let descriptor3 = FetchDescriptor<ComplexPredicateRecord>(
            predicate: #Predicate { !($0.count > 15) }
        )
        let results3 = try context.fetch(descriptor3)
        XCTAssertEqual(results3.count, 1) // Apple
    }

    private func makeTemporaryDirectory(prefix: String) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(prefix)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
}

@Model
private final class ComplexPredicateRecord {
    var name: String
    var count: Int
    var isActive: Bool

    init(name: String, count: Int, isActive: Bool) {
        self.name = name
        self.count = count
        self.isActive = isActive
    }
}
