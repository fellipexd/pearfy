# Spring Boot → Pearfy: implemented analyzer boundary

The CLI 0.1.0 analyzer uses Spring source as evidence, not as the canonical
contract. OpenAPI/Swagger documents remain authoritative evidence alongside
route annotations; disagreements are retained as conflicts.

## Detection

The current source scan recognizes `pom.xml` and Gradle metadata containing
Spring Boot dependencies, plus Java/Kotlin source indicators such as
`@SpringBootApplication`, `@RestController` and `@RequestMapping`.

It also records type/method annotations for controllers, services, repositories,
entities, transaction boundaries, authorization, validation, scheduled jobs and
Kafka/RabbitMQ/JMS listeners. Annotation text is capped and stored as
contract metadata/evidence; source implementations are never copied.

## Extracted routes

The implemented route extractor recognizes class-level `@RequestMapping` path
prefixes and common method annotations:

- `@GetMapping`
- `@PostMapping`
- `@PutMapping`
- `@PatchMapping`
- `@DeleteMapping`
- `@RequestMapping(method = RequestMethod.<VERB>)`

It records method, joined path, method name, relative source path, confidence,
and evidence summary. It does not copy source snippets. OpenAPI contributes
request/response schemas, examples, parameters, operation IDs and security
scheme names.

## Review required

The analyzer does not convert constructor injection, transaction propagation,
Spring Security expressions, ORM relationships, delivery guarantees, cache
behavior or exception handlers into Pearfy code. The recorded annotations are
discovery evidence, not proof of semantic equivalence. Unknown or lossy
constructs need review and must remain unresolved in the canonical contract.
Compilation is not route closure; use per-route E2E parity after implementing
the Pearfy route.
