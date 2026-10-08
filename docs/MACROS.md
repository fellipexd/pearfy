# Pearfy public macros

The source of truth for available macros is
[`Sources/PearfyMacros/PearfyMacros.swift`](../Sources/PearfyMacros/PearfyMacros.swift)
and the implementation registry is
[`Sources/PearfyMacrosImpl/PearfyMacroPlugin.swift`](../Sources/PearfyMacrosImpl/PearfyMacroPlugin.swift).
The categorized inventory and limits are maintained in the
[Pearfy Core Skill reference](../.agents/skills/pearfy-core/references/macros.md).

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
