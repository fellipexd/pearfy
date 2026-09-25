import SwiftCompilerPlugin
import SwiftSyntaxMacros

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
