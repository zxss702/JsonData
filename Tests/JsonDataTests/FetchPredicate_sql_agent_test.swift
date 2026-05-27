#if !canImport(SwiftData)
import Foundation
import XCTest
@testable import JsonData

final class FetchPredicate_sql_agent_test: XCTestCase {
    func testFetchWithPredicateReturnsOnlyMatchingRowAndPlainFetchReturnsFaults() throws {
        let directory = try makeTemporaryDirectory(prefix: "JsonDataFetchPredicateSQLAgentTests")
        defer { try? FileManager.default.removeItem(at: directory) }

        let insertContext = ModelContext(url: directory)
        let alice = FetchPredicateAgentUser(name: "A", age: 21)
        insertContext.insert(alice)
        insertContext.insert(FetchPredicateAgentUser(name: "B", age: 17))
        insertContext.insert(FetchPredicateAgentUser(name: "A", age: 15))

        let predicateContext = ModelContext(url: directory)
        let descriptor = FetchDescriptor<FetchPredicateAgentUser>(
            predicate: #Predicate<FetchPredicateAgentUser> { $0.age > 18 && $0.name == "A" }
        )
        let matches = try predicateContext.fetch(descriptor)
        XCTAssertEqual(matches.count, 1)
        XCTAssertEqual(matches.first?.persistentModelID, alice.persistentModelID)

        let plainFetchContext = ModelContext(url: directory)
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
