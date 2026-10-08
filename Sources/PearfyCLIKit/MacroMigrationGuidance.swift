import Foundation

enum PearfyMacroMigrationGuidance {
    enum Status: String {
        case applicable
        case notApplicable = "not-applicable"
        case notSupported = "not-supported"
    }

    struct Decision: Equatable {
        let status: Status
        let guidance: String

        var statusLine: String { "macro=\(status.rawValue): \(guidance)" }
    }

    static func route(method: String, path: String) -> Decision {
        let macro: String
        switch method.uppercased() {
        case "GET": macro = "@Get"
        case "POST": macro = "@Post"
        case "PUT": macro = "@Put"
        case "PATCH": macro = "@Patch"
        case "DELETE": macro = "@Delete"
        default:
            return Decision(
                status: .notSupported,
                guidance: "no public Pearfy controller macro maps HTTP \(method.uppercased()); keep this route manual and review its semantics"
            )
        }
        guard !path.contains(":"), !path.contains("*"), !path.contains("(") else {
            return Decision(
                status: .notSupported,
                guidance: "\(macro) exists, but the legacy path syntax needs explicit translation and parameter review before mapping"
            )
        }
        return Decision(
            status: .applicable,
            guidance: "prefer @RestController + \(macro) with the contracted path; this CLI records contracts only and does not generate or rewrite handlers"
        )
    }

    static func element(_ element: PearfyLegacyElementContract) -> Decision {
        let annotation = element.attributes["annotation"].flatMap(stringValue)
        switch element.kind {
        case .controller:
            return Decision(
                status: .applicable,
                guidance: "prefer @RestController and supported route macros when translating its HTTP handlers; preserve explicit __pearfy_registerRoutes registration"
            )
        case .service:
            return Decision(
                status: .applicable,
                guidance: "@Service is available; verify initializer/dependency semantics before replacing the legacy component"
            )
        case .repository:
            return Decision(
                status: .applicable,
                guidance: "@Repository is available for the Pearfy implementation; preserve persistence and protocol binding semantics"
            )
        case .model:
            return Decision(
                status: .notSupported,
                guidance: "\(annotation.map { "@\($0) was detected; " } ?? "")the analyzer has no field/type mapping; @Entity requires explicit supported stored properties and schema review"
            )
        case .securityRule:
            return Decision(
                status: .notSupported,
                guidance: "route policy macros exist, but this analyzer cannot prove equivalent principal, expression, and middleware semantics; keep the policy unresolved until reviewed"
            )
        case .validation:
            return Decision(
                status: .notSupported,
                guidance: "some field constraints have Pearfy macros, but field types and complete constraints were not extracted; do not translate this annotation automatically"
            )
        case .transaction:
            return Decision(
                status: .notSupported,
                guidance: "no public Pearfy transaction macro exists; preserve the boundary and map it to PearfyTransactions only after reviewing rollback/propagation behavior"
            )
        case .job:
            return Decision(status: .notSupported, guidance: "no public Pearfy scheduling macro exists; retain the job behavior and choose an implemented scheduler explicitly")
        case .event:
            return Decision(status: .notSupported, guidance: "no public Pearfy listener macro exists; retain delivery/acknowledgement behavior and map it explicitly")
        case .externalDependency:
            return Decision(status: .notApplicable, guidance: "external dependency metadata is not a Pearfy macro concern")
        }
    }

    private static func stringValue(_ value: PearfyMigrationJSONValue) -> String? {
        guard case .string(let string) = value else { return nil }
        return string
    }
}
