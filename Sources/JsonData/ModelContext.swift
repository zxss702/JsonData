import Foundation

#if !canImport(SwiftData)
import GRDB

private final class WeakRef {
    weak var value: (any PersistentModel)?

    init(_ value: any PersistentModel) {
        self.value = value
    }
}

public final class ModelContext: @unchecked Sendable {
    public static let shared = ModelContext()
    public let baseURL: URL

    private let identityMapLock = NSLock()
    private var identityMap: [String: WeakRef] = [:]
    
    private var insertedModels: [String: any PersistentModel] = [:]
    private var changedModels: [String: any PersistentModel] = [:]
    private var deletedModels: [String: any PersistentModel] = [:]
    
    public var hasChanges: Bool {
        identityMapLock.lock()
        defer { identityMapLock.unlock() }
        return !insertedModels.isEmpty || !changedModels.isEmpty || !deletedModels.isEmpty
    }

    private let databaseQueue: DatabaseQueue

    public static let contextDidChange = Notification.Name("JsonData.ModelContextDidChange")

    init() {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        baseURL = docs.appendingPathComponent("JsonDataStore")
        try? FileManager.default.createDirectory(at: baseURL, withIntermediateDirectories: true)
        let dbURL = baseURL.appendingPathComponent("JsonData.sqlite")
        databaseQueue = try! DatabaseQueue(path: dbURL.path)
    }

    public init(url: URL) {
        self.baseURL = url.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: baseURL, withIntermediateDirectories: true)
        databaseQueue = try! DatabaseQueue(path: url.path)
    }
    
    public init(_ container: ModelContainer) {
        self.baseURL = container.mainContext.baseURL
        self.databaseQueue = container.mainContext.databaseQueue
    }

    private func _purgeStaleEntries() {
        identityMap = identityMap.filter { $0.value.value != nil }
    }

    private func _postContextDidChange() {
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: Self.contextDidChange, object: nil)
        }
    }

    private func _tableName(for type: any PersistentModel.Type) -> String {
        if let schemaType = type as? any _JsonDataSchemaProviding.Type {
            return schemaType._jsonDataTableName
        }
        return String(describing: type)
    }

    private func _columns(for type: any PersistentModel.Type) -> [_JsonDataColumnInfo] {
        if let schemaType = type as? any _JsonDataSchemaProviding.Type {
            return schemaType._jsonDataColumns
        }
        return []
    }

    fileprivate static func _keyPathResolver(for type: any PersistentModel.Type) -> ((AnyKeyPath) -> String?)? {
        guard let schemaType = type as? any _JsonDataSchemaProviding.Type else { return nil }
        return { keyPath in
            schemaType._jsonDataPropertyName(for: keyPath)
        }
    }

    private func _ensureTable(for type: any PersistentModel.Type, in db: Database? = nil) throws {
        let tableName = _tableName(for: type)
        let columns = _columns(for: type)
        
        let definitions = ["id TEXT PRIMARY KEY NOT NULL", "payload BLOB NOT NULL"] + columns.map { column in
            let sqlType = _sqlType(for: column.kind)
            let nullability = column.isOptional ? "" : " NOT NULL"
            let unique = column.options.contains(.unique) ? " UNIQUE" : ""
            return "\(column.columnName) \(sqlType)\(nullability)\(unique)"
        }
        let sql = "CREATE TABLE IF NOT EXISTS \(_quote(identifier: tableName)) (\(definitions.joined(separator: ", ")) )"
        
        if let db {
            try db.execute(sql: sql)
        } else {
            try databaseQueue.write { try $0.execute(sql: sql) }
        }
    }

    private func _sqlType(for kind: _JsonDataColumnKind) -> String {
        switch kind {
        case .string, .uuid, .date, .codableJSON:
            return "TEXT"
        case .integer, .bool:
            return "INTEGER"
        case .double:
            return "REAL"
        case .data:
            return "BLOB"
        }
    }

    private func _quote(identifier: String) -> String {
        "\"" + identifier.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    private func _databaseValue(for value: Any?, kind: _JsonDataColumnKind) throws -> DatabaseValueConvertible? {
        guard let value else { return nil }
        switch kind {
        case .string:
            return value as? String
        case .integer:
            return value as? Int64 ?? (value as? Int).map(Int64.init)
        case .double:
            return value as? Double
        case .bool:
            if let bool = value as? Bool { return bool ? 1 : 0 }
            return nil
        case .uuid:
            return (value as? UUID)?.uuidString
        case .date:
            return ISO8601DateFormatter().string(from: value as! Date)
        case .data:
            return value as? Data
        case .codableJSON:
            let data = try JSONEncoder().encode(AnyEncodable(value))
            return String(decoding: data, as: UTF8.self)
        }
    }

    private func _extractColumnValues(from model: any PersistentModel) throws -> [String: DatabaseValueConvertible?] {
        let mirror = Mirror(reflecting: model)
        var fields: [String: Any?] = [:]
        for child in mirror.children {
            guard let label = child.label, label.hasPrefix("_") else { continue }
            fields[String(label.dropFirst())] = _fieldStorageValue(from: child.value)
        }

        var values: [String: DatabaseValueConvertible?] = [:]
        for column in _columns(for: type(of: model)) {
            let rawValue = fields[column.propertyName] ?? nil
            values[column.columnName] = try _databaseValue(for: rawValue, kind: column.kind)
        }
        return values
    }

    private func _fieldStorageValue(from storage: Any) -> Any? {
        let mirror = Mirror(reflecting: storage)
        for child in mirror.children where child.label == "value" || child.label == "defaultValue" {
            let childMirror = Mirror(reflecting: child.value)
            if childMirror.displayStyle == .optional {
                return childMirror.children.first?.value
            }
            return child.value
        }
        return nil
    }

    public func _modelDidChange(_ model: any PersistentModel) {
        identityMapLock.lock()
        defer { identityMapLock.unlock() }
        let id = model.persistentModelID
        if insertedModels[id] == nil && deletedModels[id] == nil {
            changedModels[id] = model
        }
    }

    private func _saveModel(_ model: any PersistentModel, in db: Database) throws {
        let modelType = type(of: model)
        try _ensureTable(for: modelType, in: db)
        let payload = try JSONEncoder().encode(AnyEncodable(model))
        let tableName = _tableName(for: modelType)
        let columnValues = try _extractColumnValues(from: model)
        
        let cols = _columns(for: modelType)
        var columns = ["id", "payload"]
        var placeholders = ["?", "?"]
        var arguments: [DatabaseValueConvertible?] = [model.persistentModelID, payload]
        
        for column in cols {
            columns.append(column.columnName)
            placeholders.append("?")
            arguments.append(columnValues[column.columnName] ?? nil)
        }
        
        let updates = (["payload = ?"] + cols.map { "\(_quote(identifier: $0.columnName)) = ?" }).joined(separator: ", ")
        let sql = "INSERT INTO \(_quote(identifier: tableName)) (\(columns.map(_quote(identifier:)).joined(separator: ", "))) VALUES (\(placeholders.joined(separator: ", "))) ON CONFLICT(id) DO UPDATE SET \(updates)"
        let updateArguments = StatementArguments(arguments + [payload] + cols.map { columnValues[$0.columnName] ?? nil })
        try db.execute(sql: sql, arguments: updateArguments)
    }

    public func save() throws {
        identityMapLock.lock()
        let toInsert = insertedModels.values
        let toUpdate = changedModels.values
        let toDelete = deletedModels.values
        
        insertedModels.removeAll()
        changedModels.removeAll()
        deletedModels.removeAll()
        identityMapLock.unlock()
        
        if toInsert.isEmpty && toUpdate.isEmpty && toDelete.isEmpty {
            return
        }
        
        try databaseQueue.write { db in
            for model in toDelete {
                let modelType = type(of: model)
                try _ensureTable(for: modelType, in: db)
                try db.execute(
                    sql: "DELETE FROM \(_quote(identifier: _tableName(for: modelType))) WHERE id = ?",
                    arguments: [model.persistentModelID]
                )
            }
            
            for model in toInsert {
                try _saveModel(model, in: db)
            }
            
            for model in toUpdate {
                try _saveModel(model, in: db)
            }
        }
        _postContextDidChange()
    }

    public func insert<T: PersistentModel>(_ model: T) {
        identityMapLock.lock()
        identityMap[model.persistentModelID] = WeakRef(model)
        insertedModels[model.persistentModelID] = model
        identityMapLock.unlock()

        model._modelContext = self
        model._isFault = false
    }

    public func delete<T: PersistentModel>(_ model: T) {
        identityMapLock.lock()
        let id = model.persistentModelID
        
        if deletedModels[id] != nil {
            identityMapLock.unlock()
            return // prevent infinite recursion
        }
        
        identityMap.removeValue(forKey: id)
        insertedModels.removeValue(forKey: id)
        changedModels.removeValue(forKey: id)
        deletedModels[id] = model
        identityMapLock.unlock()
        
        _processCascadeDelete(for: model)
    }
    
    private func _processCascadeDelete(for model: any PersistentModel) {
        guard let schemaType = type(of: model) as? any _JsonDataSchemaProviding.Type else { return }
        let cascadeRelationships = schemaType._jsonDataRelationships.filter { $0.deleteRule == .cascade }
        if cascadeRelationships.isEmpty { return }
        
        if model._isFault {
            _faultIn(model)
        }
        
        let mirror = Mirror(reflecting: model)
        var fields: [String: Any?] = [:]
        for child in mirror.children {
            guard let label = child.label, label.hasPrefix("_") else { continue }
            fields[String(label.dropFirst())] = _fieldStorageValue(from: child.value)
        }
        
        for rel in cascadeRelationships {
            guard let value = fields[rel.propertyName] as? Any else { continue }
            if let relatedModel = value as? any PersistentModel {
                self.delete(relatedModel)
            } else if let relatedArray = value as? [any PersistentModel] {
                for rm in relatedArray {
                    self.delete(rm)
                }
            }
        }
    }

    public func fetch<T: PersistentModel>(
        _ descriptor: FetchDescriptor<T> = FetchDescriptor<T>(),
        limit: Int? = nil
    ) throws -> [T] {
        let effectiveLimit = descriptor.fetchLimit ?? limit
        if let effectiveLimit, effectiveLimit <= 0 {
            return []
        }

        try _ensureTable(for: T.self)
        let tableName = _tableName(for: T.self)
        let query = try _buildFetchQuery(for: T.self, descriptor: descriptor, limit: effectiveLimit, tableName: tableName)
        let rows: [(String, Data)] = try databaseQueue.read { db in
            let rows = try Row.fetchAll(db, sql: query.sql, arguments: query.arguments)
            return try rows.map { row in
                let id: String = row["id"]
                let payload: Data = row["payload"]
                return (id, payload)
            }
        }

        var results: [T] = []
        identityMapLock.lock()
        _purgeStaleEntries()
        defer { identityMapLock.unlock() }

        for (id, payload) in rows {
            if let ref = identityMap[id], let cached = ref.value as? T {
                results.append(cached)
                continue
            }

            if descriptor.predicate == nil {
                let fault = T()
                fault.persistentModelID = id
                fault._isFault = true
                fault._modelContext = self
                identityMap[id] = WeakRef(fault)
                results.append(fault)
                continue
            }

            let model = try JSONDecoder().decode(T.self, from: payload)
            model._modelContext = self
            model._isFault = false
            identityMap[id] = WeakRef(model)
            results.append(model)
        }

        return results
    }

    public func observe<T: PersistentModel & Sendable>(
        _ descriptor: FetchDescriptor<T> = FetchDescriptor<T>()
    ) -> ValueObservation<ValueReducers.Fetch<[T]>> {
        let tableName = _tableName(for: T.self)
        try? _ensureTable(for: T.self)
        let effectiveLimit = descriptor.fetchLimit
        
        return ValueObservation.tracking { db in
            let query = try self._buildFetchQuery(for: T.self, descriptor: descriptor, limit: effectiveLimit, tableName: tableName)
            let rows = try Row.fetchAll(db, sql: query.sql, arguments: query.arguments)
            let rawData = try rows.map { row -> (String, Data) in
                let id: String = row["id"]
                let payload: Data = row["payload"]
                return (id, payload)
            }
            
            var results: [T] = []
            self.identityMapLock.lock()
            self._purgeStaleEntries()
            defer { self.identityMapLock.unlock() }

            for (id, payload) in rawData {
                if let ref = self.identityMap[id], let cached = ref.value as? T {
                    results.append(cached)
                    continue
                }

                if descriptor.predicate == nil {
                    let fault = T()
                    fault.persistentModelID = id
                    fault._isFault = true
                    fault._modelContext = self
                    self.identityMap[id] = WeakRef(fault)
                    results.append(fault)
                    continue
                }

                if let model = try? JSONDecoder().decode(T.self, from: payload) {
                    model._modelContext = self
                    model._isFault = false
                    self.identityMap[id] = WeakRef(model)
                    results.append(model)
                }
            }
            return results
        }
    }

    @MainActor
    public func startObservation<T: PersistentModel & Sendable>(
        _ descriptor: FetchDescriptor<T> = FetchDescriptor<T>(),
        onError: @Sendable @escaping (Error) -> Void = { _ in },
        onChange: @MainActor @Sendable @escaping ([T]) -> Void
    ) -> DatabaseCancellable {
        let obs = observe(descriptor)
        return obs.start(in: databaseQueue, onError: onError, onChange: onChange)
    }

    public func model<T: PersistentModel>(for id: String) -> T? {
        identityMapLock.lock()
        if let ref = identityMap[id], let cached = ref.value as? T, !cached._isFault, !cached._isFaulting {
            identityMapLock.unlock()
            return cached
        }
        identityMapLock.unlock()

        do {
            guard let model: T = try _loadModel(for: id) else { return nil }
            identityMapLock.lock()
            identityMap[id] = WeakRef(model)
            identityMapLock.unlock()
            return model
        } catch {
            return nil
        }
    }

    private func _loadModel<T: PersistentModel>(for id: String) throws -> T? {
        try _ensureTable(for: T.self)
        let payload: Data? = try databaseQueue.read { db in
            try Data.fetchOne(
                db,
                sql: "SELECT payload FROM \(_quote(identifier: _tableName(for: T.self))) WHERE id = ?",
                arguments: [id]
            )
        }
        guard let payload else { return nil }
        let model = try JSONDecoder().decode(T.self, from: payload)
        model._modelContext = self
        model._isFault = false
        return model
    }

    public func _faultIn<T: PersistentModel>(_ model: T) {
        do {
            guard let fullModel: T = try _loadModel(for: model.persistentModelID) else { return }
            model._copy(from: fullModel)
            model._modelContext = self
            model._isFault = false
            identityMapLock.lock()
            identityMap[model.persistentModelID] = WeakRef(model)
            identityMapLock.unlock()
        } catch {
            return
        }
    }

    private func _buildFetchQuery<T: PersistentModel>(
        for type: T.Type,
        descriptor: FetchDescriptor<T>,
        limit: Int?,
        tableName: String
    ) throws -> (sql: String, arguments: StatementArguments) {
        var sql = "SELECT id, payload FROM \(_quote(identifier: tableName))"
        var arguments = StatementArguments()

        if let predicate = descriptor.predicate {
            if !predicate.sql.isEmpty {
                sql += " WHERE \(predicate.sql)"
                let dbArgs = predicate.arguments.map { _databaseArgument(for: $0) }
                arguments += StatementArguments(dbArgs)
            }
        }

        let orderBy = _buildOrderByClause(descriptor.sortBy, columns: _columns(for: type))
        if !orderBy.isEmpty {
            sql += " ORDER BY \(orderBy)"
        }

        if let fetchOffset = descriptor.fetchOffset, fetchOffset > 0 {
            sql += " LIMIT -1 OFFSET \(fetchOffset)"
        }
        if let limit {
            if descriptor.fetchOffset != nil {
                sql = sql.replacingOccurrences(of: "LIMIT -1", with: "LIMIT \(limit)")
            } else {
                sql += " LIMIT \(limit)"
            }
        }

        return (sql, arguments)
    }

    private func _buildOrderByClause<T: PersistentModel>(
            _ sortBy: [SortDescriptor<T>],
            columns: [_JsonDataColumnInfo]
        ) -> String {
            let resolver = Self._keyPathResolver(for: T.self)
            let fragments = sortBy.compactMap { descriptor -> String? in
                let mirror = Mirror(reflecting: descriptor)
                guard
                    let comparison = mirror.children.first(where: { $0.label == "comparison" })?.value,
                    let comparable = Mirror(reflecting: comparison).children.first(where: { $0.label == "comparable" })?.value,
                    let keyPath = Mirror(reflecting: comparable).children.first(where: { $0.label == ".1" })?.value,
                    let column = _jsonDataColumn(for: keyPath, columns: columns, resolver: resolver)
                else {
                    return nil
                }
                let isReverse = String(describing: descriptor).contains("order: reverse") || String(describing: mirror.children.first(where: { $0.label == "order" })?.value ?? "").contains("reverse")
                return "\(_quote(identifier: column.columnName)) \(isReverse ? "DESC" : "ASC")"
            }
            return fragments.joined(separator: ", ")
        }
}

private func _jsonDataColumn(
    for keyPath: Any,
    columns: [_JsonDataColumnInfo],
    resolver: ((AnyKeyPath) -> String?)? = nil
) -> _JsonDataColumnInfo? {
    if let anyKeyPath = keyPath as? AnyKeyPath,
       let propertyName = resolver?(anyKeyPath),
       let match = columns.first(where: { $0.propertyName == propertyName || $0.columnName == propertyName }) {
        return match
    }

    let description = String(describing: keyPath)
    let normalized = description.replacingOccurrences(of: "\\", with: "")
    let separators = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_"))
    let tokens = normalized.components(separatedBy: separators.inverted).filter { !$0.isEmpty }

    for token in tokens.reversed() {
        if let match = columns.first(where: { $0.propertyName == token || $0.columnName == token }) {
            return match
        }
    }

    return columns.first {
        normalized.contains($0.propertyName) || normalized.contains($0.columnName)
    }
}


private func _databaseArgument(for value: Any?) -> DatabaseValueConvertible? {
    switch value {
    case let int as Int: return int
    case let int64 as Int64: return int64
    case let double as Double: return double
    case let string as String: return string
    case let bool as Bool: return bool ? 1 : 0
    case let uuid as UUID: return uuid.uuidString
    case let date as Date: return ISO8601DateFormatter().string(from: date)
    case let data as Data: return data
    case nil: return nil
    default:
        if let value {
            let data = try? JSONEncoder().encode(AnyEncodable(value))
            return data.map { String(decoding: $0, as: UTF8.self) }
        }
        return nil
    }
}

private struct AnyEncodable: Encodable {
    private let encodeImpl: (Encoder) throws -> Void

    init(_ value: Any) {
        self.encodeImpl = { encoder in
            var container = encoder.singleValueContainer()
            switch value {
            case let value as String:
                try container.encode(value)
            case let value as Int:
                try container.encode(value)
            case let value as Int64:
                try container.encode(value)
            case let value as Double:
                try container.encode(value)
            case let value as Bool:
                try container.encode(value)
            case let value as UUID:
                try container.encode(value.uuidString)
            case let value as Date:
                try container.encode(ISO8601DateFormatter().string(from: value))
            case let value as Data:
                try container.encode(value.base64EncodedString())
            case let value as [String: String]:
                try container.encode(value)
            case let value as any Encodable:
                try value.encode(to: encoder)
            default:
                try container.encodeNil()
            }
        }
    }

    func encode(to encoder: Encoder) throws {
        try encodeImpl(encoder)
    }
}

#endif
