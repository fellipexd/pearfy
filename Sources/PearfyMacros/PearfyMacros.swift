import PearfyDI
import PearfyData
import PearfyWeb

@attached(member, names: arbitrary)
public macro Component(
    qualifier: String? = nil,
    primary: Bool = false,
    scope: ServiceContainer.Scope = .singleton
) = #externalMacro(module: "PearfyMacrosImpl", type: "ComponentMacro")

@attached(member, names: arbitrary)
public macro Service(
    qualifier: String? = nil,
    primary: Bool = false,
    scope: ServiceContainer.Scope = .singleton
) = #externalMacro(module: "PearfyMacrosImpl", type: "ComponentMacro")

@attached(member, names: arbitrary)
public macro Repository(
    qualifier: String? = nil,
    primary: Bool = false,
    scope: ServiceContainer.Scope = .singleton
) = #externalMacro(module: "PearfyMacrosImpl", type: "ComponentMacro")

@attached(member, names: named(__pearfy_schema))
public macro Entity(_ table: String) = #externalMacro(module: "PearfyMacrosImpl", type: "EntityMacro")

@attached(member, names: named(__pearfy_contractSchemas))
public macro ContractModel() = #externalMacro(module: "PearfyMacrosImpl", type: "ContractModelMacro")

@attached(peer, names: named(__pearfy_marker))
public macro ID(strategy: SchemaIdentifierStrategy? = nil) = #externalMacro(module: "PearfyMacrosImpl", type: "MarkerMacro")

@attached(peer, names: named(__pearfy_marker))
public macro Column(
    name: String? = nil,
    nullable: Bool? = nil,
    unique: Bool = false,
    precision: Int? = nil,
    scale: Int? = nil,
    renamedFrom: String? = nil
) = #externalMacro(module: "PearfyMacrosImpl", type: "MarkerMacro")

@attached(peer, names: named(__pearfy_marker))
public macro ContractField(name: String? = nil, required: Bool? = nil) = #externalMacro(module: "PearfyMacrosImpl", type: "MarkerMacro")

@attached(peer, names: named(__pearfy_marker))
public macro Autowired() = #externalMacro(module: "PearfyMacrosImpl", type: "MarkerMacro")

@attached(peer, names: named(__pearfy_marker))
public macro Inject() = #externalMacro(module: "PearfyMacrosImpl", type: "MarkerMacro")

@attached(peer, names: named(__pearfy_marker))
public macro Qualifier(_ name: String) = #externalMacro(module: "PearfyMacrosImpl", type: "MarkerMacro")

@attached(peer, names: named(__pearfy_marker))
public macro Primary() = #externalMacro(module: "PearfyMacrosImpl", type: "MarkerMacro")

@attached(peer, names: named(__pearfy_marker))
public macro Bind(_ type: Any.Type) = #externalMacro(module: "PearfyMacrosImpl", type: "MarkerMacro")

@attached(member, names: arbitrary)
public macro RestController(_ path: String = "", group: Any.Type? = nil) = #externalMacro(module: "PearfyMacrosImpl", type: "RestControllerMacro")

@attached(member, names: named(__pearfy_routeGroup))
public macro RouteGroup(
    name: String,
    prefix: String,
    sdk: [HTTPRouteSDKTarget],
    contractVersion: String = "1.0"
) = #externalMacro(module: "PearfyMacrosImpl", type: "RouteGroupMacro")

@attached(peer, names: named(__pearfy_marker))
public macro Get(_ path: String = "") = #externalMacro(module: "PearfyMacrosImpl", type: "MarkerMacro")

@attached(peer, names: named(__pearfy_marker))
public macro Post(_ path: String = "") = #externalMacro(module: "PearfyMacrosImpl", type: "MarkerMacro")

@attached(peer, names: named(__pearfy_marker))
public macro Put(_ path: String = "") = #externalMacro(module: "PearfyMacrosImpl", type: "MarkerMacro")

@attached(peer, names: named(__pearfy_marker))
public macro Patch(_ path: String = "") = #externalMacro(module: "PearfyMacrosImpl", type: "MarkerMacro")

@attached(peer, names: named(__pearfy_marker))
public macro Delete(_ path: String = "") = #externalMacro(module: "PearfyMacrosImpl", type: "MarkerMacro")

@attached(peer, names: named(__pearfy_marker))
public macro ResponseStatus(_ status: PearfyWeb.HTTPStatus) = #externalMacro(module: "PearfyMacrosImpl", type: "MarkerMacro")

@attached(peer, names: named(__pearfy_marker))
public macro Authenticated() = #externalMacro(module: "PearfyMacrosImpl", type: "MarkerMacro")

@attached(peer, names: named(__pearfy_marker))
public macro PermitAll() = #externalMacro(module: "PearfyMacrosImpl", type: "MarkerMacro")

@attached(peer, names: named(__pearfy_marker))
public macro RolesAllowed(_ roles: String...) = #externalMacro(module: "PearfyMacrosImpl", type: "MarkerMacro")

@attached(member, names: named(validationViolations))
public macro Validated() = #externalMacro(module: "PearfyMacrosImpl", type: "ValidationMacro")

@attached(peer, names: named(__pearfy_marker))
public macro NotBlank() = #externalMacro(module: "PearfyMacrosImpl", type: "MarkerMacro")

@attached(peer, names: named(__pearfy_marker))
public macro Size(min: Int? = nil, max: Int? = nil) = #externalMacro(module: "PearfyMacrosImpl", type: "MarkerMacro")

@attached(peer, names: named(__pearfy_marker))
public macro Min(_ value: Int) = #externalMacro(module: "PearfyMacrosImpl", type: "MarkerMacro")

@attached(peer, names: named(__pearfy_marker))
public macro Max(_ value: Int) = #externalMacro(module: "PearfyMacrosImpl", type: "MarkerMacro")

@attached(peer, names: named(__pearfy_marker))
public macro Pattern(_ expression: String) = #externalMacro(module: "PearfyMacrosImpl", type: "MarkerMacro")
