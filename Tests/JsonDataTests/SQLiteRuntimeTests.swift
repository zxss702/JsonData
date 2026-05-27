#if !canImport(SwiftData)
import Foundation
import XCTest
@testable import JsonData

final class SQLiteRuntimeTests: XCTestCase {
    func testCRUDAndPredicateFetch() throws {
        let directory = try makeTemporaryDirectory(prefix: "JsonDataSQLiteRuntimeTests")
        defer { try? FileManager.default.removeItem(at: directory) }

        let context = ModelContext(url: directory)
        let alice = RuntimeUser(name: "A", age: 21)
        let bob = RuntimeUser(name: "B", age: 17)
        let carol = RuntimeUser(name: "A", age: 15)

        context.insert(alice)
        context.insert(bob)
        context.insert(carol)

        let fetched: RuntimeUser? = context.model(for: alice.persistentModelID)
        XCTAssertEqual(fetched?.name, "A")
        XCTAssertEqual(fetched?.age, 21)

        let descriptor = FetchDescriptor<RuntimeUser>(
            predicate: #Predicate<RuntimeUser> { $0.age > 18 && $0.name == "A" }
        )
        let matches = try context.fetch(descriptor)
        XCTAssertEqual(matches.count, 1)
        XCTAssertEqual(matches.first?.persistentModelID, alice.persistentModelID)

        context.delete(alice)
        let deleted: RuntimeUser? = context.model(for: alice.persistentModelID)
        XCTAssertNil(deleted)
    }

    func testSortOffsetAndLimit() throws {
        let directory = try makeTemporaryDirectory(prefix: "JsonDataSQLiteSortTests")
        defer { try? FileManager.default.removeItem(at: directory) }

        let context = ModelContext(url: directory)
        context.insert(RuntimeUser(name: "C", age: 30))
        context.insert(RuntimeUser(name: "A", age: 10))
        context.insert(RuntimeUser(name: "B", age: 20))

        var descriptor = FetchDescriptor<RuntimeUser>(
            sortBy: [SortDescriptor(\RuntimeUser.age)]
        )
        descriptor.fetchOffset = 1
        descriptor.fetchLimit = 1

        let page = try context.fetch(descriptor)
        XCTAssertEqual(page.count, 1)
        XCTAssertEqual(page.first?.age, 20)
        XCTAssertEqual(page.first?.name, "B")
    }

    private func makeTemporaryDirectory(prefix: String) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(prefix)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
}

@Model
private final class RuntimeUser {
    var name: String = ""
    var age: Int = 0

    init(name: String = "", age: Int = 0) {
        self.name = name
        self.age = age
    }
}
#endif
