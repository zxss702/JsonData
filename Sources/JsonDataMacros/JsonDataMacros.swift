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
                    if let arguments = attribute.arguments?.as(LabeledExprListSyntax.self) {
                        for arg in arguments {
                            if arg.label?.text == "deleteRule" {
                                let expr = arg.expression.trimmedDescription
                                if expr.hasSuffix(".cascade") || expr == "cascade" { deleteRule = ".cascade" }
                                else if expr.hasSuffix(".deny") || expr == "deny" { deleteRule = ".deny" }
                            }
                        }
                    }
                    relationshipInfo = PersistentStoredProperty.RelationshipInfo(deleteRule: deleteRule, destinationType: baseType)
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
            let tableNameDecl = "internal static let _jsonDataTableName = \"\(typeName)\""
            
            let persistentVariables = variables.filter { !$0.attributeOptions.contains(".ephemeral") }
            
            let columnEntries = persistentVariables.map { variable in
                let optionsArray = variable.attributeOptions.isEmpty ? "" : ", options: [\(variable.attributeOptions.joined(separator: ", "))]"
                return "_JsonDataColumnInfo(propertyName: \"\(variable.name)\", columnName: \"\(variable.name)\", kind: \(variable.columnKind), isOptional: \(variable.isOptional)\(optionsArray))"
            }.joined(separator: ",\n")
            let columnsDecl: String
            if columnEntries.isEmpty {
                columnsDecl = "internal static let _jsonDataColumns: [_JsonDataColumnInfo] = []"
            } else {
                columnsDecl = """
                internal static let _jsonDataColumns: [_JsonDataColumnInfo] = [
                \(columnEntries)
                ]
                """
            }
            
            let relationshipVariables = variables.filter { $0.relationshipInfo != nil }
            let relationshipEntries = relationshipVariables.map { variable in
                let info = variable.relationshipInfo!
                return "_JsonDataRelationshipInfo(propertyName: \"\(variable.name)\", deleteRule: \(info.deleteRule), destinationType: \(info.destinationType).self)"
            }.joined(separator: ",\n")
            
            let relationshipsDecl: String
            if relationshipEntries.isEmpty {
                relationshipsDecl = "internal static let _jsonDataRelationships: [_JsonDataRelationshipInfo] = []"
            } else {
                relationshipsDecl = """
                internal static let _jsonDataRelationships: [_JsonDataRelationshipInfo] = [
                \(relationshipEntries)
                ]
                """
            }
            let resolverBranches = variables.map { variable in
                "if keyPath == \\\(typeName).\(variable.name) { return \"\(variable.name)\" }"
            }.joined(separator: "\n")
            let resolverDecl: String
            if resolverBranches.isEmpty {
                resolverDecl = """
                internal static func _jsonDataPropertyName(for keyPath: AnyKeyPath) -> String? {
                    return nil
                }
                """
            } else {
                resolverDecl = """
                internal static func _jsonDataPropertyName(for keyPath: AnyKeyPath) -> String? {
                    \(resolverBranches)
                    return nil
                }
                """
            }

            return [
                "@ObservationIgnored private let _observationRegistrar = ObservationRegistrar()",
                "@ObservationIgnored public var persistentModelID: String = UUID().uuidString",
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
                    var initBody = "self.persistentModelID = \"\"\n"
                    for variable in variables {
                        initBody += "self._\(variable.name) = Field()\n"
                    }
                    return "public required init() {\n\(initBody)}"
                }())
                """,
                """
                public required init(from decoder: Decoder) throws {
                    let container = try decoder.container(keyedBy: CodingKeys.self)
                    self.persistentModelID = try container.decode(String.self, forKey: .persistentModelID)
                    \(raw: variables.map { variable in
                        "self._\(variable.name) = try container.decode(Field<\(variable.type)>.self, forKey: .\(variable.name))"
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
        
        return "JsonData.Predicate(sql: \"\(raw: parsed.0)\", arguments: [\(raw: argsString)])"
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
        if let infix = expr.as(InfixOperatorExprSyntax.self) {
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
        } else {
            sql += "?"
            arguments.append(expr.trimmedDescription)
        }
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
    ]
}
