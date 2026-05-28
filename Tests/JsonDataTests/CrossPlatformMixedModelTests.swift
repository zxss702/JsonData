import Foundation
import XCTest



@testable import JsonDataCore

struct RoleItem: Codable, Equatable {
    var id: Int
    var roleName: String
}

enum StatusEnum: String, Codable, Equatable {
    case active
    case inactive
    case pending
}

@Model
private final class MixedUserRecord {
    @Attribute(.unique) var email: String
    var age: Int
    var roles: [RoleItem]
    var status: StatusEnum
    
    @Relationship(deleteRule: .cascade) var profile: MixedProfileRecord?

    init(email: String = "", age: Int = 0, roles: [RoleItem] = [], status: StatusEnum = .active, profile: MixedProfileRecord? = nil) {
        self.email = email
        self.age = age
        self.roles = roles
        self.status = status
        self.profile = profile
    }
}

@Model
private final class MixedProfileRecord {
    var bio: String
    
    init(bio: String = "") {
        self.bio = bio
    }
}

final class CrossPlatformMixedModelTests: XCTestCase {
    func testMixedAttributesAndRelationships() throws {
        let directory = try makeTemporaryDirectory(prefix: "MixedModels")
        let dbURL = directory.appendingPathComponent("db.sqlite")
        defer { try? FileManager.default.removeItem(at: directory) }

        let config = ModelConfiguration(url: dbURL)
        let container = try ModelContainer(for: MixedUserRecord.self, MixedProfileRecord.self, configurations: config)
        let context = ModelContext(container)

        let profile1 = MixedProfileRecord(bio: "Hello World")
        let roles = [RoleItem(id: 1, roleName: "Admin"), RoleItem(id: 2, roleName: "User")]
        let user1 = MixedUserRecord(email: "test@example.com", age: 30, roles: roles, status: .active, profile: profile1)
        
        context.insert(profile1)
        context.insert(user1)
        try context.save()

        // 1. Test Codable types (Array of Struct, and Enum) and standard properties
        let readContext = ModelContext(container)
        let users = try readContext.fetch(FetchDescriptor<MixedUserRecord>())
        XCTAssertEqual(users.count, 1)
        let fetchedUser = try XCTUnwrap(users.first)
        
        XCTAssertEqual(fetchedUser.email, "test@example.com")
        XCTAssertEqual(fetchedUser.age, 30)
        XCTAssertEqual(fetchedUser.roles.count, 2)
        XCTAssertEqual(fetchedUser.roles[0].roleName, "Admin")
        XCTAssertEqual(fetchedUser.status, .active)

        // 2. Test Unique Constraint Upsert
        let user2 = MixedUserRecord(email: "test@example.com", age: 35, roles: [], status: .inactive, profile: nil)
        readContext.insert(user2)
        try readContext.save()
        
        let upsertCheckContext = ModelContext(container)
        let currentUsers = try upsertCheckContext.fetch(FetchDescriptor<MixedUserRecord>())
        XCTAssertEqual(currentUsers.count, 1)
        XCTAssertEqual(currentUsers.first?.age, 35) // Upserted
        XCTAssertEqual(currentUsers.first?.status, .inactive) // Upserted enum
        
        // 3. Test cascade delete relationship
        let deleteContext = ModelContext(container)
        if let _ = try deleteContext.fetch(FetchDescriptor<MixedUserRecord>()).first {
            // Note: Since upsert overrides the row, the relationship to `profile1` might be lost if SwiftData nullifies/cascades upon overwrite.
            // Let's create a fresh user to test explicit cascade deletion.
        }
        
        // Re-inserting a clean relation graph for deletion
        let profile3 = MixedProfileRecord(bio: "Delete Me")
        let user3 = MixedUserRecord(email: "delete@example.com", age: 20, roles: [], status: .pending, profile: profile3)
        deleteContext.insert(profile3)
        deleteContext.insert(user3)
        try deleteContext.save()
        
        deleteContext.delete(user3)
        try deleteContext.save()
        
        let finalContext = ModelContext(container)
        let remainingProfiles = try finalContext.fetch(FetchDescriptor<MixedProfileRecord>())
        // profile3 should be cascade deleted
        XCTAssertFalse(remainingProfiles.contains(where: { $0.bio == "Delete Me" }))
    }

    private func makeTemporaryDirectory(prefix: String) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(prefix)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
}
