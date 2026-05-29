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
            var codingKeys = "enum CodingKeys: String, CodingKey {\n  case persistentModelID\n"
            var assignments = ""
            let variables = persistentStoredProperties(in: declaration)
            for variable in variables {
                codingKeys += "  case \(variable.name)\n"
                assignments += "self._\(variable.name) = other._\(variable.name)\n"
            }
            codingKeys += "}\n"

            let typeName = declaration.as(ClassDeclSyntax.self)?.name.text ?? "Self"
            let tableNameDecl = "public static let _jsonDataTableName = \"\(typeName)\""
            
            let persistentVariables = variables.filter { !$0.attributeOptions.contains(".ephemeral") }
            
            let columnEntries = persistentVariables.map { variable in
                let optionsArray = variable.attributeOptions.isEmpty ? "" : ", options: [\(variable.attributeOptions.joined(separator: ", "))]"
                return "_JsonDataColumnInfo(propertyName: \"\(variable.name)\", columnName: \"\(variable.name)\", kind: \(variable.columnKind), isOptional: \(variable.isOptional)\(optionsArray))"
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
                public required init(from decoder: Decoder) throws {
                    let container = try decoder.container(keyedBy: CodingKeys.self)
                    self.persistentModelID = try container.decode(PersistentIdentifier.self, forKey: .persistentModelID)
                    \(raw: persistentVariables.map { variable in
                        if variable.attributeOptions.contains(where: { $0.contains(".externalStorage") }) {
                            return """
                                if let context = decoder.userInfo[.modelContext] as? ModelContext, let ref = try? container.decode(String.self, forKey: .\(variable.name)) {
                                    if let data = try? context._loadExternalData(from: ref) as? \(variable.type) {
                                        self._\(variable.name) = Field(wrappedValue: data)
                                    } else {
                                        self._\(variable.name) = Field()
                                    }
                                } else {
                                    self._\(variable.name) = try container.decode(Field<\(variable.type)>.self, forKey: .\(variable.name))
                                }
                                """
                        } else {
                            return "self._\(variable.name) = try container.decode(Field<\(variable.type)>.self, forKey: .\(variable.name))"
                        }
                    }.joined(separator: "\n"))
                    \(raw: variables.filter { $0.attributeOptions.contains(".ephemeral") }.map { variable in
                        "self._\(variable.name) = Field<\(variable.type)>()"
                    }.joined(separator: "\n"))
                }
                """,
                """
                public func encode(to encoder: Encoder) throws {
                    var container = encoder.container(keyedBy: CodingKeys.self)
                    try container.encode(self.persistentModelID, forKey: .persistentModelID)
                    \(raw: persistentVariables.map { variable in
                        if variable.attributeOptions.contains(where: { $0.contains(".externalStorage") }) {
                            return """
                                if let context = encoder.userInfo[.modelContext] as? ModelContext, let data = self._\(variable.name).value {
                                    let ref = try context._saveExternalData(data, modelID: self.persistentModelID, propertyName: "\(variable.name)")
                                    try container.encode(ref, forKey: .\(variable.name))
                                } else {
                                    try container.encode(self._\(variable.name), forKey: .\(variable.name))
                                }
                                """
                        } else {
                            return "try container.encode(self._\(variable.name), forKey: .\(variable.name))"
                        }
                    }.joined(separator: "\n"))
                }
                """,
                """
                \(raw: codingKeys)
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

    mutating func parseExpr(_ expr: ExprSyntax) throws {
        if let tuple = expr.as(TupleExprSyntax.self), tuple.elements.count == 1, let first = tuple.elements.first {
            sql += "("
            try parseExpr(first.expression)
            sql += ")"
        } else if let infix = expr.as(InfixOperatorExprSyntax.self) {
            sql += "("
            try parseExpr(infix.leftOperand)
            sql += " "
            
            let op = infix.operator.trimmedDescription
            switch op {
            case "==": sql += "="
            case "!=": sql += "!="
            case "<", ">", "<=", ">=": sql += op
            case "&&": sql += "AND"
            case "||": sql += "OR"
            default: throw MacroError("Unsupported operator \\(op)")
            }
            
            sql += " "
            try parseExpr(infix.rightOperand)
            sql += ")"
        } else if let member = expr.as(MemberAccessExprSyntax.self) {
            if let base = member.base, base.trimmedDescription == closureParamName {
                let propName = member.declName.baseName.text
                sql += "\\\"\(propName)\\\""
            } else {
                sql += "?"
                arguments.append(expr.trimmedDescription)
            }
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
