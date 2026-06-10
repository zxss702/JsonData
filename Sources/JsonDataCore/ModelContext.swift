import Foundation
import Synchronization


import GRDB

#if canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#elseif canImport(ucrt)
import ucrt
#endif

internal final class WeakRef {
    weak var value: (any PersistentModel)?

    init(_ value: any PersistentModel) {
        self.value = value
    }
}

private final class WeakContextRef: @unchecked Sendable {
    weak var context: ModelContext?
    init(_ context: ModelContext) {
        self.context = context
    }
}

private let globalContextsLock = Mutex([WeakContextRef]())

@_cdecl("_JsonDataCore_PerformExitAutosave")
func _JsonDataCore_PerformExitAutosave() {
    globalContextsLock.withLock { contexts in
        for ref in contexts {
            try? ref.context?.save()
        }
    }
}

private let _registerAtExitOnce: Void = {
    atexit {
        _JsonDataCore_PerformExitAutosave()
    }
}()

private func registerAtExit() {
    _ = _registerAtExitOnce
}

/// 数据模型上下文，管理持久化对象的生命周期与数据库操作。
public final class ModelContext: @unchecked Sendable {
    /// 共享的单例上下文实例。
    public static let shared = ModelContext()
    /// 数据库文件所在的基础目录 URL。
    public let baseURL: URL

    internal let identityMapLock = Mutex(())
    internal var identityMap: [PersistentIdentifier: WeakRef] = [:]
    
    internal var insertedModels: [PersistentIdentifier: any PersistentModel] = [:]
    internal var changedModels: [PersistentIdentifier: any PersistentModel] = [:]
    internal var deletedModels: [PersistentIdentifier: any PersistentModel] = [:]
    
    /// 是否启用自动保存。默认为 `true`。
    public var autosaveEnabled: Bool = true
    private var pendingSaveTask: Task<Void, Never>?
    private let pendingSaveLock = Mutex(())
    
    /// 是否有未保存的更改。
    public var hasChanges: Bool {
        identityMapLock.withLock { _ in
            !insertedModels.isEmpty || !changedModels.isEmpty || !deletedModels.isEmpty
        }
    }

    // @contributor
    internal func _scheduleAutosave() {
        guard autosaveEnabled else { return }
        pendingSaveLock.withLock { _ in
            pendingSaveTask?.cancel()
            let task = Task.detached { [weak self] in
                do {
                    try await Task.sleep(for: .seconds(0.1))
                    try self?.save()
                } catch {
                    // Task was cancelled, do nothing
                }
            }
            pendingSaveTask = task
        }
    }

    private let databaseQueue: DatabaseQueue

    /// 上下文数据发生变更时发出的通知名称。
    public static let contextDidChange = Notification.Name("JsonData.ModelContextDidChange")

    // @contributor
    private func registerSelf() {
        registerAtExit()
        globalContextsLock.withLock { contexts in
            contexts.removeAll { $0.context == nil }
            contexts.append(WeakContextRef(self))
        }
    }

    /// 使用默认文档目录创建上下文。
    init() {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        baseURL = docs.appendingPathComponent("JsonDataStore")
        try? FileManager.default.createDirectory(at: baseURL, withIntermediateDirectories: true)
        let dbURL = baseURL.appendingPathComponent("JsonData.sqlite")
        databaseQueue = try! DatabaseQueue(path: dbURL.path)
        registerSelf()
    }

    /// 使用指定的数据库文件 URL 创建上下文。
    public init(url: URL) {
        self.baseURL = url.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: baseURL, withIntermediateDirectories: true)
        databaseQueue = try! DatabaseQueue(path: url.path)
        registerSelf()
    }
    
    /// 从现有的模型容器创建上下文，共享其数据库连接。
    public init(_ container: ModelContainer) {
        self.baseURL = container.mainContext.baseURL
        self.databaseQueue = container.mainContext.databaseQueue
        registerSelf()
    }

    // @contributor
    private func _purgeStaleEntries() {
        identityMap = identityMap.filter { $0.value.value != nil }
    }

    // @contributor
    private func _postContextDidChange() {
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: Self.contextDidChange, object: nil)
        }
    }

    // @contributor
    private func _tableName(for type: any PersistentModel.Type) -> String {
        if let schemaType = type as? any _JsonDataSchemaProviding.Type {
            return schemaType._jsonDataTableName
        }
        return String(describing: type)
    }

    // @contributor
    private func _columns(for type: any PersistentModel.Type) -> [_JsonDataColumnInfo] {
        if let schemaType = type as? any _JsonDataSchemaProviding.Type {
            return schemaType._jsonDataColumns
        }
        return []
    }

    // @contributor
    fileprivate static func _keyPathResolver(for type: any PersistentModel.Type) -> ((AnyKeyPath) -> String?)? {
        guard let schemaType = type as? any _JsonDataSchemaProviding.Type else { return nil }
        return { keyPath in
            schemaType._jsonDataPropertyName(for: keyPath)
        }
    }

    private let tableInitLock = Mutex(())
    private var initializedTables: Set<String> = []
    
    /// 根据给定的模型类型列表初始化数据库表结构。此方法供内部使用。
    public func _bootstrapSchema(_ schema: [any PersistentModel.Type]) {
        try? databaseQueue.write { db in
            for modelType in schema {
                try? self._ensureTable(for: modelType, in: db)
            }
        }
    }

    // @contributor
    private func _ensureTable(for type: any PersistentModel.Type, in db: Database? = nil) throws {
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

    // @contributor
    private func _sqlType(for kind: _JsonDataColumnKind) -> String {
        switch kind {
        case .string, .uuid, .date, .codableJSON, .url: return "TEXT"
        case .integer, .bool:
            return "INTEGER"
        case .double:
            return "REAL"
        case .data:
            return "BLOB"
        }
    }

    // @contributor
    private func _sqlDefault(for kind: _JsonDataColumnKind) -> String {
        switch kind {
        case .string, .uuid, .date, .codableJSON, .url:
            return "''"
        case .integer, .bool:
            return "0"
        case .double:
            return "0.0"
        case .data:
            return "x''"
        }
    }

    // @contributor
    private func _quote(identifier: String) -> String {
        "\"" + identifier.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    // MARK: - Save

    /// 标记模型已发生更改，触发自动保存。由属性变更观察器调用。
    public func _modelDidChange(_ model: any PersistentModel) {
        identityMapLock.withLock { _ in
            let id = model.persistentModelID
            if insertedModels[id] == nil && deletedModels[id] == nil {
                changedModels[id] = model
            }
        }
        _scheduleAutosave()
    }

    // @contributor
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

    /// 将所有未保存的插入、更新和删除操作写入数据库。
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

    /// 将模型插入上下文，在下一次保存时写入数据库。
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
    
    // @contributor
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

    /// 将模型标记为待删除，在下一次保存时从数据库移除。
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
    
    // @contributor
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

    // @contributor
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

    /// 根据查询描述符和限制条件从数据库检索模型实例。
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

        if descriptor.includePendingChanges {
            identityMapLock.withLock { _ in
                let pendingInserts = insertedModels.values.compactMap { $0 as? T }
                if let filter = descriptor.predicate?.memoryFilter {
                    results.removeAll { deletedModels[$0.persistentModelID] != nil || !filter($0) }
                    for insert in pendingInserts {
                        if filter(insert) && deletedModels[insert.persistentModelID] == nil {
                            results.append(insert)
                        }
                    }
                } else if descriptor.predicate == nil {
                    results.removeAll { deletedModels[$0.persistentModelID] != nil }
                    results.append(contentsOf: pendingInserts.filter { deletedModels[$0.persistentModelID] == nil })
                } else {
                    results.removeAll { deletedModels[$0.persistentModelID] != nil }
                    results.append(contentsOf: pendingInserts.filter { deletedModels[$0.persistentModelID] == nil })
                }
            }
        }

        if !descriptor.sortBy.isEmpty {
            let sortDescriptors = descriptor.sortBy
            results.sort { a, b in
                for sd in sortDescriptors {
                    if sd.areInIncreasingOrder(a, b) { return true }
                    if sd.areInIncreasingOrder(b, a) { return false }
                }
                return false
            }
        }
        if let effectiveLimit {
            results = Array(results.prefix(effectiveLimit))
        }

        return results
    }

    /// 创建数据观察器，用于监听查询结果的实时变化。
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
                    
                    let model = T()
                    model.persistentModelID = id
                    let values = self._rowToValues(row, columns: cols)
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


    /// 在主线程启动数据观察，当查询结果变化时回调 `onChange`。
    @MainActor
    public func startObservation<T: PersistentModel & Sendable>(
        _ descriptor: FetchDescriptor<T> = FetchDescriptor<T>(),
        onError: @Sendable @escaping (Error) -> Void = { _ in },
        onChange: @MainActor @Sendable @escaping ([T]) -> Void
    ) -> DatabaseCancellable {
        let obs = observe(descriptor)
        return obs.start(in: databaseQueue, onError: onError, onChange: onChange)
    }

    /// 通过持久化标识符查找并返回模型实例。
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

    // @contributor
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

    /// 将惰性加载的模型实例填充完整数据。此方法供内部使用。
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

    // @contributor
    private func _rowToValues(_ row: Row, columns: [_JsonDataColumnInfo]) -> [String: Any?] {
        var values: [String: Any?] = [:]
        values["_id"] = row["_id"] as String
        for col in columns {
            switch col.kind {
            case .string, .uuid, .date, .codableJSON, .url:
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

    // @contributor
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

        // 处理嵌套 keyPath 产生的 JOIN 子查询（如 $0.subAgent?.callID == xxx）
        if let joinConditions = descriptor.predicate?.joinConditions, !joinConditions.isEmpty {
            if let schemaType = type as? any _JsonDataSchemaProviding.Type {
                for jc in joinConditions {
                    if let rel = schemaType._jsonDataRelationships.first(where: { $0.propertyName == jc.localColumn }),
                       let destSchema = rel.destinationType as? any _JsonDataSchemaProviding.Type {
                        let targetTable = destSchema._jsonDataTableName
                        let prefix = sql.contains("WHERE") ? " AND" : " WHERE"
                        sql += "\(prefix) \(_quote(identifier: jc.localColumn)) IN (SELECT \"_id\" FROM \(_quote(identifier: targetTable)) WHERE \(_quote(identifier: jc.targetColumn)) \(jc.op) ?)"
                        if let dbArg = _databaseArgument(for: jc.argument) {
                            arguments += StatementArguments([dbArg])
                        }
                    }
                }
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

    // @contributor
    private func _buildOrderByClause<T: PersistentModel>(
            _ sortBy: [SortDescriptor<T>],
            columns: [_JsonDataColumnInfo]
        ) -> String {
            let resolver = Self._keyPathResolver(for: T.self)
            let fragments = sortBy.compactMap { descriptor -> String? in
                guard
                    let propertyName = resolver?(descriptor.keyPath),
                    let column = columns.first(where: { $0.propertyName == propertyName || $0.columnName == propertyName })
                else {
                    return nil
                }
                let isReverse = descriptor.order == .reverse
                return "\(_quote(identifier: column.columnName)) \(isReverse ? "DESC" : "ASC")"
            }
            return fragments.joined(separator: ", ")
        }
}

private func _databaseArgument(for value: Any?) -> DatabaseValueConvertible? {
    switch value {
    case let int as Int: return int
    case let int8 as Int8: return Int64(int8)
    case let int16 as Int16: return Int64(int16)
    case let int32 as Int32: return Int64(int32)
    case let int64 as Int64: return int64
    case let uint as UInt: return Int64(uint)
    case let uint8 as UInt8: return Int64(uint8)
    case let uint16 as UInt16: return Int64(uint16)
    case let uint32 as UInt32: return Int64(uint32)
    case let uint64 as UInt64: return Int64(uint64)
    case let double as Double: return double
    case let float as Float: return Double(float)
    case let string as String: return string
    case let bool as Bool: return bool ? 1 : 0
    case let uuid as UUID: return uuid.uuidString
    case let date as Date: return ISO8601DateFormatter().string(from: date)
    case let url as URL: return url.absoluteString
    case let data as Data: return data
    case nil: return nil
    default:
        return nil
    }
}

extension ModelContext {
    /// 将外部存储的数据写入文件系统。此方法供内部使用。
    public func _saveExternalData(_ data: Data, modelID: PersistentIdentifier, propertyName: String) throws -> String {
        let extDir = baseURL.appendingPathComponent(".externalStorage")
        try FileManager.default.createDirectory(at: extDir, withIntermediateDirectories: true)
        let filename = "\(modelID.id)_\(propertyName).dat"
        let fileUrl = extDir.appendingPathComponent(filename)
        try data.write(to: fileUrl)
        return filename
    }

    /// 从文件系统读取外部存储的数据。此方法供内部使用。
    public func _loadExternalData(from reference: String) throws -> Data {
        let extDir = baseURL.appendingPathComponent(".externalStorage")
        let fileUrl = extDir.appendingPathComponent(reference)
        return try Data(contentsOf: fileUrl)
    }
}
