
import Foundation
import XCTest
@testable import JsonDataCore

final class ModelMacro_schemaMetadata_agent_test: XCTestCase {
    func testModelMacroGeneratesPersistentSchemaMetadataAndSkipsTransientFields() {
        XCTAssertEqual(SchemaMetadataAgentNote._jsonDataTableName, "SchemaMetadataAgentNote")

        let columns = SchemaMetadataAgentNote._jsonDataColumns
        XCTAssertEqual(Set(columns.map(\.propertyName)), ["title", "age", "isActive"])
        XCTAssertEqual(Set(columns.map(\.columnName)), ["title", "age", "isActive"])

        XCTAssertEqual(column(named: "title", in: columns)?.kind, .string)
        XCTAssertEqual(column(named: "title", in: columns)?.isOptional, false)

        XCTAssertEqual(column(named: "age", in: columns)?.kind, .integer)
        XCTAssertEqual(column(named: "age", in: columns)?.isOptional, true)

        XCTAssertEqual(column(named: "isActive", in: columns)?.kind, .bool)
        XCTAssertEqual(column(named: "isActive", in: columns)?.isOptional, false)

        XCTAssertFalse(columns.contains { $0.propertyName == "cache" })
        XCTAssertEqual(SchemaMetadataAgentNote._jsonDataPropertyName(for: \SchemaMetadataAgentNote.title), "title")
        XCTAssertEqual(SchemaMetadataAgentNote._jsonDataPropertyName(for: \SchemaMetadataAgentNote.age), "age")
        XCTAssertEqual(SchemaMetadataAgentNote._jsonDataPropertyName(for: \SchemaMetadataAgentNote.isActive), "isActive")
        XCTAssertNil(SchemaMetadataAgentNote._jsonDataPropertyName(for: \SchemaMetadataAgentNote.cache))
    }

    private func column(named name: String, in columns: [_JsonDataColumnInfo]) -> _JsonDataColumnInfo? {
        columns.first { $0.propertyName == name }
    }
}

@Model
private final class SchemaMetadataAgentNote {
    var title: String = ""
    var age: Int? = nil
    var isActive: Bool = false
    @Transient var cache: String? = nil
}

