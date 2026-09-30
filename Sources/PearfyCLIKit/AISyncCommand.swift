import Foundation

/// Compatibility facade for callers that previously exposed `pearfy ai sync` directly.
public enum PearfyAISyncCommand {
    public static func run(arguments: [String], projectRoot: URL, frameworkRoot: URL) throws -> Int32 {
        try PearfyAICommand.run(
            arguments: ["sync"] + arguments,
            projectRoot: projectRoot,
            frameworkRoot: frameworkRoot
        )
    }
}
