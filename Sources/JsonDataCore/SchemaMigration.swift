import Foundation
import GRDB

/// Called only inside the writer transaction. An incompatible schema must fail
/// before the container becomes usable, rather than failing on its first insert.
struct ModelSchemaMigrator {
    let modelType: any PersistentModel.Type
    let tableName: String
    let columns: [_JsonDataColumnInfo]

    func migrate(in db: Database) throws {
        let schema = modelType as? any _JsonDataSchemaProviding.Type
        let columnNames = Dictionary(uniqueKeysWithValues: columns.map { ($0.propertyName, $0.columnName) })
        let indexes = (schema?._jsonDataIndexes ?? []).map { ($0.properties, false) }
            + (schema?._jsonDataUniques ?? []).map { ($0.properties, true) }
        func indexColumns(_ properties: [String]) -> [String] {
            properties.map { columnNames[$0] ?? $0 }
        }

        if try db.tableExists(tableName) {
            let existing = try db.columns(in: tableName)
            let byName = Dictionary(uniqueKeysWithValues: existing.map { ($0.name.lowercased(), $0) })
            let desiredNames = Set(["_id"] + columns.map { $0.columnName.lowercased() })
            let actualIndexes = try db.indexes(on: tableName)
            let actualUnique = Set(actualIndexes.filter {
                $0.isUnique && $0.origin != .primaryKeyConstraint
            }.map { Set($0.columns.map { $0.lowercased() }) })
            var desiredUnique = Set(columns.filter { $0.options.contains(.unique) }.map {
                Set([$0.columnName.lowercased()])
            })
            for (properties, unique) in indexes where unique {
                desiredUnique.insert(Set(indexColumns(properties).map { $0.lowercased() }))
            }
            let needsRebuild = Set(byName.keys) != desiredNames || actualUnique != desiredUnique
                || columns.contains { column in
                    guard let old = byName[column.columnName.lowercased()] else { return true }
                    return old.isNotNull == column.isOptional
                        || old.type.uppercased() != sqlType(for: column.kind)
                }
            if needsRebuild { try rebuild(in: db, existing: byName) }
        } else {
            try db.execute(sql: createTableSQL(named: tableName))
        }

        let desiredIndexNames = Set(indexes.map { "idx_\(tableName)_\($0.0.joined(separator: "_"))" })
        for index in try db.indexes(on: tableName)
        where index.origin == .createIndex && index.name.hasPrefix("idx_\(tableName)_")
            && !desiredIndexNames.contains(index.name) {
            try db.execute(sql: "DROP INDEX \(quote(index.name))")
        }
        for (properties, unique) in indexes {
            let indexName = "idx_\(tableName)_\(properties.joined(separator: "_"))"
            let names = indexColumns(properties).map(quote).joined(separator: ", ")
            try db.execute(sql: "CREATE \(unique ? "UNIQUE " : "")INDEX IF NOT EXISTS \(quote(indexName)) ON \(quote(tableName)) (\(names))")
        }
    }

    private func rebuild(in db: Database, existing: [String: ColumnInfo]) throws {
        let rowCount = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM \(quote(tableName))") ?? 0
        let prototype = modelType.init()
        let defaults = try (prototype as? any _JsonDataSchemaProviding)?._toColumnValues(context: nil) ?? [:]
        var expressions = [quote("_id")]
        var arguments: [DatabaseValueConvertible?] = []
        for column in columns {
            let old = existing[column.columnName.lowercased()]
            let defaultValue = databaseArgument(for: defaults[column.propertyName] ?? nil)
            if let old {
                if rowCount > 0, old.type.uppercased() != sqlType(for: column.kind) {
                    throw migrationError("\(column.propertyName): incompatible storage type \(old.type) → \(sqlType(for: column.kind)); an explicit migration is required")
                }
                let source = quote(old.name)
                if !column.isOptional, !old.isNotNull,
                   try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM \(quote(tableName)) WHERE \(source) IS NULL)") == true {
                    guard let defaultValue else {
                        throw migrationError("\(column.propertyName): required destination has NULL values and no declared default")
                    }
                    expressions.append("COALESCE(\(source), ?)")
                    arguments.append(defaultValue)
                } else {
                    expressions.append(source)
                }
            } else if let defaultValue {
                expressions.append("?")
                arguments.append(defaultValue)
            } else {
                guard column.isOptional || rowCount == 0 else {
                    throw migrationError("\(column.propertyName): new required property has no declared default")
                }
                expressions.append("NULL")
            }
        }
        // Copy with normal INSERT so invalid rows or duplicate unique values
        // throw; INSERT OR REPLACE here would silently discard existing data.
        let temporary = "_jsonData_migration_" + UUID().uuidString.replacingOccurrences(of: "-", with: "")
        try db.execute(sql: createTableSQL(named: temporary))
        let destination = (["_id"] + columns.map(\.columnName)).map(quote).joined(separator: ", ")
        try db.execute(
            sql: "INSERT INTO \(quote(temporary)) (\(destination)) SELECT \(expressions.joined(separator: ", ")) FROM \(quote(tableName))",
            arguments: StatementArguments(arguments))
        try db.execute(sql: "DROP TABLE \(quote(tableName))")
        try db.execute(sql: "ALTER TABLE \(quote(temporary)) RENAME TO \(quote(tableName))")
    }

    private func createTableSQL(named name: String) -> String {
        let definitions = ["\"_id\" TEXT PRIMARY KEY NOT NULL"] + columns.map { column in
            let nullability = column.isOptional ? "" : " NOT NULL"
            let unique = column.options.contains(.unique) ? " UNIQUE" : ""
            return "\(quote(column.columnName)) \(sqlType(for: column.kind))\(nullability)\(unique)"
        }
        return "CREATE TABLE \(quote(name)) (\(definitions.joined(separator: ", ")))"
    }

    private func sqlType(for kind: _JsonDataColumnKind) -> String {
        switch kind {
        case .string, .uuid, .codableJSON, .url: return "TEXT"
        case .integer, .bool: return "INTEGER"
        case .double, .date: return "REAL"
        case .data: return "BLOB"
        }
    }

    private func databaseArgument(for value: Any?) -> DatabaseValueConvertible? {
        switch value {
        case let value as URL: return value.absoluteString
        case let value as UUID: return value.uuidString
        default: return value as? any DatabaseValueConvertible
        }
    }

    private func quote(_ identifier: String) -> String {
        "\"" + identifier.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    private func migrationError(_ message: String) -> Error {
        NSError(domain: "JsonData.Migration", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}
