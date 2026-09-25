# Suítes de testes, requisitos verificáveis e falhas

## Contratos e grupos

| Cenário | Resultado esperado |
|---|---|
| `backoffice` `/bko/auth/login` + TypeScript | gera TS e collection/cURL de backoffice; não aparece nos pacotes Mobile |
| `mobile` `/app/auth/login` + iOS/Android | gera Swift+Kotlin, NÃO TS; collection/cURL mobile |
| `public` `/public/users/{id}` + 3 targets | mesmas semânticas de DTO, errores, path, status em 3 libs |
| rota sem grupo | não exporta (ou erro em strict), nunca público por acidente |
| override amplia target fora do grupo | erro de compilação/generation |
| dois métodos/path iguais | erro com file:line e ids |
| grupo faltante ou versão inválida | falha não-zero |
| gRPC agrupado | não prefixa `/app` em service/method wire |

## SDK e transportes

- Unit+integration para serialização: UUID, Decimal/Money (string/integer definido), datetime/timezone, nullable, arrays, mapas, enum desconhecido, arquivo grande, resposta vazia.
- Cada SDK realiza chamadas contra servidor fixture real, não apenas mocks; compile Swift/macOS+iOS target, Kotlin Android, TS Node/browser fixtures.
- REST: path/query escapados, multipart, body, error mapping, cancellation, redirects, TLS.
- WS: reconnection, heartbeat, stream backpressure, auth expire, cursor present/absent, duplicate/dropped events.
- gRPC: unary/streaming, cancellation, deadline, field compatibility, name reserved; browser capability fails when unsupported.
- Generated artifacts não podem importar dependências privadas não documentadas.

## Crypto e autenticação (quando feature implementada)

- TLS inválido/falso; plaintext downgrade rejeitado; token ausente/inválido/expirado.
- Bind method/path/group/requestId em AAD; adulteração de qualquer campo deve falhar antes de handler.
- Interop Swift ↔ servidor, Kotlin ↔ servidor, TS Browser+Node ↔ servidor com golden vectors.
- Requests em paralelo nas réplicas A/B, mensagem repetida, messageId novo com mesma idempotencyKey financeira, stale `kid`, rotação e invalid key.
- Resposta vinculada a request, não reutilizável/trocável por outra; timeout after-commit deve conservar idempotência.
- PII/secret scanning em manifests, SDKs, Postman, cURL, logs de falhas e traces.
- Device/browser comprometido explicitamente não coberto pelo envelope, nunca afirmar proteção que o sistema não entrega.

## Postman e cURL

- Parse/import válido da collection na versão escolhida; pastas do grupo, requests corretas, auth herdada conforme contrato.
- `--combined` agrupa por nome sem colidir `Auth`; sem vazamento de variável entre ambientes.
- cURL com paths/query escapados, placeholder sem credencial, status esperado e body válido.
- Rotas sealed: cURL usa helper e Postman documenta limitações; sem request em claro de exemplo que pareça funcional.
- HTTP coverage por grupo = 100% dos endpoints REST exportáveis declarados, ou exclusões justificadas no relatório.

## Compatibilidade

Contrato vN vs vN+1: remoção de endpoint, mudanças de nome, tipos/required, deprecation, enum handling, changes de autenticação, evento, Protobuf field number/reserved e diferenças entre published app clients. Testar instalação de SDK anterior contra nova API enquanto suportado. Comparar antes e depois; nunca aprovar breaking change só porque latest SDK compila.

## Performance

Benchmark opcional mas obrigatório para aprovação de claim de performance: bare HTTP vs generated SDK, TLS vs sealed, payloads pequeno/grande, p50/p95/p99, RPS, RSS e CPU em iOS/Android/TS/server. WebSocket reconnection load e canais gRPC reutilizados. Nada de números estimados como benchmark realizado.

## Release gates

Um milestone é aprovado somente com implementação e testes reais no repositório do usuário, revisão/hash, versões/ambiente declarados, zero gate obrigatório FAIL/INCOMPLETE. Um recurso P2 não executado pode permanecer planejado — mas não anunciado como entregue.
