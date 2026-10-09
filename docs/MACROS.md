# Pearfy public macros

The source of truth for available macros is
[`Sources/PearfyMacros/PearfyMacros.swift`](../Sources/PearfyMacros/PearfyMacros.swift)
and the implementation registry is
[`Sources/PearfyMacrosImpl/PearfyMacroPlugin.swift`](../Sources/PearfyMacrosImpl/PearfyMacroPlugin.swift).
The categorized inventory and limits are maintained in the
[Pearfy Core Skill reference](../.agents/skills/pearfy-core/references/macros.md).

## Applicability and verification matrix

This matrix lists every distinct public macro declared in this checkout. The
generated starter is an HTTP greeting service, so persistence, validation,
security, API-contract, and component-selection macros are intentionally
absent unless a starter feature actually needs them. “Not used in starter” is
not a recommendation to avoid the macro in an application that has that use
case.

| Public macro | Use when | Discovery / registration | Verification | HTTP starter |
| --- | --- | --- | --- | --- |
| `@Component` | A concrete type should be managed by Pearfy DI | `PearfyDiscoveryPlugin` finds it and generated `PearfyGeneratedRegistry.registerComponents(in:)` calls `__pearfy_register(into:)` | Generator dispatch is in `Sources/PearfyDiscoveryGenerator/main.swift`; no focused `@Component` runtime fixture currently exists | Not needed; the starter service uses the more specific `@Service` |
| `@Service` | A real application service or use case belongs in DI | Component registry plugin; explicit `registerComponents(in:)` call | `ProjectScaffolderTests` checks `@Service` and wired registry; `ServiceContainerTests` | Used for `GreetingService` |
| `@Repository` | A real infrastructure persistence adapter belongs in DI | Component registry plugin; explicit `registerComponents(in:)` call | `DiscoveredGreetingRepository.swift` and `ServiceContainerTests` | Not applicable; starter does not persist data |
| `@Entity(String)` | A supported persisted struct should expose schema metadata for a table | Entity metadata is collected by generated `PearfyGeneratedSchemaRegistry.entities` | `SchemaCompilerTests` expansion assertions | Not applicable; no persisted entity |
| `@Entity(SchemaEntity)` | An explicit schema expression should be exposed through a model type | Same generated schema registry as `@Entity(String)` | `SchemaCompilerTests` explicit schema declaration | Not applicable; no schema is required |
| `@ID` | A supported entity property defines the schema identifier | Consumed by `@Entity`; no independent registry entry | `SchemaCompilerTests` identifier expansion assertions | Not applicable; no entity |
| `@Column` | A supported entity property needs column metadata | Consumed by `@Entity`; no independent registry entry | `SchemaCompilerTests` column metadata assertions | Not applicable; no entity |
| `@ManyToOne` | A persisted entity owns a many-to-one foreign key | Stored in `SchemaEntity.relationships`; `SchemaIR` resolves it and materializes the FK column/constraint; entity discovery remains `PearfyGeneratedSchemaRegistry.entities` | `SchemaCompilerTests` checks generated registry metadata and PostgreSQL DDL | Not applicable; starter does not persist data |
| `@OneToOne` | A persisted one-to-one side owns a unique FK, or declares an inverse with `mappedBy` | Owning side produces a unique FK; inverse side resolves the named owner during `SchemaIR` validation | `SchemaCompilerTests` checks bidirectional metadata, uniqueness, and DDL | Not applicable; starter does not persist data |
| `@OneToMany` | A persisted Swift array is the inverse of a target `@ManyToOne` | Requires `mappedBy`; validated against the target owning relationship; does not add a column on the collection side | `SchemaCompilerTests` checks mappedBy resolution and absence of a collection column | Not applicable; starter does not persist data |
| `@ManyToMany` | Two persisted entities have a genuine many-to-many association | The owning side creates a deterministic junction table with non-null FKs and composite primary key; inverse side uses `mappedBy` | `SchemaCompilerTests` checks generated registry metadata, inverse mapping, canonical JSON, and PostgreSQL DDL; `PostgresIntegrationTests` covers live FK DDL | Not applicable; starter does not persist data |
| `@ContractModel` | A supported Codable struct defines an API contract schema | Generated `PearfyGeneratedSchemaRegistry.contractSchemas` gathers its `__pearfy_contractSchemas` | `ConnectContractCompilerTests` schema registry assertions | Not applicable; greeting response is not configured as a Connect contract |
| `@ContractField` | An API contract property needs explicit name or required metadata | Consumed by `@ContractModel`; no independent registry entry | `ConnectContractCompilerTests` field metadata assertions | Not applicable; no contract model |
| `@Autowired` | A supported component member uses the macro's field injection form | Consumed by `@Component` / `@Service` / `@Repository`; component registry wires the generated factory | `DiscoveredGreetingService.swift` and `ServiceContainerTests` | Not applicable; starter uses initializer injection |
| `@Inject` | A supported component member uses the macro's injection marker | Consumed by component macro; no independent registry entry | Expansion behavior is implemented in `ComponentMacro.swift`; no focused runtime fixture currently uses `@Inject` | Not applicable; initializer injection is sufficient |
| `@Qualifier` | A component binding needs a named qualifier | Consumed by component macro and DI binding | Expansion behavior is implemented in `ComponentMacro.swift`; no focused qualifier fixture currently exists | Not applicable; only one service binding |
| `@Primary` | One of multiple compatible bindings should be the preferred binding | Consumed by component macro and DI binding | Expansion behavior is implemented in `ComponentMacro.swift`; no focused primary-binding fixture currently exists | Not applicable; only one service binding |
| `@Bind` | A component binds an abstraction to an implementation type | Consumed by component macro; resulting binding is registered in the component registry | `DiscoveredGreetingRepository.swift` and `ServiceContainerTests` | Not applicable; starter has no repository abstraction |
| `@RestController` | A type declares static HTTP endpoints | Expands `__pearfy_registerRoutes(in:instance:)`; application composition must call it explicitly | `HTTPRouterTests` macro route tests and scaffold bootstrap test | Used by `GreetingController` and explicitly registered |
| `@Get` | A controller endpoint handles GET | Consumed by `@RestController`; registered by explicit generated registrar call | `HTTPRouterTests` route method and path assertions | Used by greeting endpoint |
| `@Post` | A controller endpoint handles POST | Same controller registrar | `HTTPRouterTests` macro route tests | Not applicable; no POST behavior |
| `@Put` | A controller endpoint handles PUT | Same controller registrar | `HTTPRouterTests.restControllerMacrosGenerateBoundRoutes` exercises the registered route | Not applicable; no PUT behavior |
| `@Patch` | A controller endpoint handles PATCH | Same controller registrar | `HTTPRouterTests.restControllerMacrosGenerateBoundRoutes` exercises the registered route | Not applicable; no PATCH behavior |
| `@Delete` | A controller endpoint handles DELETE | Same controller registrar | `HTTPRouterTests.restControllerMacrosGenerateBoundRoutes` exercises the registered route | Not applicable; no DELETE behavior |
| `@ResponseStatus` | A controller endpoint needs a supported non-default response status | Consumed by `@RestController` route expansion | `HTTPRouterTests` status assertions | Not applicable; greeting uses default status |
| `@Authenticated` | A route declares authenticated access metadata | Consumed by `@RestController`; actual auth middleware remains separately configured | `HTTPRouterTests` access metadata and security middleware tests | Not applicable; starter endpoint is public |
| `@PermitAll` | A route explicitly declares public access metadata | Consumed by `@RestController` | Scaffold test checks annotation; `HTTPRouterTests` access assertions | Used to make the starter route's public policy explicit |
| `@RolesAllowed` | A route declares a supported role policy | Consumed by `@RestController`; does not install authentication itself | `HTTPRouterTests` access metadata assertions | Not applicable; no role-restricted endpoint |
| `@RouteGroup` | A controller participates in a literal route group contract | Emits `__pearfy_routeGroup`; referenced by `@RestController(group:)` and registered through controller route setup | `HTTPRouterTests` grouped route test | Not applicable; one endpoint needs no shared group |
| `@Validated` | A supported value type should generate `validationViolations()` | Method is generated on the type; call it through validation APIs | `HTTPRouterTests` validation macro coverage | Not applicable; no input model |
| `@NotBlank` | A supported String field must not be blank | Consumed by `@Validated` | `HTTPRouterTests` validation macro coverage | Not applicable; no validated input |
| `@Size` | A supported field needs a supported length/range constraint | Consumed by `@Validated` | `HTTPRouterTests` validation macro coverage | Not applicable; no validated input |
| `@Min` | A supported comparable field needs a minimum constraint | Consumed by `@Validated` | `HTTPRouterTests` validation macro coverage | Not applicable; no validated input |
| `@Max` | A supported comparable field needs a maximum constraint | Consumed by `@Validated` | `HTTPRouterTests` validation macro coverage | Not applicable; no validated input |
| `@Pattern` | A supported String field needs a regular-expression constraint | Consumed by `@Validated` | `HTTPRouterTests.restControllerMacrosGenerateBoundRoutes` now checks a rejected pattern value | Not applicable; no validated input |

## Relationship schema example

```swift
@Entity("customers")
struct CustomerSchema {
    @ID var id: UUID
    @OneToMany(targetTable: "invoices", mappedBy: "customer")
    var invoices: [InvoiceSchema]
}

@Entity("invoices")
struct InvoiceSchema {
    @ID var id: UUID
    @ManyToOne(targetTable: "customers", column: "customer_id", nullable: false)
    var customer: CustomerSchema
}
```

The owning property adds `customer_id` and its deterministic FK to the schema
plan; the inverse collection adds no database column. Generate the migration
from the compiled registry with `pearfy migrations generate --product
<SwiftPM-product> --id <version_name>`. The app product implements
`--pearfy-export-schema <path>` by serializing
`SchemaIR(entities: PearfyGeneratedSchemaRegistry.entities)`.

An owning `@ManyToOne` or `@OneToOne` can include its physical FK column in the
entity primary key with `primaryKey: true`. Do not add a second `@ID` property
for the same database column:

```swift
@Entity("bank_accounts")
struct BankAccountSchema {
    @ID var id: UUID
}

@Entity("bank_account_balance_projections")
struct BalanceProjectionSchema {
    @ManyToOne(targetTable: "bank_accounts", column: "account_id", primaryKey: true)
    var account: BankAccountSchema
    @ID(strategy: .assigned) var currency: String
    @ID(strategy: .assigned) var scale: Int
}
```

This produces one non-null `account_id` column with an FK to
`bank_accounts.id` and the primary key `(account_id, currency, scale)`.
Relationship key columns come first in relationship property declaration
order, followed by scalar `@ID` columns in declaration order. Inverse and
many-to-many relationships cannot directly join the entity key. The planner
reports an explicit-migration diagnostic if an existing table's primary key
would change; it does not guess how to replace a live key.

For a real many-to-many association, the owning side declares `@ManyToMany`
and can set `joinTable`, `joinColumn`, `inverseJoinColumn`, referenced columns,
foreign-key names, and referential actions. Defaults are deterministic from
the source and target table names. A bidirectional inverse property uses
`@ManyToMany(targetTable: ..., mappedBy: "owningProperty")`. Pearfy adds the
junction table, two foreign keys, and a composite primary key to `SchemaIR`.
The relationship macros only describe schema: they do not provide ORM loading,
queries, or persistence operations.
Relationship targets currently reference one primary or unique column; composite
referenced keys and ORM fetch/cascade behavior are outside the implemented
schema contract.

The controller binding annotations `@PathVariable`, `@QueryParam`,
`@HeaderParam`, `@RequestBody`, and validation annotation `@Valid` are public
property wrappers, not macros. They are consumed by the `@RestController`
expansion (and validation APIs for `@Valid`). `HTTPRouterTests` exercises path,
query, body, and validation bindings; there is no focused `@HeaderParam` test
in this checkout. The starter uses `@PathVariable`; it has no query, header,
or body input to bind.

`pearfy architecture check` scans application Swift files under `Sources/`
and emits `REVIEW macro-policy` for direct `HTTPRouter` verb registrations that
have matching route macros. The diagnostic is advisory: static source scanning
cannot prove handler equivalence. Explain a valid dynamic or infrastructure
exception next to the registration. The check excludes test targets, and does
not claim a macro applies to code outside its supported expansion shape. If the
source tree is missing or exceeds scan limits, it reports `INCOMPLETE` instead
of treating unscanned files as clear.

For an application, use a macro when the public expansion represents the
intended behavior. HTTP controllers use `@RestController` and supported route
macros, then explicitly call the generated `__pearfy_registerRoutes` method.
Direct `HTTPRouter` route registration is an exception for a demonstrated
dynamic or infrastructure requirement without an equivalent macro; explain the
exception where the code is generated or migrated.

`pearfy init` uses the route macros for its one actual starter endpoint. It
does not add sample services, entities, validation rules, or route groups that
the application did not request. `pearfy migrate` is contract-first and does
not rewrite source; `pearfy migrate status routes|elements` reports macro
applicability and concrete limits for detected migration items. A suggestion is
not a claim that source conversion or semantic equivalence was verified.
