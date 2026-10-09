import Foundation

public struct PearfyMacroPolicyFinding: Equatable, Sendable {
    public let path: String
    public let line: Int
    public let method: String

    public init(path: String, line: Int, method: String) {
        self.path = path
        self.line = line
        self.method = method
    }

    public var guidance: String {
        let macro = "@" + method.prefix(1).uppercased() + method.dropFirst().lowercased()
        return "direct HTTPRouter registration uses \(method.uppercased()); prefer \(macro) under @RestController when the route is static and its handler semantics fit, otherwise document the dynamic or infrastructure reason"
    }
}

public struct PearfyMacroPolicyDiagnosticReport: Equatable, Sendable {
    public let findings: [PearfyMacroPolicyFinding]
    public let skippedFiles: Int

    public var isComplete: Bool { skippedFiles == 0 }
}

/// A bounded, source-level check for application route declarations that have
/// a public controller macro equivalent. This is advisory because only the
/// Swift compiler can establish semantic equivalence.
public enum PearfyMacroPolicyDiagnostics {
    private static let routeCall = try! NSRegularExpression(
        pattern: #"\b(?:router|[A-Za-z_][A-Za-z_0-9]*router)\s*\.\s*(get|post|put|patch|delete)\s*\("#,
        options: [.caseInsensitive]
    )
    private static let genericRouteCall = try! NSRegularExpression(
        pattern: #"\b(?:router|[A-Za-z_][A-Za-z_0-9]*router)\s*\.\s*on\s*\(\s*\.(get|post|put|patch|delete)\b"#,
        options: [.caseInsensitive]
    )
    private static let stringLiteral = try! NSRegularExpression(
        pattern: #"""[\s\S]*?"""|"(?:\\.|[^"\\])*""#
    )
    private static let lineComment = try! NSRegularExpression(pattern: #"//.*$"#, options: [.anchorsMatchLines])

    public static func check(projectRoot: URL, maximumFiles: Int = 2_000, maximumFileBytes: Int = 1_048_576) throws -> PearfyMacroPolicyDiagnosticReport {
        let root = projectRoot.standardizedFileURL.resolvingSymlinksInPath()
        let sources = root.appendingPathComponent("Sources", isDirectory: true)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: sources.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            return PearfyMacroPolicyDiagnosticReport(findings: [], skippedFiles: 1)
        }
        guard let enumerator = FileManager.default.enumerator(
            at: sources,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey, .isDirectoryKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return PearfyMacroPolicyDiagnosticReport(findings: [], skippedFiles: 1) }

        var findings: [PearfyMacroPolicyFinding] = []
        var scannedFiles = 0
        var skippedFiles = 0
        for case let file as URL in enumerator {
            let values = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey, .isDirectoryKey])
            guard values.isSymbolicLink != true else {
                if values.isDirectory == true { enumerator.skipDescendants() }
                continue
            }
            guard values.isRegularFile == true, file.pathExtension == "swift" else { continue }
            scannedFiles += 1
            guard scannedFiles <= max(1, maximumFiles), let size = values.fileSize, size <= max(1, maximumFileBytes) else {
                skippedFiles += 1
                continue
            }
            guard let source = try? String(contentsOf: file, encoding: .utf8) else {
                skippedFiles += 1
                continue
            }
            let resolvedFile = file.standardizedFileURL.resolvingSymlinksInPath()
            let relativePath = String(resolvedFile.path.dropFirst(root.path.count + 1))
            let withoutStrings = maskingMatches(of: stringLiteral, in: source)
            let codeSource = maskingMatches(of: lineComment, in: withoutStrings)
            for (lineNumber, sourceLine) in codeSource.components(separatedBy: .newlines).enumerated() {
                let code = sourceLine.trimmingCharacters(in: .whitespaces)
                guard !code.isEmpty else { continue }
                let line = code as NSString
                for expression in [routeCall, genericRouteCall] {
                    let fullRange = NSRange(location: 0, length: line.length)
                    for match in expression.matches(in: code, range: fullRange) {
                        guard match.numberOfRanges > 1 else { continue }
                        let method = line.substring(with: match.range(at: 1)).lowercased()
                        findings.append(PearfyMacroPolicyFinding(path: relativePath, line: lineNumber + 1, method: method))
                    }
                }
            }
        }
        return PearfyMacroPolicyDiagnosticReport(
            findings: findings.sorted { ($0.path, $0.line, $0.method) < ($1.path, $1.line, $1.method) },
            skippedFiles: skippedFiles
        )
    }

    private static func maskingMatches(of expression: NSRegularExpression, in source: String) -> String {
        let mutable = NSMutableString(string: source)
        let fullRange = NSRange(location: 0, length: mutable.length)
        for match in expression.matches(in: source, range: fullRange).reversed() {
            let value = mutable.substring(with: match.range)
            let masked = String(value.map { $0 == "\n" || $0 == "\r" ? $0 : " " })
            mutable.replaceCharacters(in: match.range, with: masked)
        }
        return mutable as String
    }
}
