#if !canImport(SwiftData)
import Foundation
import XCTest
@testable import JsonData

final class LinuxWindows_smoke_agent_test: XCTestCase {
    func testMinimalCRUDSmokeFlow() throws {
        let directory = try makeTemporaryDirectory(prefix: "JsonDataLinuxWindowsSmokeAgentTests")
        defer { try? FileManager.default.removeItem(at: directory) }

        let insertContext = ModelContext(url: directory)
        let record = LinuxWindowsSmokeAgentRecord(name: "hello")
        insertContext.insert(record)

        let readContext = ModelContext(url: directory)
        let reloaded: LinuxWindowsSmokeAgentRecord? = readContext.model(for: record.persistentModelID)
        XCTAssertEqual(reloaded?.name, "hello")

        let deleteContext = ModelContext(url: directory)
        let toDelete: LinuxWindowsSmokeAgentRecord? = deleteContext.model(for: record.persistentModelID)
        deleteContext.delete(try XCTUnwrap(toDelete))

        let verifyContext = ModelContext(url: directory)
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
#endif
