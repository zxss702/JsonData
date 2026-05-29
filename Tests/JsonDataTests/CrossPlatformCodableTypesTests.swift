import Foundation
import XCTest



@testable import JsonDataCore

final class CrossPlatformCodableTypesTests: XCTestCase {
    func testCustomCodableTypesAndEnums() throws {
        let directory = try makeTemporaryDirectory(prefix: "JsonDataCodableTests")
        let dbURL = directory.appendingPathComponent("db.sqlite")
        defer { try? FileManager.default.removeItem(at: directory) }

        let config = ModelConfiguration(url: dbURL)
        let container = try ModelContainer(for: CustomTypesRecord.self, configurations: config)
        let context = ModelContext(container)
        
        let record = CustomTypesRecord(
            status: .active,
            settings: SettingsStruct(theme: "Dark", notificationsEnabled: true),
            url: URL(string: "https://example.com")!,
            data: "hello".data(using: .utf8)!,
            uuid: UUID()
        )
        
        context.insert(record)
        try context.save()
        
        let fetchContext = ModelContext(container)
        let descriptor = FetchDescriptor<CustomTypesRecord>()
        let results = try fetchContext.fetch(descriptor)
        
        XCTAssertEqual(results.count, 1)

        if let fetched = results.first {
            XCTAssertEqual(fetched.status, .active)
            XCTAssertEqual(fetched.settings.theme, "Dark")
            XCTAssertEqual(fetched.settings.notificationsEnabled, true)
            XCTAssertEqual(fetched.url.absoluteString, "https://example.com")
            XCTAssertEqual(String(data: fetched.data, encoding: .utf8), "hello")
            XCTAssertEqual(fetched.uuid, record.uuid)
        }
    }

    private func makeTemporaryDirectory(prefix: String) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(prefix)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
}

enum CustomStatus: String, Codable {
    case pending
    case active
    case suspended
}

struct SettingsStruct: Codable {
    var theme: String
    var notificationsEnabled: Bool
}

@Model
private final class CustomTypesRecord {
    var status: CustomStatus
    var settings: SettingsStruct
    var url: URL
    var data: Data
    var uuid: UUID

    init(status: CustomStatus, settings: SettingsStruct, url: URL, data: Data, uuid: UUID) {
        self.status = status
        self.settings = settings
        self.url = url
        self.data = data
        self.uuid = uuid
    }
}
