import Foundation
import XCTest
#if canImport(SwiftData)
import SwiftData
#endif
@testable import JsonData

@Model
private final class PredicateTestRecord {
    var name: String
    var age: Int
    var score: Double
    var isActive: Bool

    init(name: String = "", age: Int = 0, score: Double = 0.0, isActive: Bool = false) {
        self.name = name
        self.age = age
        self.score = score
        self.isActive = isActive
    }
}

final class CrossPlatformPredicateTests: XCTestCase {
    func testPredicates() throws {
        let directory = try makeTemporaryDirectory(prefix: "Predicates")
        let dbURL = directory.appendingPathComponent("db.sqlite")
        defer { try? FileManager.default.removeItem(at: directory) }

        let config = ModelConfiguration(url: dbURL)
        let container = try ModelContainer(for: PredicateTestRecord.self, configurations: config)
        let context = ModelContext(container)

        let alice = PredicateTestRecord(name: "Alice", age: 30, score: 95.5, isActive: true)
        let bob = PredicateTestRecord(name: "Bob", age: 25, score: 82.0, isActive: false)
        let charlie = PredicateTestRecord(name: "Charlie", age: 35, score: 95.5, isActive: true)
        let diana = PredicateTestRecord(name: "Diana", age: 28, score: 88.0, isActive: true)

        context.insert(alice)
        context.insert(bob)
        context.insert(charlie)
        context.insert(diana)
        try context.save()

        let readContext = ModelContext(container)
        
        // Exact match
        let p1 = FetchDescriptor<PredicateTestRecord>(predicate: #Predicate { $0.name == "Alice" })
        let res1 = try readContext.fetch(p1)
        XCTAssertEqual(res1.count, 1)
        XCTAssertEqual(res1.first?.name, "Alice")

        // Inequality
        let p2 = FetchDescriptor<PredicateTestRecord>(predicate: #Predicate { $0.age > 28 })
        let res2 = try readContext.fetch(p2)
        XCTAssertEqual(res2.count, 2)
        let res2Names = Set(res2.map { $0.name })
        XCTAssertEqual(res2Names, ["Alice", "Charlie"])

        // Compound AND
        let p3 = FetchDescriptor<PredicateTestRecord>(predicate: #Predicate { $0.isActive && $0.score == 95.5 })
        let res3 = try readContext.fetch(p3)
        XCTAssertEqual(res3.count, 2)
        
        // Compound OR
        let p4 = FetchDescriptor<PredicateTestRecord>(predicate: #Predicate { $0.name == "Bob" || $0.age == 28 })
        let res4 = try readContext.fetch(p4)
        XCTAssertEqual(res4.count, 2)
        let res4Names = Set(res4.map { $0.name })
        XCTAssertEqual(res4Names, ["Bob", "Diana"])
        
        // Bool equality
        let p5 = FetchDescriptor<PredicateTestRecord>(predicate: #Predicate { $0.isActive == false })
        let res5 = try readContext.fetch(p5)
        XCTAssertEqual(res5.count, 1)
        XCTAssertEqual(res5.first?.name, "Bob")
        
        // String .contains
        let p6 = FetchDescriptor<PredicateTestRecord>(predicate: #Predicate { $0.name.contains("li") })
        let res6 = try readContext.fetch(p6)
        XCTAssertEqual(res6.count, 2)
        XCTAssertEqual(Set(res6.map { $0.name }), ["Alice", "Charlie"])
        
        // String .hasPrefix
        let p7 = FetchDescriptor<PredicateTestRecord>(predicate: #Predicate { $0.name.starts(with: "D") })
        let res7 = try readContext.fetch(p7)
        XCTAssertEqual(res7.count, 1)
        XCTAssertEqual(res7.first?.name, "Diana")
        
        // String .hasSuffix
        let p8 = FetchDescriptor<PredicateTestRecord>(predicate: #Predicate { $0.name.contains("b") })
        let res8 = try readContext.fetch(p8)
        XCTAssertEqual(res8.count, 1)
        XCTAssertEqual(res8.first?.name, "Bob")
    }

    private func makeTemporaryDirectory(prefix: String) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(prefix)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
}
