import Foundation
import XCTest



@testable import JsonDataCore

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
    
    func testChildToOneAssignsParentToMany() throws {
        let (context, cleanup) = try makeContext()
        defer { cleanup() }
        
        let owner = Owner(name: "Alice")
        let pet = Pet(name: "Fluffy")
        context.insert(owner)
        context.insert(pet)
        
        pet.owner = owner
        
        XCTAssertEqual(owner.pets.count, 1)
        XCTAssertEqual(owner.pets.first?.persistentModelID, pet.persistentModelID)
        XCTAssertEqual(pet.owner?.persistentModelID, owner.persistentModelID)
    }
    
    func testChildToOneNilRemovesFromParentToMany() throws {
        let (context, cleanup) = try makeContext()
        defer { cleanup() }
        
        let owner = Owner(name: "Alice")
        let pet = Pet(name: "Fluffy")
        context.insert(owner)
        context.insert(pet)
        
        pet.owner = owner
        XCTAssertEqual(owner.pets.count, 1)
        
        pet.owner = nil
        XCTAssertTrue(owner.pets.isEmpty)
        XCTAssertNil(pet.owner)
    }
    
    func testChildReparentMovesBetweenToMany() throws {
        let (context, cleanup) = try makeContext()
        defer { cleanup() }
        
        let alice = Owner(name: "Alice")
        let bob = Owner(name: "Bob")
        let pet = Pet(name: "Fluffy")
        context.insert(alice)
        context.insert(bob)
        context.insert(pet)
        
        pet.owner = alice
        XCTAssertEqual(alice.pets.count, 1)
        XCTAssertTrue(bob.pets.isEmpty)
        
        pet.owner = bob
        XCTAssertTrue(alice.pets.isEmpty)
        XCTAssertEqual(bob.pets.count, 1)
        XCTAssertEqual(bob.pets.first?.persistentModelID, pet.persistentModelID)
        XCTAssertEqual(pet.owner?.persistentModelID, bob.persistentModelID)
    }
    
    func testChildAssignSameParentDoesNotDuplicate() throws {
        let (context, cleanup) = try makeContext()
        defer { cleanup() }
        
        let owner = Owner(name: "Alice")
        let pet = Pet(name: "Fluffy")
        context.insert(owner)
        context.insert(pet)
        
        pet.owner = owner
        pet.owner = owner
        XCTAssertEqual(owner.pets.count, 1)
    }
    
    func testChildAssignPersistsAcrossSave() throws {
        let directory = try makeTemporaryDirectory(prefix: "InversePersist")
        let dbURL = directory.appendingPathComponent("db.sqlite")
        defer { try? FileManager.default.removeItem(at: directory) }
        
        let config = ModelConfiguration(url: dbURL)
        let container = try ModelContainer(for: Owner.self, Pet.self, configurations: config)
        let context = ModelContext(container)
        
        let owner = Owner(name: "Alice")
        let pet = Pet(name: "Fluffy")
        context.insert(owner)
        context.insert(pet)
        pet.owner = owner
        try context.save()
        
        let ownerID = owner.persistentModelID
        let petID = pet.persistentModelID
        
        let readContext = ModelContext(container)
        let reloadedOwner: Owner? = readContext.model(for: ownerID)
        let reloadedPet: Pet? = readContext.model(for: petID)
        XCTAssertEqual(reloadedOwner?.pets.count, 1)
        XCTAssertEqual(reloadedOwner?.pets.first?.persistentModelID, petID)
        XCTAssertEqual(reloadedPet?.owner?.persistentModelID, ownerID)
    }

    private func makeContext() throws -> (ModelContext, () -> Void) {
        let directory = try makeTemporaryDirectory(prefix: "InverseTests")
        let dbURL = directory.appendingPathComponent("db.sqlite")
        let config = ModelConfiguration(url: dbURL)
        let container = try ModelContainer(for: Owner.self, Pet.self, configurations: config)
        let context = ModelContext(container)
        return (context, { try? FileManager.default.removeItem(at: directory) })
    }

    private func makeTemporaryDirectory(prefix: String) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(prefix)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
}
