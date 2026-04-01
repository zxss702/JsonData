import SwiftCompilerPlugin
import SwiftSyntax
import SwiftSyntaxBuilder
import SwiftSyntaxMacros

private struct PersistentStoredProperty {
    let name: String
    let type: String
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
        return bindings.compactMap { binding in
            guard
                let identifier = binding.pattern.as(IdentifierPatternSyntax.self)?.identifier.text,
                let type = binding.typeAnnotation?.type.trimmedDescription
            else {
                return nil
            }
            return PersistentStoredProperty(name: identifier, type: type)
        }
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
        extension \(type.trimmed): PersistentModel {}
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
            assignments += "self.\(variable.name) = other.\(variable.name)\n"
        }
        codingKeys += "}\n"
        let typeName = declaration.as(ClassDeclSyntax.self)?.name.text ?? "Self"
        
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

@main
struct JsonDataPlugin: CompilerPlugin {
    let providingMacros: [Macro.Type] = [
        ModelMacro.self,
        TransientMacro.self,
    ]
}
