import Foundation
import XCTest
@testable import JsonDataCore

@Model
private final class PredicateTarget {
    var id: String
    var name: String
    var age: Int
    var score: Double
    var isVerified: Bool
    var optString: String?
    
    init(id: String, name: String, age: Int, score: Double, isVerified: Bool, optString: String? = nil) {
        self.id = id
        self.name = name
        self.age = age
        self.score = score
        self.isVerified = isVerified
        self.optString = optString
    }
}

final class CrossPlatformPredicateExpansionTests: XCTestCase {
    var container: ModelContainer!
    var context: ModelContext!
    var testDir: URL!
    
    override func setUpWithError() throws {
        let fileManager = FileManager.default
        let tempDir = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try fileManager.createDirectory(at: tempDir, withIntermediateDirectories: true)
        testDir = tempDir
        container = try ModelContainer(for: [PredicateTarget.self], at: testDir.appendingPathComponent("predicates.sqlite"))
        context = container.mainContext
        
        // Insert sample data
        context.insert(PredicateTarget(id: "1", name: "Alpha", age: 10, score: 90.5, isVerified: true, optString: "HasValue"))
        context.insert(PredicateTarget(id: "2", name: "Beta", age: 20, score: 80.0, isVerified: false, optString: nil))
        context.insert(PredicateTarget(id: "3", name: "Gamma", age: 30, score: 99.9, isVerified: true, optString: "Another"))
        context.insert(PredicateTarget(id: "4", name: "Delta", age: 40, score: 50.0, isVerified: false, optString: nil))
        context.insert(PredicateTarget(id: "5", name: "Epsilon", age: 50, score: 60.5, isVerified: true, optString: "Yes"))
        try context.save()
    }
    
    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: testDir)
    }
    
    func testStringEquals() throws {
        let pred: JsonDataCore.Predicate<PredicateTarget> = #Predicate<PredicateTarget> { $0.name == "Alpha" }
        let res = try context.fetch(FetchDescriptor(predicate: pred))
        XCTAssertEqual(res.count, 1)
        XCTAssertEqual(res.first?.name, "Alpha")
    }
    
    func testStringNotEquals() throws {
        let pred: JsonDataCore.Predicate<PredicateTarget> = #Predicate<PredicateTarget> { $0.name != "Alpha" }
        let res = try context.fetch(FetchDescriptor(predicate: pred))
        XCTAssertEqual(res.count, 4)
    }
    
    func testStringContains() throws {
        let pred: JsonDataCore.Predicate<PredicateTarget> = #Predicate<PredicateTarget> { $0.name.contains("a") }
        let res = try context.fetch(FetchDescriptor(predicate: pred))
        // Alpha, Beta, Gamma, Delta contain 'a'. Epsilon doesn't.
        XCTAssertEqual(res.count, 4)
    }
    
    func testStringHasPrefix() throws {
        let pred: JsonDataCore.Predicate<PredicateTarget> = #Predicate<PredicateTarget> { $0.name.hasPrefix("Al") }
        let res = try context.fetch(FetchDescriptor(predicate: pred))
        XCTAssertEqual(res.count, 1)
    }
    
    func testStringHasSuffix() throws {
        let pred: JsonDataCore.Predicate<PredicateTarget> = #Predicate<PredicateTarget> { $0.name.hasSuffix("ta") }
        let res = try context.fetch(FetchDescriptor(predicate: pred))
        // Beta, Delta
        XCTAssertEqual(res.count, 2)
    }
    
    func testIntGreaterThan() throws {
        let pred: JsonDataCore.Predicate<PredicateTarget> = #Predicate<PredicateTarget> { $0.age > 20 }
        let res = try context.fetch(FetchDescriptor(predicate: pred))
        XCTAssertEqual(res.count, 3)
    }
    
    func testIntGreaterThanOrEqual() throws {
        let pred: JsonDataCore.Predicate<PredicateTarget> = #Predicate<PredicateTarget> { $0.age >= 20 }
        let res = try context.fetch(FetchDescriptor(predicate: pred))
        XCTAssertEqual(res.count, 4)
    }
    
    func testIntLessThan() throws {
        let pred: JsonDataCore.Predicate<PredicateTarget> = #Predicate<PredicateTarget> { $0.age < 30 }
        let res = try context.fetch(FetchDescriptor(predicate: pred))
        XCTAssertEqual(res.count, 2)
    }
    
    func testIntLessThanOrEqual() throws {
        let pred: JsonDataCore.Predicate<PredicateTarget> = #Predicate<PredicateTarget> { $0.age <= 30 }
        let res = try context.fetch(FetchDescriptor(predicate: pred))
        XCTAssertEqual(res.count, 3)
    }
    
    func testDoubleComparisons() throws {
        let pred: JsonDataCore.Predicate<PredicateTarget> = #Predicate<PredicateTarget> { $0.score > 60.5 }
        let res = try context.fetch(FetchDescriptor(predicate: pred))
        XCTAssertEqual(res.count, 3)
    }
    
    func testBoolTrue() throws {
        let pred: JsonDataCore.Predicate<PredicateTarget> = #Predicate<PredicateTarget> { $0.isVerified == true }
        let res = try context.fetch(FetchDescriptor(predicate: pred))
        XCTAssertEqual(res.count, 3)
    }
    
    func testBoolFalse() throws {
        let pred: JsonDataCore.Predicate<PredicateTarget> = #Predicate<PredicateTarget> { $0.isVerified == false }
        let res = try context.fetch(FetchDescriptor(predicate: pred))
        XCTAssertEqual(res.count, 2)
    }
    
    func testBoolNotOperator() throws {
        let pred: JsonDataCore.Predicate<PredicateTarget> = #Predicate<PredicateTarget> { !$0.isVerified }
        let res = try context.fetch(FetchDescriptor(predicate: pred))
        XCTAssertEqual(res.count, 2)
    }
    
    func testOptionalIsNil() throws {
        let pred: JsonDataCore.Predicate<PredicateTarget> = #Predicate<PredicateTarget> { $0.optString == nil }
        let res = try context.fetch(FetchDescriptor(predicate: pred))
        XCTAssertEqual(res.count, 2)
    }
    
    func testOptionalIsNotNil() throws {
        let pred: JsonDataCore.Predicate<PredicateTarget> = #Predicate<PredicateTarget> { $0.optString != nil }
        let res = try context.fetch(FetchDescriptor<PredicateTarget>(predicate: pred))
        XCTAssertEqual(res.count, 3)
    }
    
    func testCompoundAnd() throws {
        let pred: JsonDataCore.Predicate<PredicateTarget> = #Predicate<PredicateTarget> { $0.age > 10 && $0.score > 90.0 }
        let res = try context.fetch(FetchDescriptor<PredicateTarget>(predicate: pred))
        XCTAssertEqual(res.count, 1) // Gamma (30, 99.9)
    }
    
    func testCompoundOr() throws {
        let pred: JsonDataCore.Predicate<PredicateTarget> = #Predicate<PredicateTarget> { $0.age == 10 || $0.age == 50 }
        let res = try context.fetch(FetchDescriptor<PredicateTarget>(predicate: pred))
        XCTAssertEqual(res.count, 2)
    }
    
    func testCompoundComplex1() throws {
        let pred: JsonDataCore.Predicate<PredicateTarget> = #Predicate<PredicateTarget> { ($0.age < 30 && $0.isVerified == true) || ($0.age > 40 && $0.score < 70.0) }
        let res = try context.fetch(FetchDescriptor<PredicateTarget>(predicate: pred))
        // (10, true) -> Alpha
        // (50, 60.5) -> Epsilon
        XCTAssertEqual(res.count, 2)
    }
    
    func testCompoundComplex2() throws {
        let pred: JsonDataCore.Predicate<PredicateTarget> = #Predicate<PredicateTarget> { ($0.name.hasPrefix("A") || $0.name.hasPrefix("B")) && $0.isVerified == false }
        let res = try context.fetch(FetchDescriptor<PredicateTarget>(predicate: pred))
        // Beta is the only unverified starting with A or B
        XCTAssertEqual(res.count, 1)
        XCTAssertEqual(res.first?.name, "Beta")
    }
    
    func testDeepCompoundOptional() throws {
        let pred: JsonDataCore.Predicate<PredicateTarget> = #Predicate<PredicateTarget> { $0.optString != nil && $0.score > 80.0 }
        let res = try context.fetch(FetchDescriptor<PredicateTarget>(predicate: pred))
        // Alpha (90.5), Gamma (99.9)
        XCTAssertEqual(res.count, 2)
    }
}
