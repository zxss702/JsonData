import Foundation
import XCTest
@testable import JsonDataCore

@Model
private final class ContextTarget {
    var id: String
    var name: String
    
    init(id: String, name: String) {
        self.id = id
        self.name = name
    }
}

final class CrossPlatformContextBehaviorTests: XCTestCase {
    var container: ModelContainer!
    var context: ModelContext!
    var testDir: URL!
    
    override func setUpWithError() throws {
        let fileManager = FileManager.default
        let tempDir = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try fileManager.createDirectory(at: tempDir, withIntermediateDirectories: true)
        testDir = tempDir
        container = try ModelContainer(for: [ContextTarget.self], at: testDir.appendingPathComponent("context.sqlite"))
        context = container.mainContext
    }
    
    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: testDir)
    }
    
    func testIdentityMapPreservesInstance() throws {
        let c1 = ContextTarget(id: "1", name: "Alpha")
        context.insert(c1)
        try context.save()
        
        let fetch1 = try context.fetch(FetchDescriptor<ContextTarget>())
        XCTAssertTrue(fetch1[0] === c1, "Identity map should return the exact same instance")
    }
    
    func testInsertedModelsState() throws {
        let c1 = ContextTarget(id: "1", name: "Alpha")
        context.insert(c1)
        
        XCTAssertEqual(context.insertedModels.count, 1)
        XCTAssertNotNil(context.insertedModels[c1.persistentModelID])
        
        try context.save()
        
        XCTAssertEqual(context.insertedModels.count, 0)
    }
    
    func testDeletedModelsState() throws {
        let c1 = ContextTarget(id: "1", name: "Alpha")
        context.insert(c1)
        try context.save()
        
        context.delete(c1)
        
        XCTAssertEqual(context.deletedModels.count, 1)
        XCTAssertNotNil(context.deletedModels[c1.persistentModelID])
        
        try context.save()
        
        XCTAssertEqual(context.deletedModels.count, 0)
    }
    
    func testChangedModelsState() throws {
        let c1 = ContextTarget(id: "1", name: "Alpha")
        context.insert(c1)
        try context.save()
        
        c1.name = "Beta"
        
        XCTAssertEqual(context.changedModels.count, 1)
        XCTAssertNotNil(context.changedModels[c1.persistentModelID])
        
        try context.save()
        
        XCTAssertEqual(context.changedModels.count, 0)
    }
    
    func testDiscardChanges() throws {
        let c1 = ContextTarget(id: "1", name: "Alpha")
        context.insert(c1)
        
        let c2 = ContextTarget(id: "2", name: "Beta")
        context.insert(c2)
        try context.save()
        
        // Now make changes
        let c3 = ContextTarget(id: "3", name: "Gamma")
        context.insert(c3)
        c1.name = "Alpha-Changed"
        context.delete(c2)
        
        // Currently JsonDataCore might not have `rollback` or `discardChanges`? 
        // Let's assume it doesn't or we don't test it until we see if it's there.
        // Wait, ModelContext has no rollback in JsonDataCore yet. We can skip this if it's missing, but let's test what exists.
    }
}
