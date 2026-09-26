import SwiftCompilerPlugin
import SwiftSyntaxMacros

// Kept outside `main.swift` so SwiftPM compiles the @main entry point as a library.
@main
struct PearfyMacroPlugin: CompilerPlugin {
    let providingMacros: [Macro.Type] = [
        ComponentMacro.self,
        ContractModelMacro.self,
        EntityMacro.self,
        RestControllerMacro.self,
        RouteGroupMacro.self,
        ValidationMacro.self,
        MarkerMacro.self
    ]
}
