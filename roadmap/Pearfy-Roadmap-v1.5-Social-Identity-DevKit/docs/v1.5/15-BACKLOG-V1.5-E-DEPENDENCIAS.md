# Backlog v1.5 com precedência

| Marco | Entrega | Pré-requisito | Gate |
|---|---|---|---|
| V0 | Inventariar o checkout Pearfy e congelar baseline de build/teste | Checkout Pearfy | Matriz real de implementações |
| V1 | Module Registry + versioned capabilities | Module Manager v1.4 | No planned API treated implemented |
| V2 | Skills por módulos instalados + recipes | V1 | Skill-version match |
| V3 | MCP read-only e plan/diff | V1/V2 | Scope, schema, no sensitive leakage |
| V4 | MCP write tools + CI Guardian integration | V3 | Authz/write approval/real gates |
| V5 | Identity social-login + optional relation | Identity/Security/Data | First-login concurrency, OAuth tests |
| V6 | SocialCore, Actor, Graph/visibility | Data/Security/Identity adapter | Visibility blocks and races |
| V7 | SocialContent & moderation state | V6/Data/Jobs | Concurrent reaction+revision |
| V8 | SocialFeed & Connect SDK parity | V7/Connect | Cursor/privacy/performance |
| V9 | Release dos módulos independentes | V0 + gates V1–V8 | API docs, opt-in build, tests, rollback e suporte de versão |

Não exigir terminar o DevKit completo antes de liberar módulos Social já verificados. Priorizar contratos genéricos e módulos opt-in; não adicionar dependências de Payments/Chatbot/CRM ao Social sem necessidade comprovada.
