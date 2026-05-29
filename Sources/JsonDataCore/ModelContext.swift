import Foundation
import Synchronization


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

    private let identityMapLock = Mutex(())
    private var identityMap: [PersistentIdentifier: WeakRef] = [:]
    
    private var insertedModels: [PersistentIdentifier: any PersistentModel] = [:]
    private var changedModels: [PersistentIdentifier: any PersistentModel] = [:]
    private var deletedModels: [PersistentIdentifier: any PersistentModel] = [:]
    
    public var autosaveEnabled: Bool = true
    private var pendingSaveTask: DispatchWorkItem?
    private let pendingSaveLock = Mutex(())
    
    public var hasChanges: Bool {
        identityMapLock.withLock { _ in
            !insertedModels.isEmpty || !changedModels.isEmpty || !deletedModels.isEmpty
        }
    }

    private func _scheduleAutosave() {
        guard autosaveEnabled else { return }
        pendingSaveLock.withLock { _ in
            pendingSaveTask?.cancel()
            let task = DispatchWorkItem { [weak self] in
                try? self?.save()
            }
            pendingSaveTask = task
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1, execute: task)
        }
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

    private let tableInitLock = Mutex(())
    private var initializedTables: Set<String> = []

    private func _ensureTable<T: PersistentModel>(for type: T.Type, in db: Database? = nil) throws {
        let tableName = _tableName(for: type)
        
        let alreadyInit = tableInitLock.withLock { _ -> Bool in
            if initializedTables.contains(tableName) { return true }
            initializedTables.insert(tableName)
            return false
        }
        
        if alreadyInit { return }
        
        let columns = _columns(for: type)
        
        let definitions = ["_id TEXT PRIMARY KEY NOT NULL"] + columns.map { column in
            let sqlType = _sqlType(for: column.kind)
            let nullability = column.isOptional ? "" : " NOT NULL"
            let unique = column.options.contains(.unique) ? " UNIQUE" : ""
            return "\(_quote(identifier: column.columnName)) \(sqlType)\(nullability)\(unique)"
        }
        let sql = "CREATE TABLE IF NOT EXISTS \(_quote(identifier: tableName)) (\(definitions.joined(separator: ", ")) )"
        
        let performMigration: (Database) throws -> Void = { db in
            try db.execute(sql: sql)
            let existingColumns = try db.columns(in: tableName).map { $0.name }
            for column in columns {
                if !existingColumns.contains(column.columnName) {
                    let sqlType = self._sqlType(for: column.kind)
                    let defaultVal = column.isOptional ? "" : " DEFAULT \(self._sqlDefault(for: column.kind))"
                    let nullability = column.isOptional ? "" : " NOT NULL"
                    let alterSQL = "ALTER TABLE \(self._quote(identifier: tableName)) ADD COLUMN \(self._quote(identifier: column.columnName)) \(sqlType)\(nullability)\(defaultVal)"
                    try db.execute(sql: alterSQL)
                }
            }
            
            if let schemaType = type as? any _JsonDataSchemaProviding.Type {
                for index in schemaType._jsonDataIndexes {
                    let indexName = "idx_\(tableName)_\(index.properties.joined(separator: "_"))"
                    let cols = index.properties.map(self._quote(identifier:)).joined(separator: ", ")
                    try db.execute(sql: "CREATE INDEX IF NOT EXISTS \(self._quote(identifier: indexName)) ON \(self._quote(identifier: tableName)) (\(cols))")
                }
                
                for unique in schemaType._jsonDataUniques {
                    let indexName = "idx_uniq_\(tableName)_\(unique.properties.joined(separator: "_"))"
                    let cols = unique.properties.map(self._quote(identifier:)).joined(separator: ", ")
                    try db.execute(sql: "CREATE UNIQUE INDEX IF NOT EXISTS \(self._quote(identifier: indexName)) ON \(self._quote(identifier: tableName)) (\(cols))")
                }
            }
        }

        if let db {
            try performMigration(db)
        } else {
            try databaseQueue.write { try performMigration($0) }
        }
        
        _ = tableInitLock.withLock { _ in
            initializedTables.insert(tableName)
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

    private func _sqlDefault(for kind: _JsonDataColumnKind) -> String {
        switch kind {
        case .string, .uuid, .date, .codableJSON:
            return "''"
        case .integer, .bool:
            return "0"
        case .double:
            return "0.0"
        case .data:
            return "x''"
        }
    }

    private func _quote(identifier: String) -> String {
        "\"" + identifier.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    // MARK: - Save

    public func _modelDidChange(_ model: any PersistentModel) {
        identityMapLock.withLock { _ in
            let id = model.persistentModelID
            if insertedModels[id] == nil && deletedModels[id] == nil {
                changedModels[id] = model
            }
        }
        _scheduleAutosave()
    }

    private func _saveModel(_ model: any PersistentModel, in db: Database) throws {
        let modelType = type(of: model)
        try _ensureTable(for: modelType, in: db)
        let tableName = _tableName(for: modelType)
        
        guard let schemaModel = model as? any _JsonDataSchemaProviding else { return }
        let columnValues = try schemaModel._toColumnValues(context: self)
        
        let cols = _columns(for: modelType)
        var columns = ["_id"]
        var placeholders = ["?"]
        var arguments: [DatabaseValueConvertible?] = [model.persistentModelID.id]
        
        for column in cols {
            columns.append(column.columnName)
            placeholders.append("?")
            let rawValue = columnValues[column.columnName] ?? nil
            arguments.append(_databaseArgument(for: rawValue))
        }
        
        let sql = "INSERT OR REPLACE INTO \(_quote(identifier: tableName)) (\(columns.map(_quote(identifier:)).joined(separator: ", "))) VALUES (\(placeholders.joined(separator: ", ")))"
        let updateArguments = StatementArguments(arguments)
        try db.execute(sql: sql, arguments: updateArguments)
    }

    public func save() throws {
        let (toInsert, toUpdate, toDelete) = identityMapLock.withLock { _ -> ([any PersistentModel], [any PersistentModel], [any PersistentModel]) in
            let inserts = Array(insertedModels.values)
            let updates = Array(changedModels.values)
            let deletes = Array(deletedModels.values)

            insertedModels.removeAll()
            changedModels.removeAll()
            deletedModels.removeAll()
            return (inserts, updates, deletes)
        }
        
        if toInsert.isEmpty && toUpdate.isEmpty && toDelete.isEmpty {
            return
        }
        
        try databaseQueue.write { db in
            for model in toDelete {
                let modelType = type(of: model)
                try _ensureTable(for: modelType, in: db)
                
                if let schemaType = modelType as? any _JsonDataSchemaProviding.Type {
                    let extDir = baseURL.appendingPathComponent(".externalStorage")
                    for column in schemaType._jsonDataColumns where column.options.contains(.externalStorage) {
                        let filename = "\(model.persistentModelID.id)_\(column.propertyName).dat"
                        let fileUrl = extDir.appendingPathComponent(filename)
                        try? FileManager.default.removeItem(at: fileUrl)
                    }
                }
                
                try db.execute(
                    sql: "DELETE FROM \(_quote(identifier: _tableName(for: modelType))) WHERE _id = ?",
                    arguments: [model.persistentModelID.id]
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

    // MARK: - Insert / Delete

    public func insert<T: PersistentModel>(_ model: T) {
        let shouldReturn = identityMapLock.withLock { _ -> Bool in
            if insertedModels[model.persistentModelID] != nil || identityMap[model.persistentModelID] != nil {
                return true
            }
            identityMap[model.persistentModelID] = WeakRef(model)
            insertedModels[model.persistentModelID] = model
            return false
        }
        if shouldReturn { return }

        model._modelContext = self
        model._isFault = false
        
        _processCascadeInsert(for: model)
        _scheduleAutosave()
    }
    
    private func _processCascadeInsert(for model: any PersistentModel) {
        guard let schemaType = type(of: model) as? any _JsonDataSchemaProviding.Type else { return }
        let relationships = schemaType._jsonDataRelationships
        if relationships.isEmpty { return }
        
        let mirror = Mirror(reflecting: model)
        var fields: [String: Any?] = [:]
        for child in mirror.children {
            guard let label = child.label, label.hasPrefix("_") else { continue }
            fields[String(label.dropFirst())] = _fieldStorageValue(from: child.value)
        }
        
        for rel in relationships {
            guard let value = fields[rel.propertyName] as? Any else { continue }
            if let relatedModel = value as? any PersistentModel {
                self.insert(relatedModel)
            } else if let relatedArray = value as? [any PersistentModel] {
                for rm in relatedArray {
                    self.insert(rm)
                }
            }
        }
    }

    public func delete<T: PersistentModel>(_ model: T) {
        let shouldReturn = identityMapLock.withLock { _ -> Bool in
            let id = model.persistentModelID
            if deletedModels[id] != nil {
                return true
            }
            
            identityMap.removeValue(forKey: id)
            insertedModels.removeValue(forKey: id)
            changedModels.removeValue(forKey: id)
            deletedModels[id] = model
            return false
        }
        
        if shouldReturn { return }
        
        _processCascadeDelete(for: model)
        _scheduleAutosave()
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

    private func _fieldStorageValue(from storage: Any) -> Any? {
        let mirror = Mirror(reflecting: storage)
        for child in mirror.children where child.label == "value" || child.label == "defaultValue" {
            let childMirror = Mirror(reflecting: child.value)
            if childMirror.displayStyle == .optional {
                if let unwrapped = childMirror.children.first?.value {
                    return unwrapped
                }
                continue
            }
            return child.value
        }
        return nil
    }

    // MARK: - Fetch

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
        let cols = _columns(for: T.self)
        
        let rows: [Row] = try databaseQueue.read { db in
            try Row.fetchAll(db, sql: query.sql, arguments: query.arguments)
        }

        var results: [T] = []
        identityMapLock.withLock { _ in
            _purgeStaleEntries()
        }

        for row in rows {
            let idStr: String = row["_id"]
            let id = PersistentIdentifier(id: idStr)
            
            let model: T
            let wasFault: Bool
            if let ref = identityMap[id], let cached = ref.value as? T {
                model = cached
                wasFault = cached._isFault
            } else {
                model = T()
                model.persistentModelID = id
                wasFault = true
            }
            
            if descriptor.predicate == nil && wasFault {
                model._isFault = true
                model._modelContext = self
                identityMap[id] = WeakRef(model)
                results.append(model)
                continue
            }

            if wasFault {
                let values = _rowToValues(row, columns: cols)
                if let schemaModel = model as? any _JsonDataSchemaProviding {
                    schemaModel._populateFromColumnValues(values, context: self)
                }
                model._modelContext = self
                model._isFault = false
                identityMap[id] = WeakRef(model)
            }
            
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
            let cols = self._columns(for: T.self)
            
            let results = self.identityMapLock.withLock { _ -> [T] in
                var results = [T]()
                for row in rows {
                    let idStr: String = row["_id"]
                    let id = PersistentIdentifier(id: idStr)
                    
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

                    let values = self._rowToValues(row, columns: cols)
                    let model = T()
                    model.persistentModelID = id
                    if let schemaModel = model as? any _JsonDataSchemaProviding {
                        schemaModel._populateFromColumnValues(values, context: self)
                    }
                    model._modelContext = self
                    model._isFault = false
                    self.identityMap[id] = WeakRef(model)
                    results.append(model)
                }
                return results
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

    public func model<T: PersistentModel>(for id: PersistentIdentifier) -> T? {
        if let cached = identityMapLock.withLock({ _ -> T? in
            if let ref = identityMap[id], let cached = ref.value as? T, !cached._isFault, !cached._isFaulting {
                return cached
            }
            return nil
        }) {
            return cached
        }

        do {
            guard let model: T = try _loadModel(for: id) else { return nil }
            identityMapLock.withLock { _ in
                identityMap[id] = WeakRef(model)
            }
            return model
        } catch {
            return nil
        }
    }

    private func _loadModel<T: PersistentModel>(for id: PersistentIdentifier) throws -> T? {
        try _ensureTable(for: T.self)
        let tableName = _tableName(for: T.self)
        let cols = _columns(for: T.self)
        let selectCols = (["_id"] + cols.map { _quote(identifier: $0.columnName) }).joined(separator: ", ")
        
        let row: Row? = try databaseQueue.read { db in
            try Row.fetchOne(
                db,
                sql: "SELECT \(selectCols) FROM \(_quote(identifier: tableName)) WHERE _id = ?",
                arguments: [id.id]
            )
        }
        guard let row else { return nil }
        
        let model = T()
        model.persistentModelID = id
        let values = _rowToValues(row, columns: cols)
        if let schemaModel = model as? any _JsonDataSchemaProviding {
            schemaModel._populateFromColumnValues(values, context: self)
        }
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
            identityMapLock.withLock { _ in
                identityMap[model.persistentModelID] = WeakRef(model)
            }
        } catch {
            return
        }
    }

    // MARK: - Row ↔ Values Helpers

    private func _rowToValues(_ row: Row, columns: [_JsonDataColumnInfo]) -> [String: Any?] {
        var values: [String: Any?] = [:]
        values["_id"] = row["_id"] as String
        for col in columns {
            switch col.kind {
            case .string, .uuid, .date, .codableJSON:
                values[col.columnName] = row[col.columnName] as String?
            case .integer:
                values[col.columnName] = row[col.columnName] as Int64?
            case .double:
                values[col.columnName] = row[col.columnName] as Double?
            case .bool:
                values[col.columnName] = row[col.columnName] as Int64?
            case .data:
                values[col.columnName] = row[col.columnName] as Data?
            }
        }
        
        return values
    }

    // MARK: - Query Building

    private func _buildFetchQuery<T: PersistentModel>(
        for type: T.Type,
        descriptor: FetchDescriptor<T>,
        limit: Int?,
        tableName: String
    ) throws -> (sql: String, arguments: StatementArguments) {
        let cols = _columns(for: type)
        let selectCols = (["_id"] + cols.map { _quote(identifier: $0.columnName) }).joined(separator: ", ")
        var sql = "SELECT \(selectCols) FROM \(_quote(identifier: tableName))"
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
        return nil
    }
}

extension ModelContext {
    public func _saveExternalData(_ data: Data, modelID: PersistentIdentifier, propertyName: String) throws -> String {
        let extDir = baseURL.appendingPathComponent(".externalStorage")
        try FileManager.default.createDirectory(at: extDir, withIntermediateDirectories: true)
        let filename = "\(modelID.id)_\(propertyName).dat"
        let fileUrl = extDir.appendingPathComponent(filename)
        try data.write(to: fileUrl)
        return filename
    }

    public func _loadExternalData(from reference: String) throws -> Data {
        let extDir = baseURL.appendingPathComponent(".externalStorage")
        let fileUrl = extDir.appendingPathComponent(reference)
        return try Data(contentsOf: fileUrl)
    }
}
