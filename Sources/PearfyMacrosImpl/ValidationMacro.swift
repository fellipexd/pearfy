import SwiftDiagnostics
import SwiftSyntax
import SwiftSyntaxBuilder
import SwiftSyntaxMacros

public struct ValidationMacro: MemberMacro {
    public static func expansion(
        of node: AttributeSyntax,
        providingMembersOf declaration: some DeclGroupSyntax,
        conformingTo _: [TypeSyntax],
        in context: some MacroExpansionContext
    ) throws -> [DeclSyntax] {
        var checks: [String] = []
        for member in declaration.memberBlock.members {
            guard let property = member.decl.as(VariableDeclSyntax.self) else { continue }
            let attributes = property.attributes.compactMap { element -> AttributeSyntax? in
                guard case .attribute(let attribute) = element else { return nil }
                return attribute
            }
            let hasRules = attributes.contains { ["NotBlank", "Size", "Min", "Max", "Pattern"].contains(attributeName($0)) }
            guard hasRules else { continue }
            guard property.bindings.count == 1,
                  let binding = property.bindings.first,
                  let name = binding.pattern.as(IdentifierPatternSyntax.self)?.identifier.text,
                  let type = binding.typeAnnotation?.type.trimmedDescription else {
                context.diagnose(Diagnostic(node: Syntax(property), message: ValidationMacroMessage("validation constraints require one named stored property with an explicit type")))
                continue
            }

            for attribute in attributes {
                let call: String
                switch attributeName(attribute) {
                case "NotBlank":
                    guard type == "String" else {
                        context.diagnose(Diagnostic(node: Syntax(property), message: ValidationMacroMessage("@NotBlank applies to String properties")))
                        continue
                    }
                    call = "PearfyValidation.ValidationRules.notBlank(field: \(swiftString(name)), value: self.\(name))"
                case "Size":
                    guard type == "String" else {
                        context.diagnose(Diagnostic(node: Syntax(property), message: ValidationMacroMessage("@Size currently applies to String properties")))
                        continue
                    }
                    let minimum = labeledArgument("min", in: attribute) ?? "nil"
                    let maximum = labeledArgument("max", in: attribute) ?? "nil"
                    call = "PearfyValidation.ValidationRules.length(field: \(swiftString(name)), value: self.\(name), minimum: \(minimum), maximum: \(maximum))"
                case "Min":
                    guard let value = firstArgument(in: attribute) else {
                        context.diagnose(Diagnostic(node: Syntax(property), message: ValidationMacroMessage("@Min requires a numeric bound")))
                        continue
                    }
                    call = "PearfyValidation.ValidationRules.minimum(field: \(swiftString(name)), value: self.\(name), minimum: \(value))"
                case "Max":
                    guard let value = firstArgument(in: attribute) else {
                        context.diagnose(Diagnostic(node: Syntax(property), message: ValidationMacroMessage("@Max requires a numeric bound")))
                        continue
                    }
                    call = "PearfyValidation.ValidationRules.maximum(field: \(swiftString(name)), value: self.\(name), maximum: \(value))"
                case "Pattern":
                    guard type == "String", let expression = firstArgument(in: attribute) else {
                        context.diagnose(Diagnostic(node: Syntax(property), message: ValidationMacroMessage("@Pattern requires a String property and a regex expression")))
                        continue
                    }
                    call = "PearfyValidation.ValidationRules.matches(field: \(swiftString(name)), value: self.\(name), pattern: \(expression))"
                default:
                    continue
                }
                checks.append("violations += \(call)")
            }
        }

        return [DeclSyntax(stringLiteral: """
        public func validationViolations() -> [PearfyValidation.ValidationViolation] {
            var violations: [PearfyValidation.ValidationViolation] = []
            \(checks.joined(separator: "\n"))
            return violations
        }
        """)]
    }

    private static func attributeName(_ attribute: AttributeSyntax) -> String {
        attribute.attributeName.trimmedDescription.split(separator: ".").last.map(String.init) ?? ""
    }

    private static func firstArgument(in attribute: AttributeSyntax) -> String? {
        guard case .argumentList(let arguments) = attribute.arguments,
              let expression = arguments.first?.expression else { return nil }
        return expression.trimmedDescription
    }

    private static func labeledArgument(_ label: String, in attribute: AttributeSyntax) -> String? {
        guard case .argumentList(let arguments) = attribute.arguments,
              let expression = arguments.first(where: { $0.label?.text == label })?.expression else { return nil }
        return expression.trimmedDescription
    }

    private static func swiftString(_ value: String) -> String {
        "\"" + value.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }
}

private struct ValidationMacroMessage: DiagnosticMessage {
    let message: String

    init(_ message: String) { self.message = message }

    var diagnosticID: MessageID { MessageID(domain: "PearfyValidationMacro", id: message) }
    var severity: DiagnosticSeverity { .error }
}
