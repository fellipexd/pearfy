# Ideias de outros ecossistemas e o que adaptar

| Referência | Ideia útil | Tradução em Pearfy | Não copiar literalmente |
|---|---|---|---|
| Go | goroutines + simplicidade de deploy | API async simples, capacidade e diagnóstico | scheduler/GC do Go |
| Go | perf tooling e budgets de memória | métricas/benchmarks e limites por estágio | API runtime de GC inexistente em Swift |
| Rust | ownership e alocação consciente | `borrowing`, `consuming`, `~Copyable` onde medido | obrigar todos os DTOs a serem move-only |
| Java | AOT e bootstrap previsível | registry/factories gerados | reflexão/classpath scanner JVM |
| Java/Netty | pipelines de rede | adapter SwiftNIO e middleware medido | reescrever Netty em Swift |
| Node.js/Fastify | schemas e serializers especializados | binding/validation/serialization gerados | runtime JavaScript/V8 |
| Swift | strict concurrency, actors, ARC | isolamento explícito, objetos imutáveis, profiling | actor global e pools indiscriminados |

Este documento é uma comparação de arquitetura e não prevê qual linguagem/framework vencerá cada workload. Exemplo de referências tecnológicas a investigar quando implementar: SwiftNIO, Swift Evolution ownership, Go runtime/GC, Java AOT e Fastify schemas. Fixar versão e fonte oficial na issue correspondente.
