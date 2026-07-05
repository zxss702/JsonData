import XCTest
import JsonData

@Model
final class TestActorModel: @unchecked Sendable {
    var name: String
    
    init(name: String) {
        self.name = name
    }
}

@ModelActor
actor TestModelActor {
    func insertModel(name: String) {
        let model = TestActorModel(name: name)
        modelContext.insert(model)
        try? modelContext.save()
    }
    
    func fetchModels() -> [TestActorModel] {
        let descriptor = FetchDescriptor<TestActorModel>()
        return (try? modelContext.fetch(descriptor)) ?? []
    }
    
    func fetchModel(id: PersistentIdentifier) -> TestActorModel? {
        return self[id, as: TestActorModel.self]
    }
}

final class ModelActorTests: XCTestCase {
    func testModelActorExpansionAndFunctionality() async throws {
        let container = try ModelContainer(for: TestActorModel.self, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        
        let actor = TestModelActor(modelContainer: container)
        
        // Test basic actor execution
        await actor.insertModel(name: "Test Name")
        
        let models = await actor.fetchModels()
        XCTAssertEqual(models.count, 1)
        XCTAssertEqual(models.first?.name, "Test Name")
        
        let id = models.first!.persistentModelID
        let fetchedModel = await actor.fetchModel(id: id)
        XCTAssertNotNil(fetchedModel)
        XCTAssertEqual(fetchedModel?.name, "Test Name")
        
        // Test container and executor are accessible
        let accessibleContainer = await actor.modelContainer
        XCTAssertNotNil(accessibleContainer)
        
        let accessibleExecutor = await actor.modelExecutor
        XCTAssertNotNil(accessibleExecutor)
    }
}
