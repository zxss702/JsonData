import Foundation
import XCTest
@testable import JsonDataCore

// 1. Deep Nested Models
@Model
private final class Grandparent {
    var id: String
    var name: String
    
    @Relationship(deleteRule: .cascade, inverse: \Parent.grandparent)
    var parents: [Parent]
    
    init(id: String, name: String, parents: [Parent] = []) {
        self.id = id
        self.name = name
        self.parents = parents
    }
}

@Model
private final class Parent {
    var id: String
    var name: String
    var grandparent: Grandparent?
    
    @Relationship(deleteRule: .cascade, inverse: \Child.parent)
    var children: [Child]
    
    init(id: String, name: String, children: [Child] = []) {
        self.id = id
        self.name = name
        self.children = children
    }
}

@Model
private final class Child {
    var id: String
    var age: Int
    var parent: Parent?
    
    init(id: String, age: Int) {
        self.id = id
        self.age = age
    }
}

// 2. Complex Struct Mixed
struct ComplexProfile: Codable, Equatable {
    var bio: String
    var tags: [String]
    var metadata: [String: String]
    var scores: [Int]
    
    struct Settings: Codable, Equatable {
        var notificationsEnabled: Bool
        var theme: String
    }
    var settings: Settings
}

@Model
private final class UserWithComplexStruct {
    var id: String
    var profile: ComplexProfile
    
    init(id: String, profile: ComplexProfile) {
        self.id = id
        self.profile = profile
    }
}

final class CrossPlatformDeepNestingTests: XCTestCase {
    
    func testDeepModelCascadingDeletes() throws {
        let directory = try makeTemporaryDirectory(prefix: "DeepNesting")
        let dbURL = directory.appendingPathComponent("db.sqlite")
        defer { try? FileManager.default.removeItem(at: directory) }
        
        let config = ModelConfiguration(url: dbURL)
        let container = try ModelContainer(for: Grandparent.self, Parent.self, Child.self, configurations: config)
        let context = ModelContext(container)
        
        let c1 = Child(id: "c1", age: 5)
        let c2 = Child(id: "c2", age: 8)
        let c3 = Child(id: "c3", age: 10)
        
        let p1 = Parent(id: "p1", name: "Parent1", children: [c1, c2])
        let p2 = Parent(id: "p2", name: "Parent2", children: [c3])
        
        let gp = Grandparent(id: "gp1", name: "Grandparent1", parents: [p1, p2])
        
        context.insert(gp)
        try context.save()
        
        // Verify all are saved
        let readContext = ModelContext(container)
        let gpCount = try readContext.fetch(FetchDescriptor<Grandparent>()).count
        let pCount = try readContext.fetch(FetchDescriptor<Parent>()).count
        let cCount = try readContext.fetch(FetchDescriptor<Child>()).count
        
        XCTAssertEqual(gpCount, 1)
        XCTAssertEqual(pCount, 2)
        XCTAssertEqual(cCount, 3)
        
        // Cascade delete Grandparent
        let gpResult = try readContext.fetch(FetchDescriptor<Grandparent>(predicate: #Predicate<Grandparent> { $0.id == "gp1" }))
        XCTAssertEqual(gpResult.count, 1)
        
        readContext.delete(gpResult[0])
        try readContext.save()
        
        // Verify cascade deleted everything
        let finalGpCount = try readContext.fetch(FetchDescriptor<Grandparent>()).count
        let finalPCount = try readContext.fetch(FetchDescriptor<Parent>()).count
        let finalCCount = try readContext.fetch(FetchDescriptor<Child>()).count
        
        XCTAssertEqual(finalGpCount, 0, "Grandparent should be deleted")
        XCTAssertEqual(finalPCount, 0, "Parents should be cascade deleted")
        XCTAssertEqual(finalCCount, 0, "Children should be cascade deleted")
    }
    
    func testComplexStructMixedModel() throws {
        let directory = try makeTemporaryDirectory(prefix: "ComplexStruct")
        let dbURL = directory.appendingPathComponent("db.sqlite")
        defer { try? FileManager.default.removeItem(at: directory) }
        
        let config = ModelConfiguration(url: dbURL)
        let container = try ModelContainer(for: UserWithComplexStruct.self, configurations: config)
        let context = ModelContext(container)
        
        let profile = ComplexProfile(
            bio: "Hello world",
            tags: ["swift", "sqlite", "orm"],
            metadata: ["source": "app", "version": "1.0"],
            scores: [99, 100, 85],
            settings: ComplexProfile.Settings(notificationsEnabled: true, theme: "dark")
        )
        
        let user = UserWithComplexStruct(id: "user1", profile: profile)
        context.insert(user)
        try context.save()
        
        let readContext = ModelContext(container)
        let results = try readContext.fetch(FetchDescriptor<UserWithComplexStruct>())
        
        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results[0].profile, profile, "Complex Codable struct should be successfully encoded/decoded via JSON to SQLite TEXT")
    }
    
    func testDeepNestedLogicalPredicates() throws {
        let directory = try makeTemporaryDirectory(prefix: "NestedLogic")
        let dbURL = directory.appendingPathComponent("db.sqlite")
        defer { try? FileManager.default.removeItem(at: directory) }
        
        let config = ModelConfiguration(url: dbURL)
        let container = try ModelContainer(for: Child.self, configurations: config)
        let context = ModelContext(container)
        
        context.insert(Child(id: "1", age: 5))
        context.insert(Child(id: "2", age: 10))
        context.insert(Child(id: "3", age: 15))
        context.insert(Child(id: "4", age: 20))
        try context.save()
        
        let readContext = ModelContext(container)
        
        // (age > 5 && age < 20) || id == "1"
        let desc = FetchDescriptor<Child>(predicate: #Predicate<Child> { 
            ($0.age > 5 && $0.age < 20) || $0.id == "1"
        })
        let results = try readContext.fetch(desc)
        
        // Should match: id="1"(age 5), id="2"(age 10), id="3"(age 15). id="4" fails both.
        XCTAssertEqual(results.count, 3)
        let ids = results.map { $0.id }.sorted()
        XCTAssertEqual(ids, ["1", "2", "3"])
    }
    
    private func makeTemporaryDirectory(prefix: String) throws -> URL {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("\(prefix)-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        return tempDir
    }
}
