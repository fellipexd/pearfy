# Application architecture

Pearfy uses Clean Architecture as the default for new projects and for projects whose architecture style is unspecified. The business profile (`standard-api`, `financial-transactional`, and others) selects capabilities and dependencies; it does not override the architecture style. A project that already declares a style keeps it.

The default dependency direction is inward:

- **Domain** owns business rules and domain values. It does not depend on Pearfy, databases, HTTP, or external services.
- **Application** owns use cases and application services. It depends on domain contracts, not infrastructure implementations.
- **Infrastructure** implements persistence and external-service adapters and contains the composition root that wires the application.
- **Presentation** contains HTTP controllers and transport-facing request/response types. It delegates work to application use cases.

These are responsibility boundaries, not a requirement to create empty directories. Add a repository contract and adapter when persistence is part of the application. Do not add a placeholder repository to a persistence-free starter.

## Pearfy macros by role

Use a public macro when its documented semantics fit the code being written:

- `@Service` registers an actual application service/use case for generated dependency-injection discovery.
- `@Repository` registers an actual repository adapter; preserve its protocol binding semantics.
- `@RestController` and supported route, binding, and policy annotations declare HTTP endpoints in Presentation. Call the generated route registrar explicitly.
- `@Entity`, `@ID`, and `@Column` describe supported persisted schema models. `@Entity` is not an ORM and is not a generic domain-model macro.
- `@ContractModel` and `@ContractField` describe supported API contract schemas when PearfyConnect is selected. They are not required for every domain value.

There is no general-purpose Pearfy model macro. Do not invent APIs or add annotations without a matching purpose. When using low-level APIs because a supported macro does not cover a demonstrated dynamic or infrastructure need, record that reason in the implementation or migration report.

## Existing and migrated projects

Preserve a style already declared in project metadata. If the style is absent, treat the project as `clean` and persist that value in generated or updated Pearfy architecture metadata. A migration must preserve behavior and only introduce Clean Architecture boundaries where the existing code can be mapped safely; report unsupported mappings rather than generating misleading layers.
