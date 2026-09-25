import PackagePlugin

@main
struct PearfyDiscoveryPlugin: BuildToolPlugin {
    func createBuildCommands(context: PluginContext, target: Target) async throws -> [Command] {
        guard let sourceTarget = target as? SourceModuleTarget else { return [] }
        let swiftFiles = sourceTarget.sourceFiles(withSuffix: "swift").map(\.url)
        let output = context.pluginWorkDirectoryURL.appending(path: "PearfyGeneratedRegistry.swift")
        let generator = try context.tool(named: "PearfyDiscoveryGenerator")
        return [
            .buildCommand(
                displayName: "Generate Pearfy component registry for \(target.name)",
                executable: generator.url,
                arguments: [output.path] + swiftFiles.map(\.path),
                inputFiles: swiftFiles,
                outputFiles: [output]
            )
        ]
    }
}
