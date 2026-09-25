import Foundation
import SwiftDiagnostics
import SwiftSyntax
import SwiftSyntaxBuilder
import SwiftSyntaxMacros

public struct RestControllerMacro: MemberMacro {
    public static func expansion(
        of node: AttributeSyntax,
        providingMembersOf declaration: some DeclGroupSyntax,
        conformingTo _: [TypeSyntax],
        in context: some MacroExpansionContext
    ) throws -> [DeclSyntax] {
        guard declaration.is(StructDeclSyntax.self) || declaration.is(ClassDeclSyntax.self) else {
            context.diagnose(Diagnostic(node: Syntax(declaration), message: ControllerMacroMessage("@RestController supports structs and classes")))
            return []
        }

        let prefix = firstStringArgument(in: node) ?? ""
        let controllerAttributes: [AttributeSyntax]
        if let value = declaration.as(StructDeclSyntax.self) {
            controllerAttributes = attributes(on: value)
        } else if let value = declaration.as(ClassDeclSyntax.self) {
            controllerAttributes = attributes(on: value)
        } else {
            controllerAttributes = []
        }
        let controllerAuthenticated = hasAttribute("Authenticated", in: controllerAttributes)
        let controllerPermitAll = hasAttribute("PermitAll", in: controllerAttributes)
        let controllerRoles = roleArguments(in: controllerAttributes)
        let controllerAccess: String
        if !controllerRoles.isEmpty {
            controllerAccess = ".roles(Set([\(controllerRoles.joined(separator: ", "))]))"
        } else if controllerAuthenticated {
            controllerAccess = ".authenticated"
        } else {
            controllerAccess = controllerPermitAll ? ".permitAll" : ".authenticated"
        }
        var routeRegistrations: [String] = []
        for member in declaration.memberBlock.members {
            guard let function = member.decl.as(FunctionDeclSyntax.self),
                  let route = routeDefinition(for: function) else { continue }
            guard let generated = makeRouteRegistration(
                function: function,
                method: route.method,
                path: joinedPath(prefix, route.path),
                controllerAuthenticated: controllerAuthenticated,
                controllerPermitAll: controllerPermitAll,
                controllerRoles: controllerRoles,
                controllerAccess: controllerAccess,
                context: context
            ) else { continue }
            routeRegistrations.append(generated)
        }

        return [DeclSyntax(stringLiteral: """
        static func __pearfy_registerRoutes(in router: PearfyWeb.HTTPRouter, instance: Self) async throws {
        \(routeRegistrations.joined(separator: "\n"))
        }
        """)]
    }

    private static func routeDefinition(for function: FunctionDeclSyntax) -> (method: String, path: String)? {
        for attribute in attributes(on: function) {
            let name = attribute.attributeName.trimmedDescription.split(separator: ".").last.map(String.init) ?? ""
            let method: String
            switch name {
            case "Get": method = "get"
            case "Post": method = "post"
            case "Put": method = "put"
            case "Patch": method = "patch"
            case "Delete": method = "delete"
            default: continue
            }
            return (method, firstStringArgument(in: attribute) ?? "")
        }
        return nil
    }

    private static func makeRouteRegistration(
        function: FunctionDeclSyntax,
        method: String,
        path: String,
        controllerAuthenticated: Bool,
        controllerPermitAll: Bool,
        controllerRoles: [String],
        controllerAccess: String,
        context: some MacroExpansionContext
    ) -> String? {
        let functionName = function.name.text
        var localBindings: [String] = []
        var callArguments: [String] = []
        let methodAttributes = attributes(on: function)
        let methodPermitAll = hasAttribute("PermitAll", in: methodAttributes)
        let methodRoles = roleArguments(in: methodAttributes)
        let routeAccess: String

        if methodPermitAll && !methodRoles.isEmpty {
            context.diagnose(Diagnostic(node: Syntax(function), message: ControllerMacroMessage("@PermitAll cannot be combined with @RolesAllowed")))
            return nil
        }
        if methodPermitAll {
            routeAccess = ".permitAll"
        } else if !methodRoles.isEmpty {
            routeAccess = ".roles(Set([\(methodRoles.joined(separator: ", "))]))"
        } else if hasAttribute("Authenticated", in: methodAttributes) {
            routeAccess = ".authenticated"
        } else if !controllerRoles.isEmpty {
            routeAccess = controllerAccess
        } else if controllerPermitAll {
            routeAccess = ".permitAll"
        } else if controllerAuthenticated {
            routeAccess = ".authenticated"
        } else {
            routeAccess = ".authenticated"
        }

        for (index, parameter) in function.signature.parameterClause.parameters.enumerated() {
            let externalName = parameter.firstName.text
            let localName = parameter.secondName?.text ?? externalName
            let type = parameter.type.trimmedDescription
            let binding: String

            let isValid = hasAttribute("Valid", on: parameter)
            if hasAttribute("RequestBody", on: parameter) || isValid {
                binding = "try request.decodeBody((\(type)).self)"
            } else if hasAttribute("PathVariable", on: parameter) {
                let name = markerArgument("PathVariable", on: parameter) ?? swiftString(localName)
                if type == "UUID" || type == "Foundation.UUID" {
                    binding = "try request.pathUUID(for: \(name))"
                } else {
                    binding = "try request.pathValue(for: \(name), as: (\(type)).self)"
                }
            } else if hasAttribute("QueryParam", on: parameter) {
                let name = markerArgument("QueryParam", on: parameter) ?? swiftString(localName)
                if type == "UUID" || type == "Foundation.UUID" {
                    binding = "try request.queryUUID(\(name))"
                } else {
                    binding = "try request.queryParameter(\(name), as: (\(type)).self)"
                }
            } else if hasAttribute("HeaderParam", on: parameter) {
                let name = markerArgument("HeaderParam", on: parameter) ?? swiftString(localName)
                binding = "try request.headerValue(\(name), as: (\(type)).self)"
            } else if type == "HTTPRequest" || type == "PearfyWeb.HTTPRequest" {
                binding = "request"
            } else {
                context.diagnose(Diagnostic(
                    node: Syntax(parameter),
                    message: ControllerMacroMessage("controller parameters need @PathVariable, @QueryParam, @HeaderParam, or @RequestBody")
                ))
                return nil
            }

            let variable = "__pearfy_parameter_\(index)"
            localBindings.append("let \(variable): \(type) = \(binding)")
            if isValid {
                localBindings.append("do { try PearfyValidation.validate(\(variable)) } catch let error as PearfyValidation.ValidationError { return try PearfyWeb.HTTPResponse.json(error.violations, status: 400) }")
            }
            let label = externalName == "_" ? "" : "\(externalName): "
            callArguments.append("\(label)\(variable)")
        }

        let effects = function.signature.effectSpecifiers
        let tryPrefix = effects?.throwsClause?.throwsSpecifier == nil ? "" : "try "
        let awaitPrefix = effects?.asyncSpecifier == nil ? "" : "await "
        let call = "\(tryPrefix)\(awaitPrefix)instance.\(functionName)(\(callArguments.joined(separator: ", ")))"
        let returnType = function.signature.returnClause?.type.trimmedDescription ?? "Void"
        let responseStatus = attributes(on: function)
            .first(where: { attributeName($0) == "ResponseStatus" })
            .flatMap(firstArgument)
            .map { statusExpression($0) }
            ?? "200"

        let response: String
        if returnType == "Void" || returnType == "()" {
            response = "\(call)\nreturn PearfyWeb.HTTPResponse(status: \(responseStatus == "200" ? "204" : responseStatus))"
        } else if returnType == "String" {
            response = "let __pearfy_result = \(call)\nreturn PearfyWeb.HTTPResponse.text(__pearfy_result, status: \(responseStatus))"
        } else if returnType == "HTTPResponse" || returnType == "PearfyWeb.HTTPResponse" {
            response = "return \(call)"
        } else {
            response = "let __pearfy_result = \(call)\nreturn try PearfyWeb.HTTPResponse.json(__pearfy_result, status: \(responseStatus))"
        }

        let allBindings = localBindings.map { "            \($0)" }.joined(separator: "\n")
        return """
        try await router.on(.\(method), path: \(swiftString(path)), access: \(routeAccess)) { request in
        \(allBindings)
            \(response.replacingOccurrences(of: "\n", with: "\n            "))
        }
        """
    }

    private static func joinedPath(_ prefix: String, _ route: String) -> String {
        let segments = [prefix, route].map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "/")) }
            .filter { !$0.isEmpty }
        return "/" + segments.joined(separator: "/")
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

    private static func hasAttribute<S: SyntaxProtocol & WithAttributesSyntax>(_ name: String, on syntax: S) -> Bool {
        attributes(on: syntax).contains { attributeName($0) == name }
    }

    private static func hasAttribute(_ name: String, in attributes: [AttributeSyntax]) -> Bool {
        attributes.contains { attributeName($0) == name }
    }

    private static func roleArguments(in attributes: [AttributeSyntax]) -> [String] {
        guard let attribute = attributes.first(where: { attributeName($0) == "RolesAllowed" }),
              case .argumentList(let arguments) = attribute.arguments else { return [] }
        return arguments.map { $0.expression.trimmedDescription }
    }

    private static func markerArgument<S: SyntaxProtocol & WithAttributesSyntax>(
        _ name: String,
        on syntax: S
    ) -> String? {
        attributes(on: syntax).first(where: { attributeName($0) == name }).flatMap(firstArgument)
    }

    private static func firstStringArgument(in attribute: AttributeSyntax) -> String? {
        guard case .argumentList(let arguments) = attribute.arguments,
              let expression = arguments.first?.expression.as(StringLiteralExprSyntax.self) else { return nil }
        var value = ""
        for segment in expression.segments {
            guard case .stringSegment(let string) = segment else { return nil }
            value += string.content.text
        }
        return value
    }

    private static func firstArgument(_ attribute: AttributeSyntax) -> String? {
        guard case .argumentList(let arguments) = attribute.arguments,
              let expression = arguments.first?.expression else { return nil }
        return expression.trimmedDescription
    }

    private static func swiftString(_ value: String) -> String {
        "\"" + value.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    private static func statusExpression(_ expression: String) -> String {
        if expression.hasPrefix(".") { return "PearfyWeb.HTTPStatus\(expression).rawValue" }
        if expression.hasPrefix("HTTPStatus.") { return "PearfyWeb.\(expression).rawValue" }
        return "PearfyWeb.HTTPStatus.\(expression).rawValue"
    }
}

private struct ControllerMacroMessage: DiagnosticMessage {
    let message: String

    init(_ message: String) { self.message = message }

    var diagnosticID: MessageID { MessageID(domain: "PearfyControllerMacro", id: message) }
    var severity: DiagnosticSeverity { .error }
}
