# 17 — PearfyConnect Backoffice SDK e UI opcionais

Mantém decisão v1.3: `@RouteGroup(name:"backoffice", prefix:"/bko", sdk:[.typescript])` exporta SDK TypeScript e collection Postman BKO. `/app` iOS+Android e `/public` três continuam independentes. SDK não é limite de segurança.

```text
@pearfy/backoffice (TS)
  auth.me(), users.*, groups.*, roles.*, permissions.*, approvals.*,
  audit.*, crm.customers.*, crm.tasks.*, crm.insights.*
```

`@pearfy/backoffice-ui` (React) é opt-in por `pearfy add backoffice-ui --framework react`; geração de páginas de lista/form, árvore de grupo, grants, approvals inbox, histórico e CRM; componentes expõem capability da sessão para UX, mas enforcement inteiro reside no backend.

## Exemplo TS conceitual

```typescript
const bko = new BackofficeClient({baseURL: "https://api.exemplo.com"});
const pending = await bko.approvals.list({status: "pending", assignedTo: "me"});
await bko.approvals.approve({requestId: pending.items[0].id,
  comment: "Conferido"});
```

Considerar `If-Match`/version em ações concorrentes; request não significa execução concluída. Export schema com operações request/approve/reject/cancel/status, erros tipados `Forbidden`, `Expired`, `AlreadyDecided`, `Conflict`, `ExecutionUnknown`.

## Generator/guardrails

Postman collection **por grupo**, cURL **por endpoint**, environment sem segredo e SDK não inclui campos internos de RBAC (credential hash, hashes de payload, raw PII) nem capability que represente ACL bypass. Interface nunca interpreta `session.permissions` como autorização de servidor.

## Gate

Mudança de policy reflete em SDK/contracts; BKO React não compila se DTO alterou; operação direta via cURL respeita perms/aprovações; kit UI pode ser removido sem desinstalar backend.
