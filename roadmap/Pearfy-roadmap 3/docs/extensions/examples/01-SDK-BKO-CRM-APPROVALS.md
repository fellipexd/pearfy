# Exemplo conceitual — grupo BKO, CRM e aprovação

Não colar no repositório antes de confirmar macros e providers implementados. É uma representação da UX desejada.

```swift
@RouteGroup(name: "backoffice", prefix: "/bko", sdk: [.typescript])
enum BackofficeAPI {}

@ApprovalPolicy("customer-export", requiredApprovals: 1,
    approverPermission: "crm.export.approve")
struct ExportApproval {}

@ApprovalPolicy("high-value-refund", requiredApprovals: 2,
    approverPermission: "payments.refund.approve.high")
struct RefundApproval {}

@RestController("/crm/customers", group: BackofficeAPI.self)
final class CustomerController {
    @Get("/{id}")
    @RequiresPermission("crm.customer.read")
    func find(@PathVariable id: UUID) async throws -> CustomerDTO {
        // Service revalida actor, tenant, owner/group scope.
        try await crm.findAuthorizedCustomer(id: id)
    }

    @Post("/export")
    @RequiresPermission("crm.export.request")
    @RequiresApproval("customer-export")
    func requestExport(@RequestBody input: CustomerExportInput)
        async throws -> ApprovalRequestDTO {
        try await crmExports.request(input)
    }
}
```

**Fluxo correto:** POST /bko/crm/customers/export cria solicitação pendente; outro usuário com permission apropriada no tenant aprova; worker/execução idempotente verifica snapshot da operação e política, executa export; status e audit acessíveis no SDK. O controller não deve ser único local do guard.

```typescript
const bko = new BackofficeClient({baseURL: "https://api.exemplo.com"});
const pending = await bko.approvals.list({status: "pending", assignedTo: "me"});
await bko.approvals.approve({requestId: pending.items[0].id});
```

Gerar collection `backoffice.postman_collection.json` e arquivo cURL por rota BKO com auth placeholders, sem secrets.
