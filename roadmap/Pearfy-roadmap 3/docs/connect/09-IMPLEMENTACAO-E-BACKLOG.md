# Plano de implementação incremental e backlog do Pearfy Connect

> Não reiniciar/refatorar módulos prontos por causa dos exemplos. Primeiro comparar este plano com o estado real do repositório. "P0" significa prioridade para implementação do Connect, não implica funcionalidade já entregue.

| ID | Prioridade | Dependências | Entrega e gate |
|---|---|---|---|
| PCON-000 | P0 | repo atual | inventário código/testes/contratos/CLI e matriz pronto/parcial/ausente |
| PCON-001 | P0 | macros/discovery/route registry | `@RouteGroup`, composição path, registro estável, export policy; group collision tests |
| PCON-002 | P0 | PCON-001, DTO/schema | Contract IR determinística e typed operation IDs; golden schema tests |
| PCON-003 | P0 | PCON-002 | OpenAPI por grupo com auth/erro/exemplos; lint+request conformance |
| PCON-004 | P0 | PCON-002 | `.pearfy` versionado, subset por grupo, hashes, no-secrets; roundtrip test |
| PCON-005 | P0 | PCON-003/004 | SDK Swift iOS REST compila e executa chamadas reais |
| PCON-006 | P0 | PCON-003/004 | SDK Kotlin Android REST emulador/target de CI |
| PCON-007 | P0 | PCON-003/004 | SDK TypeScript REST em browser+Node fixtures |
| PCON-008 | P0 | PCON-003 | collection Postman HTTP por grupo + cURL por rota; paridade total |
| PCON-009 | P0 transversal | PCON-001..008 | Guardian contract/source parity, anti-leak e generation gate |
| PCON-010 | P1 | 002, auth infra | reusable auth providers, refresh, cancellation, retries seguros, errors typed |
| PCON-011 | P1 | 002, runtime WS | WS typed contracts + 3 clients + reconnect/backpressure/cursor se disponível |
| PCON-012 | P1 | 002, grpc-swift/server | Protobuf stable schema e gRPC clients; browser adapter + capability check |
| PCON-013 | P1 | 004, release infra | semver/contracts published baselines + compatible mobile version testing |
| PCON-014 | P1 | 008, 011, 012 | aux WebSocket/gRPC; Postman/CLI capabilities report |
| PCON-015 | P2 / security gate before feature release | 010, threat model | HPKE candidate interoperable REST requests, KMS, nonce/replay, audit |
| PCON-016 | P2 / security gate before feature release | 015 | bidirectional responses, key separation, key rotation, error envelope |
| PCON-017 | P2 | 011/012/015 | sealed WS/gRPC per message/stream only after formal framing review |
| PCON-018 | P2 | Connect stable | PearfyFlow hooks: typed flow states and navigation contracts (separate ADR) |

## Dependências importantes

- DI/Route Discovery do core estão no caminho crítico do registry correto; macros sem discovery global não bastam.
- PearfySecurity autenticação server-side + TLS antes de declarar o SDK apto a produção. Payload sealed não deve bloquear P0 REST simples, mas não marcar feature sealed pronta antes de PCON-015/016.
- gRPC é para serviços e clientes que o demandem; não alterar a decisão do PearfyTransactionalStore multi-instância.
- Postman e cURL gerados desde P0 REST; não tratá-los como documentação opcional.

## Fatias de entrega demonstráveis

- Slice 1: `/bko/auth/login` apenas TS; `/app/auth/login` apenas Swift+Kotlin; `/public/users/{id}` nos três; sem vazamento entre grupos.
- Slice 2: `sdk generate --all`, `export postman`, `export curl`; bytes estáveis, tudo compilável.
- Slice 3: auth/retry errors e contrato breaking change detectado antes de release.
- Slice 4: WS events, gRPC+browser compatibility; capabilities corretamente declaradas.
- Slice 5: request/response sealed num endpoint de teste, rotação key e replay cross-replica em ambiente controlado.

## Definition of done

Não é suficiente ter documentação ou saída fake: handlers reais funcionam, artefatos são importáveis/compiláveis, testes cruzados aprovados, erros precisos, gates automáticos e registros de versões suportadas. Publicar sem coverage das funcionalidades anunciadas = não concluído.
