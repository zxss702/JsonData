import Foundation
import SwiftCompilerPlugin
import SwiftSyntax
import SwiftSyntaxBuilder
import SwiftSyntaxMacros

struct MacroError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

private struct PersistentStoredProperty {
    let name: String
    let type: String
    let baseType: String
    let isOptional: Bool
    let attributeOptions: [String]
    let relationshipInfo: RelationshipInfo?

    struct RelationshipInfo {
        let deleteRule: String
        let destinationType: String
        let inverseName: String?
    }

    var columnKind: String {
        switch baseType {
        case "String":
            return "_JsonDataColumnKind.string"
        case "Int":
            return "_JsonDataColumnKind.integer"
        case "Double":
            return "_JsonDataColumnKind.double"
        case "Bool":
            return "_JsonDataColumnKind.bool"
        case "UUID":
            return "_JsonDataColumnKind.uuid"
        case "Date":
            return "_JsonDataColumnKind.date"
        case "Data":
            return "_JsonDataColumnKind.data"
        default:
            return "_JsonDataColumnKind.codableJSON"
        }
    }
}

private extension AttributeListSyntax.Element {
    var attributeSyntax: AttributeSyntax? {
        switch self {
        case .attribute(let attribute):
            attribute
        case .ifConfigDecl:
            nil
        }
    }
}

private extension VariableDeclSyntax {
    var hasAccessor: Bool {
        bindings.contains { binding in
            binding.accessorBlock != nil
        }
    }

    var hasTransientAttribute: Bool {
        return attributes.contains { element in
            guard let attribute = element.attributeSyntax else { return false }
            let name = attribute.attributeName.trimmedDescription
            return name == "Transient" || name.hasSuffix(".Transient")
        }
    }

    var persistentStoredProperties: [PersistentStoredProperty] {
        guard !hasAccessor, !hasTransientAttribute else { return [] }

        var properties: [PersistentStoredProperty] = []
        for binding in bindings {
            guard
                let identifier = binding.pattern.as(IdentifierPatternSyntax.self)?.identifier.text,
                let type = binding.typeAnnotation?.type.trimmedDescription
            else {
                continue
            }

            let normalizedType = type.replacingOccurrences(of: " ", with: "")
            let baseType: String
            let isOptional: Bool
            if normalizedType.hasSuffix("?") {
                baseType = String(normalizedType.dropLast())
                isOptional = true
            } else if normalizedType.hasPrefix("Optional<"), normalizedType.hasSuffix(">") {
                baseType = String(normalizedType.dropFirst("Optional<".count).dropLast())
                isOptional = true
            } else {
                baseType = normalizedType
                isOptional = false
            }

            var attributeOptions: [String] = []
            var relationshipInfo: PersistentStoredProperty.RelationshipInfo? = nil

            for element in attributes {
                guard let attribute = element.attributeSyntax else { continue }
                let attrName = attribute.attributeName.trimmedDescription
                if attrName == "Attribute" || attrName.hasSuffix(".Attribute") {
                    if let arguments = attribute.arguments?.as(LabeledExprListSyntax.self) {
                        for arg in arguments {
                            let expr = arg.expression.trimmedDescription
                            if expr.hasSuffix(".unique") || expr == "unique" { attributeOptions.append(".unique") }
                            if expr.hasSuffix(".externalStorage") || expr == "externalStorage" { attributeOptions.append(".externalStorage") }
                            if expr.hasSuffix(".ephemeral") || expr == "ephemeral" { attributeOptions.append(".ephemeral") }
                            if expr.hasSuffix(".transformable") || expr == "transformable" { attributeOptions.append(".transformable") }
                        }
                    }
                } else if attrName == "Relationship" || attrName.hasSuffix(".Relationship") {
                    var deleteRule = ".nullify"
                    var inverseName: String? = nil
                    if let arguments = attribute.arguments?.as(LabeledExprListSyntax.self) {
                        for arg in arguments {
                            if arg.label?.text == "deleteRule" {
                                let expr = arg.expression.trimmedDescription
                                if expr.hasSuffix(".cascade") || expr == "cascade" { deleteRule = ".cascade" }
                                else if expr.hasSuffix(".deny") || expr == "deny" { deleteRule = ".deny" }
                            } else if arg.label?.text == "inverse" {
                                let expr = arg.expression.trimmedDescription
                                if expr.hasPrefix("\\.") {
                                    inverseName = String(expr.dropFirst(2))
                                } else if let dotIndex = expr.lastIndex(of: ".") {
                                    inverseName = String(expr[expr.index(after: dotIndex)...])
                                }
                            }
                        }
                    }
                    let isRelArray = baseType.hasPrefix("[") && baseType.hasSuffix("]")
                    let destType = isRelArray ? String(baseType.dropFirst().dropLast()) : baseType
                    relationshipInfo = PersistentStoredProperty.RelationshipInfo(deleteRule: deleteRule, destinationType: destType, inverseName: inverseName)
                }
            }

            properties.append(
                PersistentStoredProperty(
                    name: identifier,
                    type: type,
                    baseType: baseType,
                    isOptional: isOptional,
                    attributeOptions: attributeOptions,
                    relationshipInfo: relationshipInfo
                )
            )
        }
        return properties
    }
}

private func persistentStoredProperties(
    in declaration: some DeclGroupSyntax
) -> [PersistentStoredProperty] {
    declaration.memberBlock.members
        .compactMap { $0.decl.as(VariableDeclSyntax.self) }
        .flatMap(\.persistentStoredProperties)
}

public struct ModelMacro: ExtensionMacro, MemberAttributeMacro, MemberMacro {
    public static func expansion(
        of node: AttributeSyntax,
        attachedTo declaration: some DeclGroupSyntax,
        providingExtensionsOf type: some TypeSyntaxProtocol,
        conformingTo protocols: [TypeSyntax],
        in context: some MacroExpansionContext
    ) throws -> [ExtensionDeclSyntax] {
        let decl: DeclSyntax = """
        extension \(type.trimmed): PersistentModel, _JsonDataSchemaProviding {}
        """
        guard let extensionDecl = decl.as(ExtensionDeclSyntax.self) else {
            return []
        }
        return [extensionDecl]
    }

    public static func expansion(
        of node: AttributeSyntax,
        attachedTo declaration: some DeclGroupSyntax,
        providingAttributesFor member: some DeclSyntaxProtocol,
        in context: some MacroExpansionContext
    ) throws -> [AttributeSyntax] {
        guard let varDecl = member.as(VariableDeclSyntax.self) else { return [] }
        guard !varDecl.persistentStoredProperties.isEmpty else { return [] }

        return ["@Field"]
    }

    public static func expansion(
            of node: AttributeSyntax,
            providingMembersOf declaration: some DeclGroupSyntax,
            conformingTo protocols: [TypeSyntax],
            in context: some MacroExpansionContext
        ) throws -> [DeclSyntax] {
            var assignments = ""
            let variables = persistentStoredProperties(in: declaration)
            for variable in variables {
                assignments += "self._\(variable.name) = other._\(variable.name)\n"
            }

            let typeName = declaration.as(ClassDeclSyntax.self)?.name.text ?? "Self"
            let tableNameDecl = "public static let _jsonDataTableName = \"\(typeName)\""
            
            let persistentVariables = variables.filter { !$0.attributeOptions.contains(".ephemeral") }
            
            let columnEntries = persistentVariables.map { variable in
                let optionsArray = variable.attributeOptions.isEmpty ? "" : ", options: [\(variable.attributeOptions.joined(separator: ", "))]"
                let kind = variable.attributeOptions.contains(where: { $0.contains(".externalStorage") }) ? "_JsonDataColumnKind.string" : variable.columnKind
                return "_JsonDataColumnInfo(propertyName: \"\(variable.name)\", columnName: \"\(variable.name)\", kind: \(kind), isOptional: \(variable.isOptional)\(optionsArray))"
            }.joined(separator: ",\n")
            let columnsDecl: String
            if columnEntries.isEmpty {
                columnsDecl = "public static let _jsonDataColumns: [_JsonDataColumnInfo] = []"
            } else {
                columnsDecl = """
                public static let _jsonDataColumns: [_JsonDataColumnInfo] = [
                \(columnEntries)
                ]
                """
            }
            
            let relationshipVariables = variables.filter { $0.relationshipInfo != nil }
            let relationshipEntries = relationshipVariables.map { variable in
                let info = variable.relationshipInfo!
                let inverseArg = info.inverseName != nil ? ", inverseName: \"\(info.inverseName!)\"" : ""
                return "_JsonDataRelationshipInfo(propertyName: \"\(variable.name)\", deleteRule: \(info.deleteRule), destinationType: \(info.destinationType).self\(inverseArg))"
            }.joined(separator: ",\n")
            
            let relationshipsDecl: String
            if relationshipEntries.isEmpty {
                relationshipsDecl = "public static let _jsonDataRelationships: [_JsonDataRelationshipInfo] = []"
            } else {
                relationshipsDecl = """
                public static let _jsonDataRelationships: [_JsonDataRelationshipInfo] = [
                \(relationshipEntries)
                ]
                """
            }
            
            func extractProperties(from macro: MacroExpansionDeclSyntax) -> [[String]] {
                var groups: [[String]] = []
                for arg in macro.arguments {
                    if let arrayExpr = arg.expression.as(ArrayExprSyntax.self) {
                        var props: [String] = []
                        for element in arrayExpr.elements {
                            if let keyPathExpr = element.expression.as(KeyPathExprSyntax.self) {
                                let str = keyPathExpr.trimmedDescription.replacingOccurrences(of: "\\", with: "").replacingOccurrences(of: ".", with: "")
                                props.append(str)
                            }
                        }
                        groups.append(props)
                    }
                }
                return groups
            }
            
            let indexMacros = declaration.memberBlock.members.compactMap { $0.decl.as(MacroExpansionDeclSyntax.self) }.filter { $0.macroName.text == "Index" }
            var indexGroups: [[String]] = []
            for m in indexMacros { indexGroups.append(contentsOf: extractProperties(from: m)) }
            
            let indexEntries = indexGroups.map { "_JsonDataIndexInfo(properties: \($0))" }.joined(separator: ",\n")
            let indexesDecl = indexEntries.isEmpty ? "public static let _jsonDataIndexes: [_JsonDataIndexInfo] = []" : """
            public static let _jsonDataIndexes: [_JsonDataIndexInfo] = [
            \(indexEntries)
            ]
            """
            
            let uniqueMacros = declaration.memberBlock.members.compactMap { $0.decl.as(MacroExpansionDeclSyntax.self) }.filter { $0.macroName.text == "Unique" }
            var uniqueGroups: [[String]] = []
            for m in uniqueMacros { uniqueGroups.append(contentsOf: extractProperties(from: m)) }
            
            let uniqueEntries = uniqueGroups.map { "_JsonDataUniqueInfo(properties: \($0))" }.joined(separator: ",\n")
            let uniquesDecl = uniqueEntries.isEmpty ? "public static let _jsonDataUniques: [_JsonDataUniqueInfo] = []" : """
            public static let _jsonDataUniques: [_JsonDataUniqueInfo] = [
            \(uniqueEntries)
            ]
            """
            let resolverBranches = variables.map { variable in
                "if keyPath == \\\(typeName).\(variable.name) { return \"\(variable.name)\" }"
            }.joined(separator: "\n")
            let resolverDecl: String
            if resolverBranches.isEmpty {
                resolverDecl = """
                public static func _jsonDataPropertyName(for keyPath: AnyKeyPath) -> String? {
                    return nil
                }
                """
            } else {
                resolverDecl = """
                public static func _jsonDataPropertyName(for keyPath: AnyKeyPath) -> String? {
                    \(resolverBranches)
                    return nil
                }
                """
            }
            
            let setValueBranches = variables.map { variable in
                let isArray = variable.baseType.hasPrefix("[") && variable.baseType.hasSuffix("]") && !variable.baseType.contains(":")
                let elementType = isArray ? String(variable.baseType.dropFirst().dropLast()) : variable.baseType
                let arrayBlock = isArray ? """
                    if let val = value as? \(elementType) {
                        var current = self.\(variable.name)
                        current.append(val)
                        self.\(variable.name) = current
                    } else 
                """ : ""
                
                return """
                if propertyName == "\(variable.name)" {
                    \(arrayBlock)if let val = value as? \(variable.type) {
                        self.\(variable.name) = val
                    } else if value == nil\(variable.isOptional ? "" : ", false") {
                    }
                    return
                }
                """
            }.joined(separator: "\n")
            
            let setValueDecl = """
            public func _jsonDataSetValue(_ value: Any?, forPropertyName propertyName: String) {
                \(setValueBranches)
            }
            """

            // ── Generate _toColumnValues ──
            let toColumnLines = persistentVariables.map { variable -> String in
                let name = variable.name
                let valExpr: String
                if variable.isOptional {
                    valExpr = "(self._\(name).value ?? self._\(name).defaultValue)?.flatMap { $0 }"
                } else {
                    valExpr = "(self._\(name).value ?? self._\(name).defaultValue)"
                }
                
                if variable.attributeOptions.contains(where: { $0.contains(".externalStorage") }) {
                    return """
                    if let data = \(valExpr) {
                        let encodedData: Data?
                        if let d = data as Any as? Data {
                            encodedData = d
                        } else {
                            encodedData = try? JSONEncoder().encode(data)
                        }
                        if let encodedData = encodedData, let context = context {
                            let ref = try context._saveExternalData(encodedData, modelID: self.persistentModelID, propertyName: "\(name)")
                            values["\(name)"] = ref
                        }
                    }
                    """
                }
                
                switch variable.baseType {
                case "String", "Int", "Double", "Data":
                    return "values[\"\(name)\"] = \(valExpr)"
                case "Bool":
                    return """
                    if let v = \(valExpr) { values["\(name)"] = v ? 1 : 0 }
                    """
                case "UUID":
                    return "values[\"\(name)\"] = (\(valExpr))?.uuidString"
                case "Date":
                    return "values[\"\(name)\"] = (\(valExpr)).map { ISO8601DateFormatter().string(from: $0) }"
                default:
                    // Use dynamic overload resolution to handle relationships OR codable types
                    return """
                    if let v = \(valExpr) {
                        if let jsonText = try? _jsonDataEncode(v) {
                            values["\(name)"] = jsonText
                        }
                    }
                    """
                }
            }.joined(separator: "\n")
            
            let toColumnValuesDecl = """
            public func _toColumnValues(context: ModelContext?) throws -> [String: Any?] {
                var values: [String: Any?] = [:]
                \(toColumnLines)
                return values
            }
            """

            // ── Generate _populateFromColumnValues ──
            let populateLines = persistentVariables.map { variable -> String in
                let name = variable.name
                
                if variable.attributeOptions.contains(where: { $0.contains(".externalStorage") }) {
                    let fetchRef = """
                        let refId_\(name): String?
                        if let r = values["\(name)"] as? String { refId_\(name) = r }
                        else if let d = values["\(name)"] as? Data { refId_\(name) = String(data: d, encoding: .utf8) }
                        else { refId_\(name) = nil }
                    """
                    
                    if variable.baseType == "Data" {
                        return """
                        \(fetchRef)
                        if let ref = refId_\(name), let ctx = context {
                            if let fileData = try? ctx._loadExternalData(from: ref) {
                                self._\(name) = Field(wrappedValue: fileData)
                            }
                        }
                        """
                    } else {
                        return """
                        \(fetchRef)
                        if let ref = refId_\(name), let ctx = context {
                            if let fileData = try? ctx._loadExternalData(from: ref),
                               let decoded = try? JSONDecoder().decode(\(variable.baseType).self, from: fileData) {
                                self._\(name) = Field(wrappedValue: decoded)
                            }
                        }
                        """
                    }
                }
                
                switch variable.baseType {
                case "String":
                    return """
                    if let v = values["\(name)"] as? String {
                        self._\(name) = Field(wrappedValue: v)
                    }
                    """
                case "Int":
                    return """
                    if let v = values["\(name)"] as? Int64 {
                        self._\(name) = Field(wrappedValue: Int(v))
                    } else if let v = values["\(name)"] as? Int {
                        self._\(name) = Field(wrappedValue: v)
                    }
                    """
                case "Double":
                    return """
                    if let v = values["\(name)"] as? Double {
                        self._\(name) = Field(wrappedValue: v)
                    }
                    """
                case "Bool":
                    return """
                    if let v = values["\(name)"] as? Int64 {
                        self._\(name) = Field(wrappedValue: v != 0)
                    } else if let v = values["\(name)"] as? Bool {
                        self._\(name) = Field(wrappedValue: v)
                    }
                    """
                case "UUID":
                    return """
                    if let v = values["\(name)"] as? String, let uuid = UUID(uuidString: v) {
                        self._\(name) = Field(wrappedValue: uuid)
                    }
                    """
                case "Date":
                    return """
                    if let v = values["\(name)"] as? String, let date = ISO8601DateFormatter().date(from: v) {
                        self._\(name) = Field(wrappedValue: date)
                    }
                    """
                case "Data":
                    return """
                    if let v = values["\(name)"] as? Data {
                        self._\(name) = Field(wrappedValue: v)
                    }
                    """
                default:
                    return """
                    if let json = values["\(name)"] as? String,
                       let decoded = try? _jsonDataDecode(\(variable.baseType).self, from: json, context: context) {
                        self._\(name) = Field(wrappedValue: decoded)
                    }
                    """
                }
            }.joined(separator: "\n")
            
            let populateDecl = """
            public func _populateFromColumnValues(_ values: [String: Any?], context: ModelContext?) {
                if let id = values["id"] as? String {
                    self.persistentModelID = PersistentIdentifier(id: id)
                }
                \(populateLines)
            }
            """

            return [
                "@ObservationIgnored public var _isSyncingInverse: Bool = false",
                "@ObservationIgnored private let _observationRegistrar = ObservationRegistrar()",
                "@ObservationIgnored public var persistentModelID: PersistentIdentifier = PersistentIdentifier(id: UUID().uuidString)",
                "@ObservationIgnored public var modelContext: ModelContext? { _modelContext }",
                "@ObservationIgnored public weak var _modelContext: ModelContext? = nil",
                "@ObservationIgnored public var _isFault: Bool = false",
                "@ObservationIgnored public var _isFaulting: Bool = false",
                """
                public func access<Member>(keyPath: KeyPath<\(raw: typeName), Member>) {
                    _observationRegistrar.access(self, keyPath: keyPath)
                }
                """,
                """
                public func withMutation<Member, Result>(
                    keyPath: KeyPath<\(raw: typeName), Member>,
                    _ mutation: () throws -> Result
                ) rethrows -> Result {
                    try _observationRegistrar.withMutation(of: self, keyPath: keyPath, mutation)
                }
                """,
                """
                public func fault() {
                    if _isFault {
                        _isFault = false
                        _isFaulting = true
                        defer { _isFaulting = false }
                        _modelContext?._faultIn(self)
                    }
                }
                """,
                """
                public func _copy(from other: any PersistentModel) {
                    guard let other = other as? \(raw: typeName) else { return }
                    \(raw: assignments)
                }
                """,
                """
                \(raw: {
                    var initBody = "self.persistentModelID = PersistentIdentifier(id: \"\")\n"
                    for variable in variables {
                        initBody += "self._\(variable.name) = Field<\(variable.type)>()\n"
                    }
                    return "public required init() {\n\(initBody)}"
                }())
                """,
                """
                \(raw: toColumnValuesDecl)
                """,
                """
                \(raw: populateDecl)
                """,
                """
                \(raw: tableNameDecl)
                """,
                """
                \(raw: columnsDecl)
                """,
                """
                \(raw: relationshipsDecl)
                """,
                """
                \(raw: resolverDecl)
                """,
                """
                \(raw: setValueDecl)
                """,
                """
                \(raw: indexesDecl)
                """,
                """
                \(raw: uniquesDecl)
                """
            ]
        }
}

public struct TransientMacro: PeerMacro {
    public static func expansion(
        of node: AttributeSyntax,
        providingPeersOf declaration: some DeclSyntaxProtocol,
        in context: some MacroExpansionContext
    ) throws -> [DeclSyntax] {
        []
    }
}

public struct AttributeMacro: PeerMacro {
    public static func expansion(
        of node: AttributeSyntax,
        providingPeersOf declaration: some DeclSyntaxProtocol,
        in context: some MacroExpansionContext
    ) throws -> [DeclSyntax] { [] }
}

public struct RelationshipMacro: PeerMacro {
    public static func expansion(
        of node: AttributeSyntax,
        providingPeersOf declaration: some DeclSyntaxProtocol,
        in context: some MacroExpansionContext
    ) throws -> [DeclSyntax] { [] }
}

public struct PredicateMacro: ExpressionMacro {
    public static func expansion(
        of node: some FreestandingMacroExpansionSyntax,
        in context: some MacroExpansionContext
    ) throws -> ExprSyntax {
        guard let closure = node.trailingClosure else {
            throw MacroError("Predicate macro requires a trailing closure")
        }
        
        var parser = PredicateClosureParser(closure: closure)
        let parsed = try parser.parse()
        
        let argsString = parsed.1.map { "\($0)" }.joined(separator: ", ")
        
        return "JsonDataCore.Predicate(sql: \"\(raw: parsed.0)\", arguments: [\(raw: argsString)])"
    }
}

private struct PredicateClosureParser {
    let closure: ClosureExprSyntax
    var sql: String = ""
    var arguments: [String] = []
    
    var closureParamName: String = "$0"

    mutating func parse() throws -> (String, [String]) {
        if let signature = closure.signature {
            if let paramList = signature.parameterClause?.as(ClosureShorthandParameterListSyntax.self) {
                closureParamName = paramList.first?.name.text ?? "$0"
            } else if let paramClause = signature.parameterClause?.as(ClosureParameterClauseSyntax.self) {
                if let param = paramClause.parameters.first {
                    closureParamName = param.secondName?.text ?? param.firstName.text
                }
            }
        }

        let statements = closure.statements
        guard statements.count == 1, let expr = statements.first?.item.as(ExprSyntax.self) else {
            throw MacroError("Predicate closure must contain a single expression")
        }
        
        try parseExpr(expr)
        return (sql, arguments)
    }

    private func getModelProperty(from expr: ExprSyntax) -> String? {
        var current: ExprSyntax = expr

        while true {
            if let memberAccess = current.as(MemberAccessExprSyntax.self) {
                if let base = memberAccess.base {
                    if base.trimmedDescription == closureParamName {
                        let name = memberAccess.declName.baseName.text
                        if name == "persistentModelID" {
                            return "_id"
                        }
                        return name
                    }
                    current = base
                } else {
                    return nil
                }
            } else if let optChain = current.as(OptionalChainingExprSyntax.self) {
                current = optChain.expression
            } else if let forceUnwrap = current.as(ForceUnwrapExprSyntax.self) {
                current = forceUnwrap.expression
            } else {
                return nil
            }
        }
    }

    mutating func parseExpr(_ expr: ExprSyntax) throws {
        if let tuple = expr.as(TupleExprSyntax.self), tuple.elements.count == 1, let first = tuple.elements.first {
            sql += "("
            try parseExpr(first.expression)
            sql += ")"
        } else if let infix = expr.as(InfixOperatorExprSyntax.self) {
            sql += "("
            try parseExpr(infix.leftOperand)
            sql += " "
            
            let isNilOperand = infix.rightOperand.as(NilLiteralExprSyntax.self) != nil || infix.rightOperand.trimmedDescription == "nil"
            
            let op = infix.operator.trimmedDescription
            switch op {
            case "==": sql += isNilOperand ? "IS" : "="
            case "!=": sql += isNilOperand ? "IS NOT" : "!="
            case "<", ">", "<=", ">=": sql += op
            case "&&": sql += "AND"
            case "||": sql += "OR"
            default: throw MacroError("Unsupported operator \(op)")
            }
            
            sql += " "
            if isNilOperand {
                sql += "NULL"
            } else {
                try parseExpr(infix.rightOperand)
            }
            sql += ")"
        } else if let propName = getModelProperty(from: expr) {
            sql += "\\\"\(propName)\\\""
        } else if let prefix = expr.as(PrefixOperatorExprSyntax.self) {
            let op = prefix.operator.trimmedDescription
            if op == "!" {
                sql += "NOT ("
                try parseExpr(prefix.expression)
                sql += ")"
            } else {
                throw MacroError("Unsupported prefix operator \\(op)")
            }
        } else if let call = expr.as(FunctionCallExprSyntax.self),
                  let member = call.calledExpression.as(MemberAccessExprSyntax.self),
                  let base = member.base,
                  let memberAccess = base.as(MemberAccessExprSyntax.self),
                  let memberBase = memberAccess.base,
                  memberBase.trimmedDescription == closureParamName {
            
            let propName = memberAccess.declName.baseName.text
            let funcName = member.declName.baseName.text
            
            guard let argExpr = call.arguments.first?.expression else {
                throw MacroError("Missing argument for \\(funcName)")
            }
            
            if funcName == "contains" {
                sql += "\\\"\(propName)\\\" LIKE ('%' || ? || '%')"
                arguments.append(argExpr.trimmedDescription)
            } else if funcName == "hasPrefix" || funcName == "starts" {
                sql += "\\\"\(propName)\\\" LIKE (? || '%')"
                arguments.append(argExpr.trimmedDescription)
            } else if funcName == "hasSuffix" || funcName == "ends" {
                sql += "\\\"\(propName)\\\" LIKE ('%' || ?)"
                arguments.append(argExpr.trimmedDescription)
            } else {
                throw MacroError("Unsupported function \(funcName)")
            }
        } else {
            sql += "?"
            arguments.append(expr.trimmedDescription)
        }
    }
}

public struct IndexMacro: DeclarationMacro {
    public static func expansion(
        of node: some FreestandingMacroExpansionSyntax,
        in context: some MacroExpansionContext
    ) throws -> [DeclSyntax] {
        return []
    }
}

public struct UniqueMacro: DeclarationMacro {
    public static func expansion(
        of node: some FreestandingMacroExpansionSyntax,
        in context: some MacroExpansionContext
    ) throws -> [DeclSyntax] {
        return []
    }
}

@main
struct JsonDataPlugin: CompilerPlugin {

    let providingMacros: [Macro.Type] = [
        ModelMacro.self,
        TransientMacro.self,
        AttributeMacro.self,
        RelationshipMacro.self,
        PredicateMacro.self,
        IndexMacro.self,
        UniqueMacro.self
    ]
}
