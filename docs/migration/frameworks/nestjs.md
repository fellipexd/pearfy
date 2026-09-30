# NestJS → Pearfy: implemented route analyzer

The analyzer recognizes `@Controller` prefixes and method-level `@Get`,
`@Post`, `@Put`, `@Patch` and `@Delete` path decorators in TypeScript. It
records method/path, handler/controller names and relative-file evidence. OpenAPI
remains the preferred source for request/response schemas and security.

Guards, interceptors, pipes, exception filters, DI provider scopes, event
handlers and transaction semantics are not translated. Treat discovered route
metadata as evidence, not an implementation plan or a proof of parity.
