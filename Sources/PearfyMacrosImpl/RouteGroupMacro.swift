import SwiftDiagnostics
import SwiftSyntax
import SwiftSyntaxBuilder
import SwiftSyntaxMacros

public struct RouteGroupMacro: MemberMacro {
    public static func expansion(
        of node: AttributeSyntax,
        providingMembersOf declaration: some DeclGroupSyntax,
        conformingTo _: [TypeSyntax],
        in context: some MacroExpansionContext
    ) throws -> [DeclSyntax] {
        guard declaration.is(EnumDeclSyntax.self) else {
            context.diagnose(Diagnostic(
                node: Syntax(declaration),
                message: RouteGroupMacroMessage("@RouteGroup can only be applied to an enum")
            ))
            return []
        }

        guard let name = stringArgument("name", in: node),
              let prefix = stringArgument("prefix", in: node),
              let targets = sdkTargets(in: node, context: context) else {
            context.diagnose(Diagnostic(
                node: Syntax(node),
                message: RouteGroupMacroMessage("@RouteGroup requires literal name, prefix, and sdk arguments")
            ))
            return []
        }
        let version = stringArgument("contractVersion", in: node) ?? "1.0"

        return [DeclSyntax(stringLiteral: """
        static var __pearfy_routeGroup: PearfyWeb.HTTPRouteGroup {
            PearfyWeb.HTTPRouteGroup(
                name: "\(swiftString(name))",
                prefix: "\(swiftString(prefix))",
                sdkTargets: Set([\(targets.joined(separator: ", "))]),
                contractVersion: "\(swiftString(version))"
            )
        }
        """)]
    }

    private static func stringArgument(_ label: String, in attribute: AttributeSyntax) -> String? {
        guard case .argumentList(let arguments) = attribute.arguments,
              let argument = arguments.first(where: { $0.label?.text == label }),
              let literal = argument.expression.as(StringLiteralExprSyntax.self) else { return nil }
        var value = ""
        for segment in literal.segments {
            guard case .stringSegment(let string) = segment else { return nil }
            value += string.content.text
        }
        return value
    }

    private static func sdkTargets(
        in attribute: AttributeSyntax,
        context: some MacroExpansionContext
    ) -> [String]? {
        guard case .argumentList(let arguments) = attribute.arguments,
              let argument = arguments.first(where: { $0.label?.text == "sdk" }),
              let array = argument.expression.as(ArrayExprSyntax.self) else { return nil }
        let validTargets: Set<String> = ["ios", "android", "typescript"]
        var targets: [String] = []
        for element in array.elements {
            guard let member = element.expression.as(MemberAccessExprSyntax.self),
                  member.base == nil,
                  validTargets.contains(member.declName.baseName.text) else {
                context.diagnose(Diagnostic(
                    node: Syntax(element),
                    message: RouteGroupMacroMessage("@RouteGroup sdk values must be .ios, .android, or .typescript")
                ))
                return nil
            }
            targets.append(".\(member.declName.baseName.text)")
        }
        guard Set(targets).count == targets.count else {
            context.diagnose(Diagnostic(
                node: Syntax(array),
                message: RouteGroupMacroMessage("@RouteGroup sdk targets must be unique")
            ))
            return nil
        }
        return targets
    }

    private static func swiftString(_ value: String) -> String {
        value.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }
}

private struct RouteGroupMacroMessage: DiagnosticMessage {
    let message: String

    init(_ message: String) { self.message = message }

    var diagnosticID: MessageID { MessageID(domain: "PearfyRouteGroupMacro", id: message) }
    var severity: DiagnosticSeverity { .error }
}
