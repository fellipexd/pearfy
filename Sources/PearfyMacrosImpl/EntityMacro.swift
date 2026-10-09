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
        guard let argument = firstArgument(in: node) else {
            context.diagnose(Diagnostic(
                node: Syntax(node),
                message: EntityMacroMessage("@Entity requires a table name or Pearfy SchemaEntity model")
            ))
            return []
        }
        if argument.as(StringLiteralExprSyntax.self) == nil {
            let hasRelationship = structure.memberBlock.members.contains { member in
                guard let variable = member.decl.as(VariableDeclSyntax.self) else { return false }
                return attributes(on: variable).contains { ["ManyToOne", "OneToOne", "OneToMany", "ManyToMany"].contains(attributeName($0)) }
            }
            if hasRelationship {
                context.diagnose(Diagnostic(
                    node: Syntax(node),
                    message: EntityMacroMessage("relationship macros require @Entity(\"table\") so Pearfy can validate and materialize their schema metadata")
                ))
                return []
            }
            return [DeclSyntax(stringLiteral: """
            static var __pearfy_schema: PearfyData.SchemaEntity {
                \(argument.trimmedDescription)
            }
            """)]
        }
        guard let table = stringLiteral(argument), !table.isEmpty else {
            context.diagnose(Diagnostic(
                node: Syntax(node),
                message: EntityMacroMessage("@Entity requires a literal table name or a SchemaEntity expression")
            ))
            return []
        }

        var columns: [String] = []
        var relationships: [String] = []
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

                let attributes = attributes(on: variable)
                let idAttribute = attributes.first(where: { attributeName($0) == "ID" })
                let columnAttribute = attributes.first(where: { attributeName($0) == "Column" })
                let relationAttributes = attributes.filter { ["ManyToOne", "OneToOne", "OneToMany", "ManyToMany"].contains(attributeName($0)) }
                guard relationAttributes.count <= 1 else {
                    context.diagnose(Diagnostic(node: Syntax(binding), message: EntityMacroMessage("a property can declare only one relationship macro")))
                    return []
                }
                if let relationship = relationAttributes.first {
                    guard variable.bindings.count == 1, idAttribute == nil, columnAttribute == nil else {
                        context.diagnose(Diagnostic(node: Syntax(binding), message: EntityMacroMessage("relationship properties cannot combine @ID or @Column; use primaryKey: true on an owning relationship to include its foreign-key column in the entity key")))
                        return []
                    }
                    guard let targetTable = stringArgument("targetTable", in: relationship), !targetTable.isEmpty else {
                        context.diagnose(Diagnostic(node: Syntax(relationship), message: EntityMacroMessage("relationship macros require a non-empty literal targetTable")))
                        return []
                    }
                    let kind = attributeName(relationship)
                    let rawType = annotation.type.trimmedDescription
                    let optional = rawType.hasSuffix("?")
                    let baseType = optional ? String(rawType.dropLast()) : rawType
                    let mappedBy = stringArgument("mappedBy", in: relationship)
                    let inverse = mappedBy != nil
                    let relationshipPrimaryKey = boolArgument("primaryKey", in: relationship) ?? false
                    if Self.argument("primaryKey", in: relationship) != nil,
                       boolArgument("primaryKey", in: relationship) == nil {
                        context.diagnose(Diagnostic(node: Syntax(relationship), message: EntityMacroMessage("primaryKey must be a literal true or false")))
                        return []
                    }
                    let isCollection = kind == "OneToMany" || kind == "ManyToMany"
                    let relatedValueType = isCollection ? arrayElementType(baseType) : baseType
                    if let relatedValueType, schemaType(for: relatedValueType, precision: nil, scale: nil) != nil {
                        context.diagnose(Diagnostic(node: Syntax(annotation.type), message: EntityMacroMessage("relationship properties must reference an entity type, not a scalar schema type")))
                        return []
                    }
                    if kind == "OneToMany" || kind == "ManyToMany" {
                        guard arrayElementType(baseType) != nil, kind == "ManyToMany" || mappedBy != nil else {
                            context.diagnose(Diagnostic(node: Syntax(annotation.type), message: EntityMacroMessage(kind == "OneToMany" ? "@OneToMany requires an array property and an explicit mappedBy" : "@ManyToMany requires an array property")))
                            return []
                        }
                    } else {
                        guard arrayElementType(baseType) == nil else {
                            context.diagnose(Diagnostic(node: Syntax(annotation.type), message: EntityMacroMessage("@\(kind) requires one entity value, optionally wrapped in Optional")))
                            return []
                        }
                    }
                    if kind == "ManyToOne", mappedBy != nil {
                        context.diagnose(Diagnostic(node: Syntax(relationship), message: EntityMacroMessage("@ManyToOne owns its foreign key and does not accept mappedBy")))
                        return []
                    }
                    if relationshipPrimaryKey {
                        guard kind == "ManyToOne" || kind == "OneToOne", !inverse else {
                            context.diagnose(Diagnostic(node: Syntax(relationship), message: EntityMacroMessage("primaryKey: true is supported only on an owning @ManyToOne or @OneToOne relationship")))
                            return []
                        }
                        let nullable = boolArgument("nullable", in: relationship) ?? optional
                        guard !nullable else {
                            context.diagnose(Diagnostic(node: Syntax(relationship), message: EntityMacroMessage("a relationship primary-key column must be non-null; use a non-optional property or nullable: false")))
                            return []
                        }
                    }
                    if kind == "OneToMany" {
                        let invalidOwnerOptions = ["column", "referencedColumn", "foreignKeyName", "nullable", "primaryKey", "onUpdate", "onDelete"].contains { label in
                            Self.argument(label, in: relationship) != nil
                        }
                        if invalidOwnerOptions {
                            context.diagnose(Diagnostic(node: Syntax(relationship), message: EntityMacroMessage("@OneToMany is inverse-only; configure the foreign key on the owning @ManyToOne")))
                            return []
                        }
                    } else if kind == "OneToOne", inverse {
                        let invalidOwnerOptions = ["column", "referencedColumn", "foreignKeyName", "nullable", "primaryKey", "onUpdate", "onDelete"].contains { label in
                            Self.argument(label, in: relationship) != nil
                        }
                        if invalidOwnerOptions {
                            context.diagnose(Diagnostic(node: Syntax(relationship), message: EntityMacroMessage("inverse @OneToOne cannot configure owner-side foreign-key options")))
                            return []
                        }
                    }
                    let onUpdate = referentialAction("onUpdate", in: relationship, context: context)
                    let onDelete = referentialAction("onDelete", in: relationship, context: context)
                    guard onUpdate != nil, onDelete != nil else { return [] }
                    let nullable = boolArgument("nullable", in: relationship) ?? optional
                    let field = pattern.identifier.text
                    let schemaKind: String = switch kind {
                    case "ManyToOne": ".manyToOne"
                    case "OneToOne": ".oneToOne"
                    case "OneToMany": ".oneToMany"
                    default: ".manyToMany"
                    }
                    let relationKind = schemaKind
                    let defaultColumn = kind == "OneToMany" || kind == "ManyToMany" || inverse ? "nil" : stringArgument("column", in: relationship).map { "\"\(swiftString($0))\"" } ?? "nil"
                    let referencedColumn = stringArgument("referencedColumn", in: relationship).map { "\"\(swiftString($0))\"" } ?? "\"id\""
                    let foreignKeyNameLabel = kind == "ManyToMany" ? "joinForeignKeyName" : "foreignKeyName"
                    let foreignKeyName = stringArgument(foreignKeyNameLabel, in: relationship).map { "\"\(swiftString($0))\"" } ?? "nil"
                    let manyToManyOptions = kind == "ManyToMany"
                    let optionOrNil: (String) -> String = { label in
                        guard manyToManyOptions, !inverse, let value = stringArgument(label, in: relationship) else { return "nil" }
                        return "\"\(swiftString(value))\""
                    }
                    let inverseReferencedColumn = manyToManyOptions && !inverse
                        ? stringArgument("inverseReferencedColumn", in: relationship).map { "\"\(swiftString($0))\"" } ?? "\"id\""
                        : "nil"
                    let inverseForeignKeyName = optionOrNil("inverseForeignKeyName")
                    if manyToManyOptions && inverse {
                        let ownerOptions = ["joinTable", "joinColumn", "inverseJoinColumn", "referencedColumn", "inverseReferencedColumn", "joinForeignKeyName", "inverseForeignKeyName", "onUpdate", "onDelete"].contains { label in
                            Self.argument(label, in: relationship) != nil
                        }
                        if ownerOptions {
                            context.diagnose(Diagnostic(node: Syntax(relationship), message: EntityMacroMessage("inverse @ManyToMany cannot configure join-table or foreign-key options")))
                            return []
                        }
                    }
                    relationships.append("""
                    PearfyData.SchemaRelationship(
                        field: "\(swiftString(field))",
                        kind: \(relationKind),
                        targetTable: "\(swiftString(targetTable))",
                        mappedBy: \(mappedBy.map { "\"\(swiftString($0))\"" } ?? "nil"),
                        column: \(defaultColumn),
                        referencedColumn: \(referencedColumn),
                        foreignKeyName: \(foreignKeyName),
                        nullable: \(nullable),
                        primaryKey: \(relationshipPrimaryKey),
                        onUpdate: \(onUpdate!),
                        onDelete: \(onDelete!),
                        joinTable: \(optionOrNil("joinTable")),
                        joinColumn: \(optionOrNil("joinColumn")),
                        inverseJoinColumn: \(optionOrNil("inverseJoinColumn")),
                        inverseReferencedColumn: \(inverseReferencedColumn),
                        inverseForeignKeyName: \(inverseForeignKeyName)
                    )
                    """)
                    continue
                }
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
                    message: EntityMacroMessage("unsupported @Entity property type '\(swiftType)'; object and collection associations require a supported relationship macro, and other custom mappings require an explicit SchemaEntity model")
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
            ], relationships: [
                \(relationships.joined(separator: ",\n                "))
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

    private static func arrayElementType(_ type: String) -> String? {
        let trimmed = type.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.first == "[", trimmed.last == "]" {
            return String(trimmed.dropFirst().dropLast()).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if trimmed.hasPrefix("Array<"), trimmed.hasSuffix(">") {
            return String(trimmed.dropFirst(6).dropLast()).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return nil
    }

    private static func referentialAction(
        _ label: String,
        in attribute: AttributeSyntax,
        context: some MacroExpansionContext
    ) -> String? {
        guard let expression = argument(label, in: attribute) else { return ".noAction" }
        let action = expression.trimmedDescription.split(separator: ".").last.map(String.init) ?? ""
        let allowed: Set<String> = ["noAction", "restrict", "cascade", "setNull", "setDefault"]
        guard allowed.contains(action) else {
            context.diagnose(Diagnostic(node: Syntax(expression), message: EntityMacroMessage("unsupported referential action '\(expression.trimmedDescription)'")))
            return nil
        }
        return "PearfyData.SchemaReferentialAction.\(action)"
    }

    private static func firstArgument(in attribute: AttributeSyntax) -> ExprSyntax? {
        guard case .argumentList(let arguments) = attribute.arguments,
              let expression = arguments.first?.expression else { return nil }
        return expression
    }

    private static func stringLiteral(_ expression: ExprSyntax) -> String? {
        guard let literal = expression.as(StringLiteralExprSyntax.self) else { return nil }
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
