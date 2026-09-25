# Critérios transversais de qualidade e segurança

## Pipeline mínimo

- Swift 6.x fixado, `swift format`/lint quando adotados, `swift build`, `swift test` macOS/Linux.
- Strict concurrency sem uso indiscriminado de `@unchecked Sendable`.
- Unit tests DI, macro expansion tests, plugin-generated snapshot tests, HTTP contract tests, integration PostgreSQL e Redis/broker conforme módulo.
- Tests de falha: timeout, cancellation, indisponibilidade, reinício, conexão quebrada, token expirado, duplicidade de mensagens, rollback, DB migration parcial.
- Regressão de bootstrap: aplicações inválidas não abrem porta.
- Benchmark reprodutível: throughput, p50/p95/p99, memória RSS, cold start, consumo CPU; ambiente/flags/publicação sempre descritos.

## Threat model por módulo

- Web: body limits, header limits, timeout, parsers, path traversal, upload temporário e CORS.
- Data: queries parametrizadas, pool isolation, rollback, timeouts, secrets.
- Security: deny by default, algoritmo de assinatura JWT permitido, validações issuer/audience, políticas de tenant, proteção contra bypass.
- Cache: isolamento de namespaces/tenant, invalidation, TTL e dados sensíveis.
- Messaging: replay/idempotência, DLQ, secretos, limites de payload e concorrência.
- Actuator: endpoints de diagnóstico protegidos; jamais publicar secrets ou tokens.

## Release gates

- Nenhum marcador de estável sem documentação, testes macOS/Linux e API review.
- 1.0: ABI/source-compatibility policy, SemVer, changelog, CVE handling policy, release signing quando infraestrutura permitir, examples testados.
- Documentar claramente escopo da auditoria: passar CI não equivale a certificação de segurança.

## Compatibilidade de concorrência

Singletons devem ser `Sendable`/actors ou proteger mutabilidade com isolamento consistente. Request scope não deve ser armazenado num singleton sem provider seguro. Não carregar lock de thread através de `await`. Cancellation deve limpar recursos e devolver conexões ao pool.
