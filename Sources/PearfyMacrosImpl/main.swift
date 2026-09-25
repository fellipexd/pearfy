import SwiftCompilerPlugin
import SwiftSyntaxMacros

@main
struct PearfyMacroPlugin: CompilerPlugin {
    let providingMacros: [Macro.Type] = [
        ComponentMacro.self,
        RestControllerMacro.self,
        ValidationMacro.self,
        MarkerMacro.self
    ]
}
