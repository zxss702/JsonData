#if !canImport(SwiftData)
import Foundation
import XCTest
@testable import JsonData

final class SchemaMetadataTests: XCTestCase {
    func testModelMacroGeneratesSchemaMetadata() {
        XCTAssertEqual(MetadataNote._jsonDataTableName, "MetadataNote")

        let columns = MetadataNote._jsonDataColumns
        XCTAssertEqual(Set(columns.map { $0.propertyName }), ["name", "age", "score", "isActive", "blob", "createdAt", "identifier", "payload"])
        XCTAssertEqual(Set(columns.map { $0.columnName }), ["name", "age", "score", "isActive", "blob", "createdAt", "identifier", "payload"])
        XCTAssertFalse(columns.contains { $0.propertyName == "transientCache" })

        XCTAssertEqual(column(named: "name", in: columns)?.kind, .string)
        XCTAssertEqual(column(named: "name", in: columns)?.isOptional, false)

        XCTAssertEqual(column(named: "age", in: columns)?.kind, .integer)
        XCTAssertEqual(column(named: "age", in: columns)?.isOptional, true)

        XCTAssertEqual(column(named: "score", in: columns)?.kind, .double)
        XCTAssertEqual(column(named: "score", in: columns)?.isOptional, false)

        XCTAssertEqual(column(named: "isActive", in: columns)?.kind, .bool)
        XCTAssertEqual(column(named: "isActive", in: columns)?.isOptional, false)

        XCTAssertEqual(column(named: "blob", in: columns)?.kind, .data)
        XCTAssertEqual(column(named: "blob", in: columns)?.isOptional, true)

        XCTAssertEqual(column(named: "createdAt", in: columns)?.kind, .date)
        XCTAssertEqual(column(named: "createdAt", in: columns)?.isOptional, false)

        XCTAssertEqual(column(named: "identifier", in: columns)?.kind, .uuid)
        XCTAssertEqual(column(named: "identifier", in: columns)?.isOptional, false)

        XCTAssertEqual(column(named: "payload", in: columns)?.kind, .codableJSON)
        XCTAssertEqual(column(named: "payload", in: columns)?.isOptional, false)
    }

    private func column(named name: String, in columns: [_JsonDataColumnInfo]) -> _JsonDataColumnInfo? {
        columns.first { $0.propertyName == name }
    }
}

@Model
private final class MetadataNote {
    var name: String = ""
    var age: Int? = nil
    var score: Double = 0
    var isActive: Bool = false
    var blob: Data? = nil
    var createdAt: Date = .distantPast
    var identifier: UUID = UUID()
    var payload: [String: String] = [:]
    @Transient var transientCache: String? = nil
}
#endif
