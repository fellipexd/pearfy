import SwiftDiagnostics
import SwiftSyntax
import SwiftSyntaxBuilder
import SwiftSyntaxMacros

public struct EntityMacro: MemberMacro {
    public static func expansion(
        of node: AttributeSyntax,
        providingMembersOf declaration: some DeclGroupSyntax,
        conformingTo _: [TypeSyntax],
        in context: some MacroExpansionContext
    ) throws -> [DeclSyntax] {
        guard let structure = declaration.as(StructDeclSyntax.self) else {
            context.diagnose(Diagnostic(
                node: Syntax(declaration),
                message: EntityMacroMessage("@Entity currently supports structs")
            ))
            return []
        }
        guard let table = firstStringArgument(in: node), !table.isEmpty else {
            context.diagnose(Diagnostic(
                node: Syntax(node),
                message: EntityMacroMessage("@Entity requires a literal table name")
            ))
            return []
        }

        var columns: [String] = []
        for member in structure.memberBlock.members {
            guard let variable = member.decl.as(VariableDeclSyntax.self) else { continue }
            for binding in variable.bindings {
                guard let pattern = binding.pattern.as(IdentifierPatternSyntax.self) else {
                    context.diagnose(Diagnostic(
                        node: Syntax(binding.pattern),
                        message: EntityMacroMessage("@Entity properties must use simple identifier patterns")
                    ))
                    return []
                }
                guard binding.accessorBlock == nil else {
                    context.diagnose(Diagnostic(
                        node: Syntax(binding),
                        message: EntityMacroMessage("@Entity properties must be stored properties")
                    ))
                    return []
                }
                guard let annotation = binding.typeAnnotation else {
                    context.diagnose(Diagnostic(
                        node: Syntax(binding),
                        message: EntityMacroMessage("@Entity properties require explicit types")
                    ))
                    return []
                }

                let attributes = variable.attributes.compactMap { element -> AttributeSyntax? in
                    guard case .attribute(let attribute) = element else { return nil }
                    return attribute
                }
                let idAttribute = attributes.first(where: { attributeName($0) == "ID" })
                let columnAttribute = attributes.first(where: { attributeName($0) == "Column" })
                let dbName = columnAttribute.flatMap { stringArgument("name", in: $0) } ?? pattern.identifier.text
                let swiftType = annotation.type.trimmedDescription
                let isOptional = swiftType.hasSuffix("?")
                let baseType = isOptional ? String(swiftType.dropLast()) : swiftType
                let typeArguments = columnAttribute.map(columnOptions) ?? ColumnOptions()
                guard let schemaType = schemaType(
                    for: baseType,
                    precision: typeArguments.precision,
                    scale: typeArguments.scale
                ) else {
                    context.diagnose(Diagnostic(
                        node: Syntax(annotation.type),
                        message: EntityMacroMessage("unsupported @Entity property type '\(swiftType)'")
                    ))
                    return []
                }

                let strategy: String?
                if let idAttribute {
                    strategy = identifierStrategy(in: idAttribute, type: schemaType, context: context)
                    guard strategy != nil else { return [] }
                } else {
                    strategy = nil
                }
                let nullable = typeArguments.nullable ?? isOptional
                if idAttribute != nil && nullable {
                    context.diagnose(Diagnostic(
                        node: Syntax(binding),
                        message: EntityMacroMessage("@ID properties cannot be optional or nullable")
                    ))
                    return []
                }

                columns.append("""
                PearfyData.SchemaColumn(
                    name: "\(swiftString(dbName))",
                    type: \(schemaType),
                    nullable: \(nullable),
                    primaryKey: \(idAttribute != nil),
                    unique: \(typeArguments.unique),
                    renamedFrom: \(typeArguments.renamedFrom.map { "\"\(swiftString($0))\"" } ?? "nil"),
                    identifierStrategy: \(strategy ?? "nil")
                )
                """)
            }
        }

        guard !columns.isEmpty else {
            context.diagnose(Diagnostic(
                node: Syntax(declaration),
                message: EntityMacroMessage("@Entity requires at least one stored property")
            ))
            return []
        }

        return [DeclSyntax(stringLiteral: """
        static var __pearfy_schema: PearfyData.SchemaEntity {
            PearfyData.SchemaEntity(table: "\(swiftString(table))", columns: [
                \(columns.joined(separator: ",\n                "))
            ])
        }
        """)]
    }

    private struct ColumnOptions {
        var nullable: Bool?
        var unique = false
        var precision: Int?
        var scale: Int?
        var renamedFrom: String?
    }

    private static func columnOptions(_ attribute: AttributeSyntax) -> ColumnOptions {
        ColumnOptions(
            nullable: boolArgument("nullable", in: attribute),
            unique: boolArgument("unique", in: attribute) ?? false,
            precision: integerArgument("precision", in: attribute),
            scale: integerArgument("scale", in: attribute),
            renamedFrom: stringArgument("renamedFrom", in: attribute)
        )
    }

    private static func schemaType(for rawType: String, precision: Int?, scale: Int?) -> String? {
        let type = rawType.split(separator: ".").last.map(String.init) ?? rawType
        switch type {
        case "String": return ".text"
        case "Int", "Int64": return ".bigInteger"
        case "Int32": return ".integer"
        case "Bool": return ".boolean"
        case "UUID": return ".uuid"
        case "Date": return ".timestampWithTimeZone"
        case "Data": return ".binary"
        case "Decimal":
            guard let precision, let scale, precision > 0, scale >= 0, scale <= precision else { return nil }
            return ".decimal(precision: \(precision), scale: \(scale))"
        default: return nil
        }
    }

    private static func identifierStrategy(
        in attribute: AttributeSyntax,
        type: String,
        context: some MacroExpansionContext
    ) -> String? {
        if let expression = argument("strategy", in: attribute)?.trimmedDescription {
            let name = expression.split(separator: ".").last.map(String.init) ?? expression
            let supported: Set<String> = ["uuidV7", "uuidV6", "uuidV5", "uuidV4", "assigned", "autoIncrement"]
            guard supported.contains(name) else {
                context.diagnose(Diagnostic(
                    node: Syntax(attribute),
                    message: EntityMacroMessage("unsupported @ID strategy '\(expression)'")
                ))
                return nil
            }
            if name.hasPrefix("uuid"), type != ".uuid" {
                context.diagnose(Diagnostic(
                    node: Syntax(attribute),
                    message: EntityMacroMessage("UUID @ID strategies require a UUID property")
                ))
                return nil
            }
            if name == "autoIncrement", type != ".integer" && type != ".bigInteger" {
                context.diagnose(Diagnostic(
                    node: Syntax(attribute),
                    message: EntityMacroMessage("autoIncrement requires an integer property")
                ))
                return nil
            }
            return "PearfyData.SchemaIdentifierStrategy.\(name)"
        }

        switch type {
        case ".uuid": return "PearfyData.SchemaIdentifierStrategy.uuidV7"
        case ".integer", ".bigInteger": return "PearfyData.SchemaIdentifierStrategy.autoIncrement"
        default:
            context.diagnose(Diagnostic(
                node: Syntax(attribute),
                message: EntityMacroMessage("@ID on this type requires an explicit supported strategy")
            ))
            return nil
        }
    }

    private static func argument(_ label: String, in attribute: AttributeSyntax) -> ExprSyntax? {
        guard case .argumentList(let arguments) = attribute.arguments else { return nil }
        return arguments.first(where: { $0.label?.text == label })?.expression
    }

    private static func boolArgument(_ label: String, in attribute: AttributeSyntax) -> Bool? {
        guard let expression = argument(label, in: attribute) else { return nil }
        switch expression.trimmedDescription {
        case "true": return true
        case "false": return false
        default: return nil
        }
    }

    private static func integerArgument(_ label: String, in attribute: AttributeSyntax) -> Int? {
        guard let expression = argument(label, in: attribute) else { return nil }
        return Int(expression.trimmedDescription.replacingOccurrences(of: "_", with: ""))
    }

    private static func stringArgument(_ label: String, in attribute: AttributeSyntax) -> String? {
        guard let expression = argument(label, in: attribute),
              let literal = expression.as(StringLiteralExprSyntax.self) else { return nil }
        var value = ""
        for segment in literal.segments {
            guard case .stringSegment(let string) = segment else { return nil }
            value += string.content.text
        }
        return value
    }

    private static func firstStringArgument(in attribute: AttributeSyntax) -> String? {
        guard case .argumentList(let arguments) = attribute.arguments,
              let expression = arguments.first?.expression,
              let literal = expression.as(StringLiteralExprSyntax.self) else { return nil }
        var value = ""
        for segment in literal.segments {
            guard case .stringSegment(let string) = segment else { return nil }
            value += string.content.text
        }
        return value
    }

    private static func attributes<S: SyntaxProtocol & WithAttributesSyntax>(on syntax: S) -> [AttributeSyntax] {
        syntax.attributes.compactMap { element in
            guard case .attribute(let attribute) = element else { return nil }
            return attribute
        }
    }

    private static func attributeName(_ attribute: AttributeSyntax) -> String {
        attribute.attributeName.trimmedDescription.split(separator: ".").last.map(String.init) ?? ""
    }

    private static func swiftString(_ value: String) -> String {
        value.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }
}

private struct EntityMacroMessage: DiagnosticMessage {
    let message: String

    init(_ message: String) { self.message = message }

    var diagnosticID: MessageID { MessageID(domain: "PearfyEntityMacro", id: message) }
    var severity: DiagnosticSeverity { .error }
}
