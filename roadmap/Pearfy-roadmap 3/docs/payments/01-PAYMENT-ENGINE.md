# PearfyPayments — PaymentEngine independente do banco

**Estado:** módulo opcional, contrato-alvo. O motor é uma biblioteca de domínio financeira em cada réplica da API, **não** um servidor único obrigatório.

## API pública-alvo (ilustrativa)
```swift
public protocol PaymentEngine: Sendable {
    func transfer(_ input: TransferInput) async throws -> TransferResult
    func reserve(_ input: ReserveFundsInput) async throws -> ReservationResult
    func release(_ input: ReleaseReservationInput) async throws -> ReservationResult
    func reverse(_ input: ReversalInput) async throws -> ReversalResult
}

public struct TransferInput: Codable, Sendable {
    let requestId: UUID          // intenção/idempotência do chamador
    let sourceAccount: UUID
    let destinationAccount: UUID
    let amount: Money
}

@Service
final class TransferService {
    @Autowired var payments: any PaymentEngine
    func transfer(_ input: TransferInput) async throws -> TransferResult {
        try await payments.transfer(input)
    }
}
```

`Money` usa representação exata com escala/rounding definidos por moeda. UUIDv7 é estratégia padrão de IDs gerados para entidades, não substitui requestId idempotente. Toda API exposta exige autenticação/autorização efetivas de contas e tenants.

## Protocolo de transferência interna de um banco lógico
0. Pré-validar sintaxe, limites estáticos e autenticação sem segurar locks; validar autorização dinâmica de novo dentro da unidade se estado relevante puder mudar.
1. `store.withTransaction { tx in ... }`, com conexão/tx física única.
2. Claim idempotente atômico em chave única compartilhada; se já concluído, devolver resultado estável; parâmetros divergentes -> rejeitar.
3. Adquirir proteção de origem/destino em ordem determinística por adapter certificado; não confiar em saldo lido antes dos locks.
4. Confirmar status, moeda, ownership, limites e saldo disponível no estado protegido.
5. Atualização condicional de saldo; verificar linhas afetadas; aplicar crédito na mesma tx.
6. Registrar lançamentos de ledger equilibrados e imutáveis; registrar resultado idempotente e outbox na mesma tx.
7. Retorno normal -> COMMIT; erro -> ROLLBACK; queda/timeout ao confirmar -> **UNKNOWN** até reconciliação.

O motor não deve abrir `requiresNew` oculto quando participa de `@Transaction(.required)` no mesmo storage, pois isso quebraria atomicidade da operação mais ampla.

## Ownership da escrita
Repos comuns podem ler saldo; gravar saldos/lançamentos confirmados só via contexto com capacidade financeira controlada. O Guardian denuncia updates diretos, mas controles de permissão/constraints no banco complementam os checks estáticos.

## Interfaces internas
`PaymentAuthorizer`, `FinancialPolicy`, `LedgerStore`, `IdempotencyStore`, `TransactionalStore`, `OutboxStore`, cada um com contrato e erros tipados; nenhuma classe do núcleo faz import de driver específico. Não criar `PaymentEngine` duplicado por adapter.

## Falhas
- Insufficient funds -> rejeição de negócio durável conforme política.
- Deadlock/serialization -> repetir unidade inteira quando seguro.
- Commit unknown -> consultar operação por idempotência antes de qualquer tentativa.
- Reservas não podem expirar e liberar fundos após liquidação sem máquina de estados validada.
- Pagamento externo usa orquestrador diferente: nunca acreditar que ROLLBACK reverte operação enviada a provedor.
