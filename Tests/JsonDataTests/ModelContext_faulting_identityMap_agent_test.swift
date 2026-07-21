
import Foundation
import XCTest
@testable import JsonDataCore

final class ModelContext_faulting_identityMap_agent_test: XCTestCase {
    func testFetchReturnsFaultPropertyAccessFaultsInAndModelForReusesInstance() throws {
        let directory = try makeTemporaryDirectory(prefix: "JsonDataFaultingIdentityMapAgentTests")
        let dbURL = directory.appendingPathComponent("db.sqlite")
        defer { try? FileManager.default.removeItem(at: directory) }

        let insertContext = try ModelContext(url: dbURL)
        let user = FaultingIdentityAgentUser(name: "A", age: 21)
        insertContext.insert(user)
        try? insertContext.save()

        let context = try ModelContext(url: dbURL)
        let fetched = try context.fetch(FetchDescriptor<FaultingIdentityAgentUser>())
        let fault = try XCTUnwrap(fetched.first)

        XCTAssertTrue(fault._isFault)
        XCTAssertEqual(fault.name, "A")
        XCTAssertFalse(fault._isFault)

        let lookedUp: FaultingIdentityAgentUser? = context.model(for: fault.persistentModelID)
        XCTAssertTrue(lookedUp === fault)
    }

    private func makeTemporaryDirectory(prefix: String) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(prefix)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
}

@Model
private final class FaultingIdentityAgentUser {
    var name: String = ""
    var age: Int = 0

    init(name: String = "", age: Int = 0) {
        self.name = name
        self.age = age
    }
}

