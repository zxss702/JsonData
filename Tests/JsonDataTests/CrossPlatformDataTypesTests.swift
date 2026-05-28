import Foundation
import XCTest



@testable import JsonDataCore

struct ComplexCodable: Codable, Equatable {
    var title: String
    var counts: [Int]
}

@Model
private final class AllDataTypesRecord {
    var stringValue: String
    var intValue: Int
    var doubleValue: Double
    var boolValue: Bool
    var uuidValue: UUID
    var dateValue: Date
    var dataValue: Data
    var codableValue: ComplexCodable

    init(
        stringValue: String = "",
        intValue: Int = 0,
        doubleValue: Double = 0.0,
        boolValue: Bool = false,
        uuidValue: UUID = UUID(),
        dateValue: Date = Date(),
        dataValue: Data = Data(),
        codableValue: ComplexCodable = ComplexCodable(title: "", counts: [])
    ) {
        self.stringValue = stringValue
        self.intValue = intValue
        self.doubleValue = doubleValue
        self.boolValue = boolValue
        self.uuidValue = uuidValue
        self.dateValue = dateValue
        self.dataValue = dataValue
        self.codableValue = codableValue
    }
}

final class CrossPlatformDataTypesTests: XCTestCase {
    func testAllDataTypesCRUD() throws {
        let directory = try makeTemporaryDirectory(prefix: "DataTypes")
        let dbURL = directory.appendingPathComponent("db.sqlite")
        defer { try? FileManager.default.removeItem(at: directory) }

        let config = ModelConfiguration(url: dbURL)
        let container = try ModelContainer(for: AllDataTypesRecord.self, configurations: config)
        let context = ModelContext(container)

        let uuid = UUID()
        let date = Date(timeIntervalSince1970: 1000000)
        let data = "Hello World".data(using: .utf8)!
        let codable = ComplexCodable(title: "Complex", counts: [1, 2, 3])

        let record = AllDataTypesRecord(
            stringValue: "String",
            intValue: 42,
            doubleValue: 3.14,
            boolValue: true,
            uuidValue: uuid,
            dateValue: date,
            dataValue: data,
            codableValue: codable
        )
        context.insert(record)
        try context.save()

        let readContext = ModelContext(container)
        let reloaded: AllDataTypesRecord? = readContext.model(for: record.persistentModelID)
        
        let unwrapped = try XCTUnwrap(reloaded)
        XCTAssertEqual(unwrapped.stringValue, "String")
        XCTAssertEqual(unwrapped.intValue, 42)
        XCTAssertEqual(unwrapped.doubleValue, 3.14)
        XCTAssertEqual(unwrapped.boolValue, true)
        XCTAssertEqual(unwrapped.uuidValue, uuid)
        XCTAssertEqual(unwrapped.dateValue.timeIntervalSince1970, date.timeIntervalSince1970, accuracy: 0.001)
        XCTAssertEqual(unwrapped.dataValue, data)
        XCTAssertEqual(unwrapped.codableValue, codable)
    }

    private func makeTemporaryDirectory(prefix: String) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(prefix)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
}
