# 14 — PearfyApprovals: maker-checker para uma ou duas outras pessoas

Módulo opcional `pearfy add approvals` depende de security, transaction store e auditoria durável; integra PearfyBackoffice quando instalado. Serve a pagamentos, exportação de CRM, concessão de role, mudanças de limites e outras operações tipadas.

## Modelo

`ApprovalPolicy` com action, required approvals (MVP 1 ou 2), `approverPermission`, resource/tenant scope, threshold/predicado determinístico, expiration, distinct approvers, requester exclusion, conflict-of-interest, policy version, optional MFA/step-up. Policy descreve **quem pode autorizar**, não executa operação diretamente.

`ApprovalRequest`: UUIDv7, actor, tenant, operation type, target ref, **canonical payload hash** + versão/schema, status, timestamps, expiry, idempotency key e policy snapshot. `ApprovalDecision`: actor, permission proof/ref, hash aprovado, timestamp, approve/reject, policy version. `ApprovalExecution`: single claim/result/recovery state.

## Máquina de estados

```text
DRAFT → PENDING(0/N) → PENDING(1/N) → APPROVED → EXECUTING → COMPLETED
                     ↘ REJECTED / EXPIRED / CANCELLED
                                             EXECUTING → UNKNOWN → RECONCILING
```

N=1 pula PENDING(1/N) quando aprovação completa. Não armazenar estado alternativo contraditório com ledger/domínio. Alterar amount/destinatário/permissão solicitada invalida request/decisions; reaprovação nova.

## Guardas obrigatórias

1. Solicitante tem permission `*.request` para action+resource+scope no momento de criar.
2. Cada aprovador é **outro usuário**, distinto de solicitante e dos aprovadores anteriores.
3. Cada aprovador tem `*.approve` requerido e escopo do recurso no ato da decisão. Hierarquia/grupo **não** concede permissão sem regra.
4. Antes de executar, revalidar policy/permissions/resource version/expiração; tratar revogação, versão e drift; nunca permitir `superadmin` bypass silencioso.
5. Uma ou duas aprovações não significam chamadas HTTP executadas duas vezes. Único claim de `ApprovalExecution`, constraint e transação compartilhada.
6. Se ação local na mesma DB, estado de aprovação + mudança de domínio no mesmo boundary transacional quando possível. Efeito externo exige outbox, idempotência remota/reconciliação; `COMMIT UNKNOWN` não é rollback.
7. Auditoria de decisão e versão, sem valor pessoal/saldo em log genérico.

## API-alvo ilustrativa

```swift
@ApprovalPolicy("high-value-refund", requiredApprovals: 2,
    approverPermission: "payments.refund.approve.high")
struct HighValueRefundApproval {}

@Post("/refund")
@RequiresPermission("payments.refund.request")
@RequiresApproval("high-value-refund")
func requestRefund(@RequestBody input: RefundInput) async throws -> ApprovalRequestDTO {
    try await refunds.request(input)
}
```

É proibido `requestRefund` devolver `completed` antes das decisões; método protegido de service precisa rejeitar bypass sem approval execution token autorizado, não somente controller. No body: `pending`, required/received, expiry e ID.

## Testes de concorrência/falhas

Três réplicas, duas aprovações simultâneas, usuário aprova duas vezes, requester=approver, aprovadores distintos mas mesmo login alias, troca de payload após 1a aprovação, revogação de permission entre etapas, expiração, rejeição, mudança de limite/policy, failover antes/depois commit, provider externo timeout, replay por idempotency, escalada de role por autoaprovação negada.
