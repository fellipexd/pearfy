import SwiftDiagnostics
import SwiftSyntax
import SwiftSyntaxBuilder
import SwiftSyntaxMacros

public struct ComponentMacro: MemberMacro {
    public static func expansion(
        of node: AttributeSyntax,
        providingMembersOf declaration: some DeclGroupSyntax,
        conformingTo _: [TypeSyntax],
        in context: some MacroExpansionContext
    ) throws -> [DeclSyntax] {
        guard let component = ComponentDescription.describe(
            declaration: declaration,
            attribute: node,
            context: context
        ) else {
            return []
        }
        var members: [DeclSyntax] = []
        if !component.autowiredProperties.isEmpty {
            let parameters = component.autowiredProperties.map { property in
                "__pearfy_\(property.name): \(property.type)"
            }.joined(separator: ", ")
            let assignments = component.autowiredProperties.map { property in
                "self.\(property.name) = __pearfy_\(property.name)"
            }.joined(separator: "\n")
            members.append(DeclSyntax(stringLiteral: """
            private init(\(parameters)) {
                \(assignments)
            }
            """))
        }

        guard let construction = component.construction else { return members }
        let registrationType = component.bindingType ?? "(Self).self"
        let qualifier = component.qualifier.map { "\($0)" } ?? "nil"
        let dependencies = construction.dependencies.map { dependency in
            "PearfyDI.Dependency((\(dependency.type)).self, qualifier: \(dependency.qualifier.map { "\($0)" } ?? "nil"))"
        }.joined(separator: ", ")
        let initializerArguments = construction.arguments.joined(separator: ", ")
        let registrationMethod = """
        static func __pearfy_register(into container: PearfyDI.ServiceContainer) async throws {
            try await container.register(
                \(registrationType),
                qualifier: \(qualifier),
                primary: \(component.isPrimary),
                scope: .\(component.scope),
                dependsOn: [\(dependencies)]
            ) { resolver in
                Self(\(initializerArguments))
            }
        }
        """
        members.append(DeclSyntax(stringLiteral: registrationMethod))
        return members
    }
}

public struct MarkerMacro: PeerMacro {
    public static func expansion(
        of node: AttributeSyntax,
        providingPeersOf declaration: some DeclSyntaxProtocol,
        in context: some MacroExpansionContext
    ) throws -> [DeclSyntax] {
        []
    }
}

private struct InjectedProperty {
    let name: String
    let type: String
    let qualifier: String?
}

private struct InjectionDependency {
    let type: String
    let qualifier: String?
}

private struct Construction {
    let dependencies: [InjectionDependency]
    let arguments: [String]
}

private struct ComponentDescription {
    let typeName: String
    let qualifier: String?
    let scope: String
    let isPrimary: Bool
    let bindingType: String?
    let autowiredProperties: [InjectedProperty]
    let construction: Construction?

    init?<D: DeclGroupSyntax & WithAttributesSyntax>(declaration: D, attribute: AttributeSyntax, context: some MacroExpansionContext) {
        guard let (typeName, genericParameterCount) = Self.declaredTypeName(declaration) else {
            context.diagnose(Diagnostic(node: Syntax(declaration), message: MacroMessage("component annotations can only be applied to structs, classes, and actors")))
            return nil
        }
        guard genericParameterCount == 0 else {
            context.diagnose(Diagnostic(node: Syntax(declaration), message: MacroMessage("generic components are not supported by this discovery prototype")))
            return nil
        }

        self.typeName = typeName
        qualifier = Self.stringArgument("qualifier", in: attribute)
            ?? Self.stringArgument("Qualifier", in: declaration)
        scope = Self.memberArgument("scope", in: attribute) ?? "singleton"
        isPrimary = Self.booleanArgument("primary", in: attribute) || Self.hasAttribute("Primary", on: declaration)
        bindingType = Self.bindType(on: declaration)

        var properties: [InjectedProperty] = []
        for member in declaration.memberBlock.members {
            guard let variable = member.decl.as(VariableDeclSyntax.self),
                  Self.hasAttribute("Autowired", on: variable) || Self.hasAttribute("Inject", on: variable) else { continue }
            let isStatic = variable.modifiers.contains { ["static", "class"].contains($0.name.text) }
            guard !isStatic else {
                context.diagnose(Diagnostic(node: Syntax(variable), message: MacroMessage("@Autowired/@Inject can only annotate instance stored properties")))
                continue
            }
            guard variable.bindings.count == 1 else {
                context.diagnose(Diagnostic(node: Syntax(variable), message: MacroMessage("@Autowired/@Inject declarations must contain exactly one stored property")))
                continue
            }
            for binding in variable.bindings {
                guard let name = binding.pattern.as(IdentifierPatternSyntax.self)?.identifier.text,
                      let type = binding.typeAnnotation?.type.trimmedDescription else {
                    context.diagnose(Diagnostic(node: Syntax(binding), message: MacroMessage("@Autowired properties require a simple name and an explicit type")))
                    continue
                }
                if binding.accessorBlock != nil {
                    context.diagnose(Diagnostic(node: Syntax(binding), message: MacroMessage("@Autowired/@Inject properties must be stored properties")))
                    continue
                }
                if binding.initializer != nil {
                    context.diagnose(Diagnostic(node: Syntax(binding), message: MacroMessage("@Autowired properties cannot declare an initializer")))
                    continue
                }
                properties.append(InjectedProperty(
                    name: name,
                    type: type,
                    qualifier: Self.stringArgument("Qualifier", in: variable)
                ))
            }
        }
        autowiredProperties = properties

        if !properties.isEmpty {
            construction = Construction(
                dependencies: properties.map { InjectionDependency(type: $0.type, qualifier: $0.qualifier) },
                arguments: properties.map { property in
                    "__pearfy_\(property.name): try await resolver.resolve((\(property.type)).self, qualifier: \(property.qualifier.map { "\($0)" } ?? "nil"))"
                }
            )
        } else if let initializer = declaration.memberBlock.members.compactMap({ $0.decl.as(InitializerDeclSyntax.self) }).first {
            let parameters = initializer.signature.parameterClause.parameters
            construction = Construction(
                dependencies: parameters.map { parameter in
                    InjectionDependency(
                        type: parameter.type.trimmedDescription,
                        qualifier: Self.stringArgument("Qualifier", in: parameter)
                    )
                },
                arguments: parameters.map { parameter in
                    let externalName = parameter.firstName.text
                    let argumentLabel = externalName == "_" ? "" : "\(externalName): "
                    let qualifier = Self.stringArgument("Qualifier", in: parameter).map { "\($0)" } ?? "nil"
                    return "\(argumentLabel)try await resolver.resolve((\(parameter.type.trimmedDescription)).self, qualifier: \(qualifier))"
                }
            )
        } else {
            construction = Construction(dependencies: [], arguments: [])
        }
    }

    static func describe(
        declaration: some DeclSyntaxProtocol,
        attribute: AttributeSyntax,
        context: some MacroExpansionContext
    ) -> ComponentDescription? {
        if let value = declaration.as(StructDeclSyntax.self) {
            return ComponentDescription(declaration: value, attribute: attribute, context: context)
        }
        if let value = declaration.as(ClassDeclSyntax.self) {
            return ComponentDescription(declaration: value, attribute: attribute, context: context)
        }
        if let value = declaration.as(ActorDeclSyntax.self) {
            return ComponentDescription(declaration: value, attribute: attribute, context: context)
        }
        context.diagnose(Diagnostic(node: Syntax(declaration), message: MacroMessage("component annotations can only be applied to structs, classes, and actors")))
        return nil
    }

    private static func declaredTypeName<D: DeclGroupSyntax>(_ declaration: D) -> (String, Int)? {
        if let value = declaration.as(StructDeclSyntax.self) {
            return (value.name.text, value.genericParameterClause?.parameters.count ?? 0)
        }
        if let value = declaration.as(ClassDeclSyntax.self) {
            return (value.name.text, value.genericParameterClause?.parameters.count ?? 0)
        }
        if let value = declaration.as(ActorDeclSyntax.self) {
            return (value.name.text, value.genericParameterClause?.parameters.count ?? 0)
        }
        return nil
    }

    private static func attributes<S: SyntaxProtocol & WithAttributesSyntax>(on syntax: S) -> [AttributeSyntax] {
        syntax.attributes.compactMap { element in
            guard case .attribute(let attribute) = element else { return nil }
            return attribute
        }
    }

    private static func hasAttribute<S: SyntaxProtocol & WithAttributesSyntax>(_ name: String, on syntax: S) -> Bool {
        attributes(on: syntax).contains { $0.attributeName.trimmedDescription.split(separator: ".").last.map(String.init) == name }
    }

    private static func stringArgument(_ name: String, in attribute: AttributeSyntax) -> String? {
        guard case .argumentList(let arguments) = attribute.arguments,
              let argument = arguments.first(where: { $0.label?.text == name }) else { return nil }
        return argument.expression.trimmedDescription
    }

    private static func stringArgument<S: SyntaxProtocol & WithAttributesSyntax>(_ name: String, in syntax: S) -> String? {
        guard let attribute = attributes(on: syntax).first(where: {
            $0.attributeName.trimmedDescription.split(separator: ".").last.map(String.init) == name
        }), case .argumentList(let arguments) = attribute.arguments,
           let argument = arguments.first else { return nil }
        return argument.expression.trimmedDescription
    }

    private static func memberArgument(_ name: String, in attribute: AttributeSyntax) -> String? {
        guard case .argumentList(let arguments) = attribute.arguments,
              let argument = arguments.first(where: { $0.label?.text == name }) else { return nil }
        return argument.expression.trimmedDescription.split(separator: ".").last.map(String.init)
    }

    private static func booleanArgument(_ name: String, in attribute: AttributeSyntax) -> Bool {
        guard case .argumentList(let arguments) = attribute.arguments,
              let argument = arguments.first(where: { $0.label?.text == name }) else { return false }
        return argument.expression.trimmedDescription == "true"
    }

    private static func bindType<D: DeclGroupSyntax & WithAttributesSyntax>(on declaration: D) -> String? {
        guard let attribute = attributes(on: declaration).first(where: {
            $0.attributeName.trimmedDescription.split(separator: ".").last.map(String.init) == "Bind"
        }), case .argumentList(let arguments) = attribute.arguments,
           let argument = arguments.first else { return nil }
        return argument.expression.trimmedDescription
    }
}

private struct MacroMessage: DiagnosticMessage {
    let message: String

    init(_ message: String) { self.message = message }

    var diagnosticID: MessageID { MessageID(domain: "PearfyMacros", id: message) }
    var severity: DiagnosticSeverity { .error }
}
