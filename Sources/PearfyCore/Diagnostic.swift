/// A stable, machine-readable framework diagnostic.
public struct PearfyDiagnostic: Error, Sendable, Equatable, CustomStringConvertible {
    public let code: String
    public let message: String

    public init(code: String, message: String) {
        self.code = code
        self.message = message
    }

    public var description: String { "\(code): \(message)" }
}
