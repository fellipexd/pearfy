# Pearfy — roadmap consolidado v1.3 + protótipo histórico

> **ATUALIZAÇÃO v1.3 — PEARFY CONNECT:** novo complemento `docs/connect/` para `@RouteGroup`, exportação segmentada de SDK iOS/Android/TypeScript, REST/WS/gRPC, TLS/HPKE opcional, Postman por grupo, cURL individual, contratos `.pearfy`, CLI e Guardian. Começar por [`docs/connect/00-LEIA-ME-ROADMAP.md`](docs/connect/00-LEIA-ME-ROADMAP.md). Continua sendo planejamento, **não** uma fotografia da branch atual.

> **IMPORTANTE:** este ZIP reúne o roadmap inicial, o adendo de performance v1.1 e NOVOS documentos de arquitetura, ORM/migrations, transações, locking, pagamentos, múltiplas instâncias e Guardian. `Sources/` e `Tests/` são a fotografia do protótipo inicial e **não são apresentados como o código vigente que você já está implementando**. Integrar as decisões na sua branch, sem sobrescrever componentes novos.

## Comece aqui

- `AGENTS.md`: padrão mandatório para implementações por LLM.
- `docs/09-ROADMAP-ATUALIZADO.md`: índice dos novos marcos e precedência.
- `docs/decisions/01-ARQUITETURA-E-NOMES.md`: arquitetura default configurável e `PearfyTransactionalStore`.
- `docs/data/01-MODELOS-IDS-E-MIGRATIONS.md`: schema Swift, UUIDv7 e migrations.
- `docs/data/02-ORM-E-QUERIES.md`: ORM, tipagem, SQL, N+1.
- `docs/data/03-TRANSACTIONAL-STORE-E-TRANSACTIONS.md`: `@Transaction`, commit/rollback.
- `docs/data/04-LOCKING-E-CONCORRENCIA.md`: quem pede lock, quem executa e por quê.
- `docs/distributed/01-MULTI-INSTANCIA-E-BANCOS.md`: Opção A (decisão definitiva).
- `docs/distributed/02-GRPC-TRANSPORTE-E-OWNERSHIP.md`: quando gRPC é opcional.
- `docs/payments/01-PAYMENT-ENGINE.md`: contrato e fluxo de transferência.
- `docs/payments/02-IDEMPOTENCIA-LEDGER-OUTBOX.md`: garantias financeiras.
- `docs/ai/01-CONTRATOS-MCP-E-AI-READY.md`: contratos e MCP.
- `docs/ai/02-GUARDIAN-E-QUALITY-GATES.md`: regras e bloqueios para LLM.
- `docs/ai/03-SEGURANCA-POLITICAS.md`: autenticação/autorização e gates de segurança.
- `docs/integration/`: backlog, testes e prompt incremental para agente.
- `performance-addendum/`: documentação original de performance preservada.

---

# Pearfy 🍐 — roadmap e protótipo inicial

**The Swift application framework.** Objetivo: iniciar rapidamente aplicações backend nativas em Swift, com DI declarativa, controllers, dados, segurança, configuração, observabilidade e starters opcionais.

Este ZIP entrega **o roadmap de implementação** e **um protótipo executável de DI por construtor** aproveitado e renomeado do starter experimental anterior. Os exemplos anotados com `@Service`, `@Autowired`, `@RestController`, `@Transactional` e semelhantes nos documentos são **contratos-alvo (não estão implementados)**. Nenhum servidor HTTP, macro, descoberta automática ou CLI está implementado neste pacote.

## Arquivos de planejamento

| Arquivo | Conteúdo |
|---|---|
| `docs/01-ROADMAP.md` | Fases, dependências, entregas e gates até 1.0 |
| `docs/02-DI-E-MACROS.md` | DI anotada, descoberta, binding de protocolos e semântica de concorrência |
| `docs/03-API-PUBLICA.md` | API-alvo em exemplos ilustrativos de Swift |
| `docs/04-ARQUITETURA.md` | Módulos, dependências e organização de pacotes |
| `docs/05-QUALIDADE-E-SEGURANCA.md` | Matriz de testes, segurança e release gates |
| `docs/06-BACKLOG.md` | Issues priorizadas e critérios de aceite |
| `docs/07-PARIDADE-E-REFERENCIAS.md` | Mapeamento de capacidades inspiradas no ecossistema Spring Boot; **apenas documentação** |
| `docs/08-DECISOES.md` | ADRs iniciais e trade-offs |

## Protótipo executável atual

Requisitos: Swift **6.2+**, macOS ou Linux, Swift Package Manager.

```bash
swift build
swift test
swift run HelloPearfy
```

Existem apenas `PearfyCore` (registro e resolução síncrona por fábrica, escopos singleton/transient, detecção básica de ciclos) e `HelloPearfy` (exemplo por construtor). O contêiner ainda não resolve factories assíncronas, escopos HTTP, qualifiers, lifecycle, macros ou discovery, e **não está pronto para cargas de produção**.

## Regra editorial do projeto

As referências de inspiração a outros frameworks aparecem somente em arquivos `.md`. Nomes de módulos, identificadores, comentários, código Swift e demais arquivos utilizam linguagem e identidade próprias do Pearfy. O script de verificação `scripts/check-branding.sh` valida essa regra para os arquivos que não são Markdown.

## Próximo passo concreto

Implementar `PDI-001` a `PDI-007` do backlog e a prova de conceito de macros + discovery em pacotes Swift distintos, com uma aplicação de exemplo que prove registro automático de componentes sem código manual de composição.


## Adendo v1.4 — extensões e operações
Ler `docs/extensions/README-v1.4.md` e `docs/extensions/00-VISAO-GERAL-E-DECISOES.md`; novo roadmap modular para PearfyAI, Messaging/Chatbot/canais, BKO/Approvals/CRM, Logs/Observability/Metric, Jobs/Webhooks, integração externa e Blueprints. Exemplos de CLI e Swift são propostas, não funcionalidades implementadas automaticamente. O prompt de integração está em `docs/extensions/integration/PROMPT-PARA-AGENTE.md`.
