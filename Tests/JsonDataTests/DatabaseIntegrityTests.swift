import Foundation
import XCTest
@testable import JsonDataCore

@Model
private final class IntegrityTestRecord {
    var name: String = ""

    init(name: String = "") {
        self.name = name
    }
}

final class DatabaseIntegrityTests: XCTestCase {
    func testCorruptedDatabaseThrowsOnOpen() throws {
        let directory = try makeTemporaryDirectory(prefix: "JsonDataIntegrityTests")
        let dbURL = directory.appendingPathComponent("db.sqlite")
        defer { try? FileManager.default.removeItem(at: directory) }

        do {
            let goodContext = try ModelContext(url: dbURL)
            goodContext.insert(IntegrityTestRecord(name: "ok"))
            try goodContext.save()
        }

        let data = try Data(contentsOf: dbURL)
        let truncated = data.prefix(data.count / 2)
        try truncated.write(to: dbURL)

        XCTAssertThrowsError(try ModelContext(url: dbURL)) { error in
            switch error {
            case JsonDataStoreError.databaseIntegrityFailed, JsonDataStoreError.databaseOpenFailed:
                break
            default:
                XCTFail("Expected database integrity/open failure, got \(error)")
            }
        }
    }

    func testCorruptedDatabasePreventsModelContainerBootstrap() throws {
        let directory = try makeTemporaryDirectory(prefix: "JsonDataIntegrityContainerTests")
        let dbURL = directory.appendingPathComponent("db.sqlite")
        defer { try? FileManager.default.removeItem(at: directory) }

        do {
            let goodContext = try ModelContext(url: dbURL)
            goodContext.insert(IntegrityTestRecord(name: "ok"))
            try goodContext.save()
        }

        let data = try Data(contentsOf: dbURL)
        let truncated = data.prefix(data.count / 2)
        try truncated.write(to: dbURL)

        XCTAssertThrowsError(
            try ModelContainer(for: [IntegrityTestRecord.self], at: dbURL)
        ) { error in
            switch error {
            case JsonDataStoreError.databaseIntegrityFailed, JsonDataStoreError.databaseOpenFailed:
                break
            default:
                XCTFail("Expected database integrity/open failure, got \(error)")
            }
        }
    }

    private func makeTemporaryDirectory(prefix: String) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(prefix)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
}
