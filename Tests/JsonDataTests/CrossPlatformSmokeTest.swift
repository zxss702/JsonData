import Foundation
import XCTest



@testable import JsonDataCore

final class CrossPlatformSmokeTest: XCTestCase {
    func testMinimalCRUDSmokeFlow() throws {
        let directory = try makeTemporaryDirectory(prefix: "JsonDataLinuxWindowsSmokeAgentTests")
        let dbURL = directory.appendingPathComponent("db.sqlite")
        defer { try? FileManager.default.removeItem(at: directory) }

        let config = ModelConfiguration(url: dbURL)
        let container = try ModelContainer(for: LinuxWindowsSmokeAgentRecord.self, configurations: config)
        let insertContext = ModelContext(container)
        let record = LinuxWindowsSmokeAgentRecord(name: "hello")
        insertContext.insert(record)
        try? insertContext.save()
        try insertContext.save()

        let readContext = ModelContext(container)
        let reloaded: LinuxWindowsSmokeAgentRecord? = readContext.model(for: record.persistentModelID)
        XCTAssertEqual(reloaded?.name, "hello")

        let deleteContext = ModelContext(container)
        let toDelete: LinuxWindowsSmokeAgentRecord? = deleteContext.model(for: record.persistentModelID)
        deleteContext.delete(try XCTUnwrap(toDelete))
        try? deleteContext.save()
        try deleteContext.save()

        let verifyContext = ModelContext(container)
        let deleted: LinuxWindowsSmokeAgentRecord? = verifyContext.model(for: record.persistentModelID)
        XCTAssertNil(deleted)
    }

    private func makeTemporaryDirectory(prefix: String) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(prefix)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
}

@Model
private final class LinuxWindowsSmokeAgentRecord {
    var name: String = ""

    init(name: String = "") {
        self.name = name
    }
}
