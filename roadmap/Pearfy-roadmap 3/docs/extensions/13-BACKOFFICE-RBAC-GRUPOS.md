# 13 — PearfyBackoffice: RBAC, grupos, herança e escopo

Instalação opt-in: `pearfy add backoffice`; `/bko` gera SDK TypeScript via PearfyConnect. Backend implementa segurança em todas as camadas, sem depender de esconder menu no React. UI `backoffice-ui` opcional e separada.

## Modelo de autorização

- `Permission`: string estável e específica (`crm.customer.read`, `crm.customer.assign`, `payments.refund.request`, `payments.refund.approve.high`).
- `Role`: conjunto de permissions e herança acíclica de roles. `Supervisor extends Atendimento`, mas não eleva automaticamente acesso a todos os tenants.
- `Group`: árvore organizacional (organização/departamento/equipe), filiação usuário-grupo e atribuição de roles no escopo; herança de grupo e de role são eixos diferentes.
- `Scope`: `own`, `team`, `descendants`, `organization`, `resource-specific` ou constraints customizadas; negação padrão; nunca confiar em ownerId enviado pelo cliente.
- `Decision`: `(actor, action, resource, organization, context, policyVersion)` -> allow/deny with reason code. Evitar cache de auth sem invalidação por revogação.
- `Delegation`: eventual módulo futuro com expiração, impossibilidade de conceder algo acima do próprio escopo e revogação auditada; não escopo MVP.

```text
Org A
 ├─ Comercial
 │   └─ Fortaleza → Atendimento → Supervisor (herda Atendimento)
 └─ Financeiro
     └─ Controladoria → AprovadorFinanceiro
```

Supervisor Fortaleza pode herdar `crm.customer.read` de Atendimento apenas para sua equipe, não para Org B ou financeiro por simples ancestralidade.

## Operações e CRUD geradas

Usuários BKO, grupos, filiações, roles, role-permissions, herança e assignments; todas alterações com audit/event e policy enforcement. Proteção contra self-elevation/elevar próprio grupo e ciclos de role. Sessões BKO com MFA configurável para operações críticas e revogação por política; `PearfyIdentity` pode ser usado como provider se instalado.

## Armazenamento mínimo proposto

`bko_users`, `bko_groups`, `bko_group_members`, `bko_roles`, `bko_role_inheritance`, `bko_permissions`, `bko_role_permissions`, `bko_user_role_assignments`, `bko_audit_events` (migrações SQL reviewáveis).

Chaves/constraints de tenant para cada relação; nunca permitir join sem tenant/scope corretos. Grupos hierárquicos precisam validar ciclo e manter semântica bem definida de subtree queries para banco certificado.

## SDK

`@RouteGroup(name:"backoffice",prefix:"/bko",sdk:[.typescript])` + CRUD/permissions/approvals via PearfyConnect. Expor `/bko/auth/me` com capabilities da sessão para UX; nenhum campo privado do modelo RBAC no contrato público por default. Collection Postman BKO separada.

## Segurança e aceite

Negação sem permission, scope tenant errada, permissão revogada no meio de sessão, herança em ciclo, assignment escalando privilegio, role sem impacto no grupo certo, admin sem bypass de approvals, versão antiga do SDK e acesso direto via cURL não autorizado. Em 3 réplicas, revogação/alteração se propagam por storage + mecanismo válido de cache invalidation, não só cache local indefinido.
