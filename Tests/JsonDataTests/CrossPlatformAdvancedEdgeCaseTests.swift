import Foundation
import XCTest
@testable import JsonDataCore

struct ComplexSettings: Codable, Equatable {
    var theme: String
    var notificationsEnabled: Bool
}

struct DeepProfile: Codable, Equatable {
    var bio: String
    var tags: [String]
    var metadata: [String: String]
    var settings: ComplexSettings
}

@Model
private final class AdvancedUser {
    var id: String
    var name: String
    var profile: DeepProfile
    var optionalTitle: String?
    var age: Int
    var score: Double
    var isActive: Bool
    
    init(id: String, name: String, profile: DeepProfile, optionalTitle: String? = nil, age: Int, score: Double, isActive: Bool) {
        self.id = id
        self.name = name
        self.profile = profile
        self.optionalTitle = optionalTitle
        self.age = age
        self.score = score
        self.isActive = isActive
    }
}

final class CrossPlatformAdvancedEdgeCaseTests: XCTestCase {
    var container: ModelContainer!
    var context: ModelContext!
    var testDir: URL!
    
    override func setUpWithError() throws {
        let fileManager = FileManager.default
        let tempDir = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try fileManager.createDirectory(at: tempDir, withIntermediateDirectories: true)
        testDir = tempDir
        
        container = try ModelContainer(for: [AdvancedUser.self], at: testDir.appendingPathComponent("advanced_test.sqlite"))
        context = container.mainContext
    }
    
    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: testDir)
    }
    
    func testComplexLogicalPredicates() throws {
        let u1 = AdvancedUser(id: "u1", name: "Alice", profile: DeepProfile(bio: "bio", tags: [], metadata: [:], settings: ComplexSettings(theme: "dark", notificationsEnabled: true)), age: 25, score: 80, isActive: true)
        let u2 = AdvancedUser(id: "u2", name: "Bob", profile: DeepProfile(bio: "bio", tags: [], metadata: [:], settings: ComplexSettings(theme: "light", notificationsEnabled: false)), age: 35, score: 90, isActive: false)
        let u3 = AdvancedUser(id: "u3", name: "Charlie", profile: DeepProfile(bio: "bio", tags: [], metadata: [:], settings: ComplexSettings(theme: "dark", notificationsEnabled: true)), age: 40, score: 50, isActive: true)
        let u4 = AdvancedUser(id: "u4", name: "Dave", profile: DeepProfile(bio: "bio", tags: [], metadata: [:], settings: ComplexSettings(theme: "light", notificationsEnabled: true)), age: 20, score: 100, isActive: true)
        
        context.insert(u1)
        context.insert(u2)
        context.insert(u3)
        context.insert(u4)
        try context.save()
        
        // Logical AND + OR
        // age > 30 AND isActive == false  --> Bob
        // OR
        // score == 100 AND isActive == true --> Dave
        let predicate1 = #Predicate<AdvancedUser> {
            ($0.age > 30 && $0.isActive == false) || ($0.score == 100.0 && $0.isActive == true)
        }
        
        let fetchDescriptor1 = FetchDescriptor<AdvancedUser>(predicate: predicate1)
        let results1 = try context.fetch(fetchDescriptor1)
        
        XCTAssertEqual(results1.count, 2)
        let names = Set(results1.map { $0.name })
        XCTAssertTrue(names.contains("Bob"))
        XCTAssertTrue(names.contains("Dave"))
    }
    
    func testComplexStructMutation() throws {
        let profile = DeepProfile(bio: "Initial Bio", tags: ["a", "b"], metadata: ["key": "val"], settings: ComplexSettings(theme: "dark", notificationsEnabled: true))
        let user = AdvancedUser(id: "u1", name: "User", profile: profile, age: 30, score: 50.0, isActive: true)
        
        context.insert(user)
        try context.save()
        
        // Fetch and mutate nested struct
        let results = try context.fetch(FetchDescriptor<AdvancedUser>())
        XCTAssertEqual(results.count, 1)
        
        let fetchedUser = results[0]
        fetchedUser.profile.settings.theme = "light"
        fetchedUser.profile.tags.append("c")
        
        try context.save()
        
        // Reload context to verify disk save
        let readContext = ModelContext(container)
        let reloadResults = try readContext.fetch(FetchDescriptor<AdvancedUser>())
        
        XCTAssertEqual(reloadResults[0].profile.settings.theme, "light")
        XCTAssertEqual(reloadResults[0].profile.tags, ["a", "b", "c"])
    }
    
    func testOptionalPredicates() throws {
        let u1 = AdvancedUser(id: "u1", name: "Alice", profile: DeepProfile(bio: "", tags: [], metadata: [:], settings: ComplexSettings(theme: "", notificationsEnabled: false)), optionalTitle: "Manager", age: 30, score: 50.0, isActive: true)
        let u2 = AdvancedUser(id: "u2", name: "Bob", profile: DeepProfile(bio: "", tags: [], metadata: [:], settings: ComplexSettings(theme: "", notificationsEnabled: false)), optionalTitle: nil, age: 40, score: 60.0, isActive: false)

        context.insert(u1)
        context.insert(u2)
        try context.save()
        
        let predicate = #Predicate<AdvancedUser> { $0.optionalTitle == nil }
        let results = try context.fetch(FetchDescriptor<AdvancedUser>(predicate: predicate))
        
        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results[0].name, "Bob")
    }
}
