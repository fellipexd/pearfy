# Frameworkless Node.js → Pearfy: implemented analyzer boundary

The generic Node.js adapter works without a framework declaration. It scans
bounded JavaScript/TypeScript source for Express-like `app`, `router` or
`server` calls to `get`, `post`, `put`, `patch`, `delete`, `head` and `options`
with a literal path. Each result is a medium-confidence source-evidence route.

It does not infer middleware order, authorization, validation, transaction or
side-effect semantics from arbitrary JavaScript. Import OpenAPI/Swagger when
available, preserve disagreements, and manually review inferred behavior.
