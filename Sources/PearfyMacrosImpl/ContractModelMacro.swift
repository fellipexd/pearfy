import SwiftDiagnostics
import SwiftSyntax
import SwiftSyntaxBuilder
import SwiftSyntaxMacros

public struct ContractModelMacro: MemberMacro {
    private struct Field {
        let name: String
        let reference: String
        let required: Bool
        let helperStatements: [String]
        let helperNames: [String]
    }

    private struct SchemaUse {
        let reference: String
        let nullable: Bool
        let helperStatements: [String]
        let helperNames: [String]
    }

    public static func expansion(
        of node: AttributeSyntax,
        providingMembersOf declaration: some DeclGroupSyntax,
        conformingTo _: [TypeSyntax],
        in context: some MacroExpansionContext
    ) throws -> [DeclSyntax] {
        guard let structure = declaration.as(StructDeclSyntax.self) else {
            context.diagnose(Diagnostic(
                node: Syntax(declaration),
                message: ContractModelMacroMessage("@ContractModel currently supports structs")
            ))
            return []
        }
        guard structure.genericParameterClause == nil else {
            context.diagnose(Diagnostic(
                node: Syntax(declaration),
                message: ContractModelMacroMessage("generic @ContractModel types are not supported")
            ))
            return []
        }

        let inheritedTypes = structure.inheritanceClause?.inheritedTypes.map {
            $0.type.trimmedDescription.split(separator: ".").last.map(String.init) ?? $0.type.trimmedDescription
        } ?? []
        guard inheritedTypes.contains("Codable")
                || (inheritedTypes.contains("Encodable") && inheritedTypes.contains("Decodable")) else {
            context.diagnose(Diagnostic(
                node: Syntax(declaration),
                message: ContractModelMacroMessage("@ContractModel types must explicitly conform to Codable")
            ))
            return []
        }

        let schemaID = structure.name.text
        guard isValidSchemaID(schemaID) else {
            context.diagnose(Diagnostic(
                node: Syntax(node),
                message: ContractModelMacroMessage("invalid @ContractModel schema ID '\(schemaID)'")
            ))
            return []
        }

        var fields: [Field] = []
        var fieldNames: Set<String> = []
        var propertyIndex = 0
        for member in structure.memberBlock.members {
            guard let variable = member.decl.as(VariableDeclSyntax.self) else { continue }
            if variable.modifiers.contains(where: { ["static", "class"].contains($0.name.text) }) { continue }
            guard variable.bindings.count == 1,
                  let binding = variable.bindings.first,
                  let propertyName = binding.pattern.as(IdentifierPatternSyntax.self)?.identifier.text else {
                context.diagnose(Diagnostic(
                    node: Syntax(variable),
                    message: ContractModelMacroMessage("@ContractModel properties must have one simple stored identifier")
                ))
                return []
            }
            guard binding.accessorBlock == nil, let annotation = binding.typeAnnotation else {
                context.diagnose(Diagnostic(
                    node: Syntax(binding),
                    message: ContractModelMacroMessage("@ContractModel properties must be stored and explicitly typed")
                ))
                return []
            }

            let contractField = variable.attributes.compactMap { element -> AttributeSyntax? in
                guard case .attribute(let attribute) = element,
                      attributeName(attribute) == "ContractField" else { return nil }
                return attribute
            }.first
            let wireName: String
            if let contractField, let expression = argument("name", in: contractField) {
                guard let value = stringLiteral(expression) else {
                    context.diagnose(Diagnostic(
                        node: Syntax(expression),
                        message: ContractModelMacroMessage("@ContractField name must be a string literal")
                    ))
                    return []
                }
                wireName = value
            } else {
                wireName = propertyName
            }
            guard fieldNames.insert(wireName).inserted else {
                context.diagnose(Diagnostic(
                    node: Syntax(binding),
                    message: ContractModelMacroMessage("duplicate @ContractModel field name '\(wireName)'")
                ))
                return []
            }

            let typeName = annotation.type.trimmedDescription
            guard let schemaUse = schemaUse(
                for: typeName,
                index: propertyIndex,
                depth: 0,
                context: context,
                diagnosticNode: Syntax(annotation.type)
            ) else {
                return []
            }
            let explicitRequired: Bool?
            if let contractField, let expression = argument("required", in: contractField) {
                guard let value = booleanLiteral(expression) else {
                    context.diagnose(Diagnostic(
                        node: Syntax(expression),
                        message: ContractModelMacroMessage("@ContractField required must be a boolean literal")
                    ))
                    return []
                }
                explicitRequired = value
            } else {
                explicitRequired = nil
            }
            fields.append(Field(
                name: wireName,
                reference: schemaUse.reference,
                required: explicitRequired ?? !schemaUse.nullable,
                helperStatements: schemaUse.helperStatements,
                helperNames: schemaUse.helperNames
            ))
            propertyIndex += 1
        }

        let orderedFields = fields.sorted { $0.name < $1.name }
        let helperStatements = fields.flatMap(\.helperStatements)
        let helperNames = Array(Set(fields.flatMap(\.helperNames))).sorted()
        let helperExpressions = helperNames.isEmpty ? "[]" : "[\(helperNames.joined(separator: ", "))]"
        let properties = orderedFields.map { "\"\(swiftString($0.name))\": \($0.reference)" }
            .joined(separator: ",\n                ")
        let required = orderedFields.filter(\.required).map { "\"\(swiftString($0.name))\"" }.joined(separator: ", ")
        let statements = helperStatements.isEmpty ? "" : helperStatements.map { "    \($0)" }.joined(separator: "\n") + "\n"

        return [DeclSyntax(stringLiteral: """
        static var __pearfy_contractSchemas: [PearfyConnect.PearfyContractSchema] {
        \(statements)    let __pearfy_root = PearfyConnect.PearfyContractSchema(
                id: "\(swiftString(schemaID))",
                type: .object,
                properties: [
                    \(properties)
                ],
                required: [\(required)],
                additionalProperties: false
            )
            let __pearfy_helpers: [PearfyConnect.PearfyContractSchema] = \(helperExpressions)
            var __pearfy_unique_helpers: [String: PearfyConnect.PearfyContractSchema] = [:]
            for schema in __pearfy_helpers { __pearfy_unique_helpers[schema.id] = schema }
            return [__pearfy_root] + __pearfy_unique_helpers.values.sorted { $0.id < $1.id }
        }
        """)]
    }

    private static func schemaUse(
        for rawTypeName: String,
        index: Int,
        depth: Int,
        context: some MacroExpansionContext,
        diagnosticNode: Syntax
    ) -> SchemaUse? {
        var typeName = rawTypeName.trimmingCharacters(in: .whitespacesAndNewlines)
        let nullable: Bool
        if typeName.hasSuffix("?") {
            nullable = true
            typeName = String(typeName.dropLast())
        } else if typeName.hasPrefix("Optional<"), typeName.hasSuffix(">") {
            nullable = true
            typeName = String(typeName.dropFirst("Optional<".count).dropLast())
        } else {
            nullable = false
        }
        typeName = typeName.trimmingCharacters(in: .whitespacesAndNewlines)

        if let elementType = arrayElementType(in: typeName) {
            guard !elementType.isEmpty,
                  let itemUse = schemaUse(
                      for: elementType,
                      index: index,
                      depth: depth + 1,
                      context: context,
                      diagnosticNode: diagnosticNode
                  ) else {
                return nil
            }
            let suffix = "\(index)_\(depth)"
            let itemName = "__pearfy_contract_item_\(suffix)"
            let arrayIDName = "__pearfy_contract_array_id_\(suffix)"
            let arraySchemaName = "__pearfy_contract_array_schema_\(suffix)"
            let statements = itemUse.helperStatements + [
                "let \(itemName) = \(itemUse.reference)",
                "let \(arrayIDName) = PearfyConnect.PearfyContractSchema.arraySchemaID(for: \(itemName))",
                "let \(arraySchemaName) = PearfyConnect.PearfyContractSchema(id: \(arrayIDName), type: .array, items: \(itemName))"
            ]
            return SchemaUse(
                reference: "PearfyConnect.PearfyContractSchemaReference(id: \(arrayIDName), nullable: \(nullable))",
                nullable: nullable,
                helperStatements: statements,
                helperNames: itemUse.helperNames + [arraySchemaName]
            )
        }

        let finalComponent = typeName.split(separator: ".").last.map(String.init) ?? typeName
        let schemaID = finalComponent
        guard isValidSchemaID(schemaID) else {
            context.diagnose(Diagnostic(
                node: diagnosticNode,
                message: ContractModelMacroMessage("unsupported @ContractModel property type '\(rawTypeName)'")
            ))
            return nil
        }
        return SchemaUse(
            reference: "PearfyConnect.PearfyContractSchemaReference(id: \"\(swiftString(schemaID))\", nullable: \(nullable))",
            nullable: nullable,
            helperStatements: [],
            helperNames: []
        )
    }

    private static func arrayElementType(in typeName: String) -> String? {
        if typeName.hasPrefix("["), typeName.hasSuffix("]") {
            return String(typeName.dropFirst().dropLast()).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if typeName.hasPrefix("Array<"), typeName.hasSuffix(">") {
            return String(typeName.dropFirst("Array<".count).dropLast()).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return nil
    }

    private static func isValidSchemaID(_ id: String) -> Bool {
        let bytes = Array(id.utf8)
        guard !bytes.isEmpty,
              bytes.count <= 128,
              (65...90).contains(bytes[0]) || (97...122).contains(bytes[0]) || bytes[0] == 95 else { return false }
        return bytes.allSatisfy {
            (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0)
                || $0 == 45 || $0 == 46 || $0 == 95
        }
    }

    private static func argument(_ label: String, in attribute: AttributeSyntax) -> ExprSyntax? {
        guard case .argumentList(let arguments) = attribute.arguments else { return nil }
        return arguments.first(where: { $0.label?.text == label })?.expression
    }

    private static func booleanLiteral(_ expression: ExprSyntax) -> Bool? {
        switch expression.trimmedDescription {
        case "true": true
        case "false": false
        default: nil
        }
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

    private static func attributeName(_ attribute: AttributeSyntax) -> String {
        attribute.attributeName.trimmedDescription.split(separator: ".").last.map(String.init) ?? ""
    }

    private static func swiftString(_ value: String) -> String {
        value.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }
}

private struct ContractModelMacroMessage: DiagnosticMessage {
    let message: String

    init(_ message: String) { self.message = message }

    var diagnosticID: MessageID { MessageID(domain: "PearfyContractModelMacro", id: message) }
    var severity: DiagnosticSeverity { .error }
}
