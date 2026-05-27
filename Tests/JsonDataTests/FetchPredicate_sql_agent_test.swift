#if !canImport(SwiftData)
import Foundation
import XCTest
@testable import JsonData

final class FetchPredicate_sql_agent_test: XCTestCase {
    func testFetchWithPredicateReturnsOnlyMatchingRowAndPlainFetchReturnsFaults() throws {
        let directory = try makeTemporaryDirectory(prefix: "JsonDataFetchPredicateSQLAgentTests")
        let dbURL = directory.appendingPathComponent("db.sqlite")
        defer { try? FileManager.default.removeItem(at: directory) }

        let insertContext = ModelContext(url: dbURL)
        let alice = FetchPredicateAgentUser(name: "A", age: 21)
        insertContext.insert(alice)
        try? insertContext.save()
        insertContext.insert(FetchPredicateAgentUser(name: "B", age: 17))
        try? insertContext.save()
        insertContext.insert(FetchPredicateAgentUser(name: "A", age: 15))
        try? insertContext.save()

        let predicateContext = ModelContext(url: dbURL)
        let descriptor = FetchDescriptor<FetchPredicateAgentUser>(
            predicate: #Predicate<FetchPredicateAgentUser> { $0.age > 18 && $0.name == "A" }
        )
        let matches = try predicateContext.fetch(descriptor)
        XCTAssertEqual(matches.count, 1)
        XCTAssertEqual(matches.first?.persistentModelID, alice.persistentModelID)

        let plainFetchContext = ModelContext(url: dbURL)
        let all = try plainFetchContext.fetch(FetchDescriptor<FetchPredicateAgentUser>())
        XCTAssertEqual(all.count, 3)
        XCTAssertTrue(all.first?._isFault == true)
    }

    private func makeTemporaryDirectory(prefix: String) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(prefix)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
}

@Model
private final class FetchPredicateAgentUser {
    var name: String = ""
    var age: Int = 0

    init(name: String = "", age: Int = 0) {
        self.name = name
        self.age = age
    }
}
#endif
