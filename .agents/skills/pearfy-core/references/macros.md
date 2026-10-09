# Public Pearfy macro inventory

This list was checked against `Sources/PearfyMacros/PearfyMacros.swift`,
`Sources/PearfyMacrosImpl/PearfyMacroPlugin.swift`, and their expansion code in
this checkout. It describes actual compiler support, not roadmap proposals.
For a row-by-row application, registration, test, and starter-app matrix, see
[`docs/MACROS.md`](../../../../docs/MACROS.md).

## HTTP controllers, routes, binding, and policy

The public macros are `@RestController`, `@Get`, `@Post`, `@Put`, `@Patch`,
`@Delete`, `@ResponseStatus`, `@Authenticated`, `@PermitAll`, and
`@RolesAllowed`. The route macros are marker macros consumed by
`@RestController`. The controller macro emits
`__pearfy_registerRoutes(in:instance:)`; application startup must call that
method explicitly. It supports controller structs/classes, literal paths,
the five listed HTTP verbs, typed return conversion, response status, and the
current parameter-binding annotations. It does not auto-discover/register
controllers.

`@PathVariable`, `@QueryParam`, `@HeaderParam`, `@RequestBody`, and `@Valid` are
public property wrappers, not compiler macros. The controller macro recognizes
them on endpoint parameters. Unannotated parameters are accepted only when
their type is `HTTPRequest`.

`@Authenticated`, `@PermitAll`, and `@RolesAllowed` declare route access
metadata. They do not authenticate credentials or install security middleware.
`@RouteGroup` creates literal route-group contract metadata and may be attached
to a controller through `@RestController(group: Type.self)`; it does not grant
authorization.

## Validation

`@Validated` generates `validationViolations()` for supported stored fields.
The public constraint marker macros are `@NotBlank`, `@Size`, `@Min`, `@Max`,
and `@Pattern`. The current expansion applies `@NotBlank`, `@Size`, and
`@Pattern` to `String`; `@Min`/`@Max` use comparable supported values. The
`@Valid` property wrapper marks a controller body parameter for validation.
There is no public `@Email` or `@NotNull` macro in this checkout.

## Dependency injection and component registration

`@Component`, `@Service`, and `@Repository` generate `__pearfy_register(into:)`
for supported nongeneric struct/class/actor components. The marker macros
`@Autowired`, `@Inject`, `@Qualifier`, `@Primary`, and `@Bind` provide input to
that expansion. The build plugin generates `PearfyGeneratedRegistry`; app code
must call `registerComponents(in:)` explicitly. There is no runtime reflection
or automatic container registration.

## Persistence schema metadata

`@Entity` generates `__pearfy_schema` for a struct with explicit stored
properties whose types map to the current schema types, or forwards an explicit
`SchemaEntity` expression. `@ID` and `@Column` are marker macros consumed by
that expansion. Persisted associations use `@ManyToOne`, `@OneToOne`,
`@OneToMany`, and `@ManyToMany` when their semantics fit. `@ManyToOne` owns its
FK; `@OneToOne` owns a unique FK unless it declares `mappedBy`; `@OneToMany` is
inverse-only and requires `mappedBy` to a target `@ManyToOne`; `@ManyToMany`
uses an owning-side junction table (optional explicit table/column names) and
an inverse-side `mappedBy` when bidirectional. `SchemaIR` resolves these
relationships, validates targets and unique reference columns, then
materializes FK columns, constraints, or a composite-key junction table for
PostgreSQL DDL planning. These macros describe schema only; they do not load,
save, cascade, or query objects at runtime. Keep them in infrastructure schema
models and leave access to repositories/adapters.

An owning `@ManyToOne` or `@OneToOne` may use `primaryKey: true` to make its
generated FK column a non-null entity key component without a duplicate scalar
property. Relationship key columns precede scalar `@ID` columns, preserving
declaration order within each group. Inverse and many-to-many associations
cannot participate directly. Changing an existing table's primary key requires
an explicit migration; the planner reports `PEARFY_SCHEMA_021`.

## API contract metadata

`@ContractModel` generates `__pearfy_contractSchemas` for supported nongeneric
Codable structs. `@ContractField` supplies field-name/required metadata. The
discovery plugin creates a target-local contract registry; it does not generate
client SDKs.

## Selection and migration rules

- Prefer a macro only when its current expansion preserves the source behavior
  and its generated registration mechanism is wired in the application.
- Mark a macro `not applicable` when the project has no corresponding route,
  component, schema, or contract use case.
- Mark it `not supported` with a concrete reason when the source has a relevant
  behavior that the current macro cannot express, the analyzer did not extract
  enough information, or an equivalence cannot be shown.
- Keep low-level HTTP/router, container, or schema code for demonstrated
  dynamic/infrastructure needs or unsupported semantics. State the exception
  and reason in generation/migration notes.
- Never infer availability from a roadmap entry. In particular this inventory
  contains no transaction, scheduler, listener, ORM, or authentication-provider
  macro.
- Run `pearfy architecture check` after editing a Pearfy application. It scans
  static direct `HTTPRouter` registrations under `Sources/` and emits an
  advisory `REVIEW macro-policy` when a route macro may apply; it excludes
  tests and cannot establish semantic equivalence on its own.
