import Foundation
import XCTest
@testable import JsonDataCore

/// Regression: child contexts from `ModelContext(container)` / `@ModelActor` must
/// inherit schema so non-generic `model(for:)` (used as `as? ConcreteType`) works.
final class ModelContext_container_schema_bootstrap_test: XCTestCase {
    func testChildContextNonGenericModelForUsesBootstrappedSchema() throws {
        let directory = try makeTemporaryDirectory(prefix: "JsonDataContainerSchemaBootstrap")
        let dbURL = directory.appendingPathComponent("db.sqlite")
        defer { try? FileManager.default.removeItem(at: directory) }

        let config = ModelConfiguration(url: dbURL)
        let container = try ModelContainer(
            for: ContainerSchemaBootstrapRecord.self,
            configurations: config
        )

        let insertContext = ModelContext(container)
        let record = ContainerSchemaBootstrapRecord(name: "schema-ok")
        insertContext.insert(record)
        try insertContext.save()

        let childContext = ModelContext(container)
        // Force the non-generic overload (same pattern as DatabaseActor.run(id:)).
        let reloaded = childContext.model(for: record.persistentModelID) as? ContainerSchemaBootstrapRecord
        XCTAssertEqual(reloaded?.name, "schema-ok")
    }

    func testModelActorContextNonGenericModelForUsesBootstrappedSchema() async throws {
        let directory = try makeTemporaryDirectory(prefix: "JsonDataModelActorSchemaBootstrap")
        let dbURL = directory.appendingPathComponent("db.sqlite")
        defer { try? FileManager.default.removeItem(at: directory) }

        let config = ModelConfiguration(url: dbURL)
        let container = try ModelContainer(
            for: ContainerSchemaBootstrapRecord.self,
            configurations: config
        )
        let actor = ContainerSchemaBootstrapActor(modelContainer: container)
        let id = await actor.insertAndReturnID(name: "actor-schema-ok")
        let name = await actor.loadName(id: id)
        XCTAssertEqual(name, "actor-schema-ok")
    }

    private func makeTemporaryDirectory(prefix: String) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(prefix)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
}

@Model
private final class ContainerSchemaBootstrapRecord {
    var name: String = ""

    init(name: String = "") {
        self.name = name
    }
}

@ModelActor
private actor ContainerSchemaBootstrapActor {
    func insertAndReturnID(name: String) -> PersistentIdentifier {
        let record = ContainerSchemaBootstrapRecord(name: name)
        modelContext.insert(record)
        try? modelContext.save()
        return record.persistentModelID
    }

    func loadName(id: PersistentIdentifier) -> String? {
        // Same pattern as Logorythia DatabaseActor.run(id:).
        (modelContext.model(for: id) as? ContainerSchemaBootstrapRecord)?.name
    }
}
