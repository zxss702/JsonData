import XCTest

@testable import JsonDataCore



@Model
private final class IndexUniqueRecord {
    #Index<IndexUniqueRecord>([\.firstName], [\.lastName, \.age])
    #Unique<IndexUniqueRecord>([\.email])
    var firstName: String
    var lastName: String
    var age: Int
    var email: String

    init(firstName: String, lastName: String, age: Int, email: String) {
        self.firstName = firstName
        self.lastName = lastName
        self.age = age
        self.email = email
    }
}

final class CrossPlatformIndexUniqueTests: XCTestCase {
    private func makeTemporaryDirectory(prefix: String) throws -> URL {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("\(prefix)-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        return tempDir
    }

    func testIndexAndUniqueMacros() throws {
        let directory = try makeTemporaryDirectory(prefix: "IndexUnique")
        let dbURL = directory.appendingPathComponent("db.sqlite")
        defer { try? FileManager.default.removeItem(at: directory) }
        
        let config = ModelConfiguration(url: dbURL)
        let container = try ModelContainer(for: IndexUniqueRecord.self, configurations: config)
        let context = ModelContext(container)
        
        let rec1 = IndexUniqueRecord(firstName: "John", lastName: "Doe", age: 30, email: "john@example.com")
        context.insert(rec1)
        
        let rec2 = IndexUniqueRecord(firstName: "Jane", lastName: "Doe", age: 25, email: "jane@example.com")
        context.insert(rec2)
        
        // On Linux, the SQLite schema should successfully create indexes and unique constraints.
        // We can test Unique constraint by attempting to insert another record with the same email.
        let rec3 = IndexUniqueRecord(firstName: "Duplicate", lastName: "Email", age: 40, email: "john@example.com")
        context.insert(rec3)
        
        try? context.save()
        
        let req = FetchDescriptor<IndexUniqueRecord>(predicate: #Predicate { $0.email == "john@example.com" })
        let fetched = try context.fetch(req)
        XCTAssertEqual(fetched.count, 1)
    }
}

