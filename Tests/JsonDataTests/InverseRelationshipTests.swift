import Foundation
import XCTest
#if canImport(SwiftData)
import SwiftData
#endif
@testable import JsonData

@Model
private final class Owner {
    var name: String
    @Relationship(inverse: \Pet.owner) var pets: [Pet]
    
    init(name: String = "", pets: [Pet] = []) {
        self.name = name
        self.pets = pets
    }
}

@Model
private final class Pet {
    var name: String
    var owner: Owner?
    
    init(name: String = "", owner: Owner? = nil) {
        self.name = name
        self.owner = owner
    }
}

final class InverseRelationshipTests: XCTestCase {
    func testInverseRelationshipSyncing() throws {
        let directory = try makeTemporaryDirectory(prefix: "InverseTests")
        let dbURL = directory.appendingPathComponent("db.sqlite")
        defer { try? FileManager.default.removeItem(at: directory) }

        let config = ModelConfiguration(url: dbURL)
        let container = try ModelContainer(for: Owner.self, Pet.self, configurations: config)
        let context = ModelContext(container)
        
        let owner = Owner(name: "Alice")
        let pet = Pet(name: "Fluffy")
        
        context.insert(owner)
        context.insert(pet)
        
        // Test setting owner.pets which HAS the @Relationship attribute
        owner.pets = [pet]
        
        XCTAssertEqual(pet.owner?.persistentModelID, owner.persistentModelID, "Inverse should be set on pet.owner")
    }

    private func makeTemporaryDirectory(prefix: String) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(prefix)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
}
