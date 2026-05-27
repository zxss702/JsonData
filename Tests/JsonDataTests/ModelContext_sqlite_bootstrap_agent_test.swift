#if !canImport(SwiftData)
import Foundation
import XCTest
@testable import JsonData

final class ModelContext_sqlite_bootstrap_agent_test: XCTestCase {
    func testModelContextURLBootstrapsSQLiteStoreAndReloadsModelByID() throws {
        let directory = try makeTemporaryDirectory(prefix: "JsonDataSQLiteBootstrapAgentTests")
        defer { try? FileManager.default.removeItem(at: directory) }

        let insertContext = ModelContext(url: directory)
        let user = SQLiteBootstrapAgentUser(name: "A", age: 21)
        insertContext.insert(user)

        let sqliteURL = directory.appendingPathComponent("JsonData.sqlite")
        XCTAssertTrue(FileManager.default.fileExists(atPath: sqliteURL.path))

        let reloadContext = ModelContext(url: directory)
        let reloaded: SQLiteBootstrapAgentUser? = reloadContext.model(for: user.persistentModelID)
        XCTAssertEqual(reloaded?.name, "A")
        XCTAssertEqual(reloaded?.age, 21)
    }

    private func makeTemporaryDirectory(prefix: String) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(prefix)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
}

@Model
private final class SQLiteBootstrapAgentUser {
    var name: String = ""
    var age: Int = 0

    init(name: String = "", age: Int = 0) {
        self.name = name
        self.age = age
    }
}
#endif
