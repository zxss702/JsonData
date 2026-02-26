import SwiftCompilerPlugin
import SwiftSyntax
import SwiftSyntaxBuilder
import SwiftSyntaxMacros

public struct ModelMacro: ExtensionMacro, MemberAttributeMacro, MemberMacro {
    public static func expansion(
        of node: AttributeSyntax,
        attachedTo declaration: some DeclGroupSyntax,
        providingExtensionsOf type: some TypeSyntaxProtocol,
        conformingTo protocols: [TypeSyntax],
        in context: some MacroExpansionContext
    ) throws -> [ExtensionDeclSyntax] {
        let decl: DeclSyntax = """
        extension \(type.trimmed): PersistentModel, Codable {}
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
        let hasAccessor = varDecl.bindings.contains { binding in
            binding.accessorBlock != nil
        }
        if hasAccessor { return [] }
        
        return ["@Field"]
    }
    
    public static func expansion(
        of node: AttributeSyntax,
        providingMembersOf declaration: some DeclGroupSyntax,
        conformingTo protocols: [TypeSyntax],
        in context: some MacroExpansionContext
    ) throws -> [DeclSyntax] {
        // 收集所有用户声明的存储属性
        var codingKeys = "enum CodingKeys: String, CodingKey {\n  case persistentModelID\n"
        var assignments = ""
        let variables = declaration.memberBlock.members.compactMap { $0.decl.as(VariableDeclSyntax.self) }
        for v in variables {
            let hasAccessor = v.bindings.contains { $0.accessorBlock != nil }
            if !hasAccessor {
                for binding in v.bindings {
                    if let ident = binding.pattern.as(IdentifierPatternSyntax.self)?.identifier.text {
                        codingKeys += "  case \(ident)\n"
                        assignments += "self.\(ident) = other.\(ident)\n"
                    }
                }
            }
        }
        codingKeys += "}\n"
        let typeName = declaration.as(ClassDeclSyntax.self)?.name.text ?? "Self"
        
        return [
            "public var persistentModelID: String = UUID().uuidString",
            "public weak var _modelContext: ModelContext? = nil",
            "public var _isFault: Bool = false",
            "public var _isFaulting: Bool = false",
            "public let didChange = SwiftCrossUI.Publisher()",
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
                // 生成 fault 空壳用的 init()，需要初始化所有 stored properties
                var initBody = "self.persistentModelID = \"\"\n"
                for v in variables {
                    let hasAccessor = v.bindings.contains { $0.accessorBlock != nil }
                    if !hasAccessor {
                        if let name = v.bindings.first?.pattern.as(IdentifierPatternSyntax.self)?.identifier.text {
                            initBody += "self._\(name) = Field()\n"
                        }
                    }
                }
                return "public required init() {\n\(initBody)}"
            }())
            """,
            """
            public required init(from decoder: Decoder) throws {
                let container = try decoder.container(keyedBy: CodingKeys.self)
                self.persistentModelID = try container.decode(String.self, forKey: .persistentModelID)
                \(raw: variables.filter { v in
                    let hasAccessor = v.bindings.contains { $0.accessorBlock != nil }
                    return !hasAccessor
                }.map { v in 
                    let name = v.bindings.first!.pattern.as(IdentifierPatternSyntax.self)!.identifier.text
                    let type = v.bindings.first!.typeAnnotation!.type.trimmedDescription
                    return "self._\(name) = try container.decode(Field<\(type)>.self, forKey: .\(name))" 
                }.joined(separator: "\n"))
            }
            """,
            """
            \(raw: codingKeys)
            """
        ]
    }
}

@main
struct JsonDataPlugin: CompilerPlugin {
    let providingMacros: [Macro.Type] = [
        ModelMacro.self,
    ]
}
