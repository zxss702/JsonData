
import Foundation
import XCTest
@testable import JsonDataCore

final class ModelContext_sqlite_bootstrap_agent_test: XCTestCase {
    func testModelContextURLBootstrapsSQLiteStoreAndReloadsModelByID() throws {
        let directory = try makeTemporaryDirectory(prefix: "JsonDataSQLiteBootstrapAgentTests")
        let dbURL = directory.appendingPathComponent("db.sqlite")
        defer { try? FileManager.default.removeItem(at: directory) }

        let insertContext = try ModelContext(url: dbURL)
        let user = SQLiteBootstrapAgentUser(name: "A", age: 21)
        insertContext.insert(user)
        try? insertContext.save()

        XCTAssertTrue(FileManager.default.fileExists(atPath: dbURL.path))

        let reloadContext = try ModelContext(url: dbURL)
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

