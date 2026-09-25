# PearfyTransactionalStore + PearfyTransactionManager

**Regra:** a abstração é genérica, independente de domínio e de fornecedor; garantias reais são implementadas por adaptadores certificados.

## Divisão
- `PearfyTransactionalStore`: abre unidade de trabalho e apresenta capacidades tipadas de leitura/escrita transacional.
- `PearfyTransactionManager`: begin/commit/rollback, propagação, timeout, contexto de transação, cleanup e classificação de erros.
- `PearfyConcurrency`: protocolo de lock/optimistic/conditional update por adapter.
- Drivers: SQL/recursos concretos; todos os repositories dentro da unidade usam **a mesma transação física**.

## APIs-alvo (ilustrativas)
```swift
@Service
final class TransferService {
    @Autowired var accounts: any AccountRepository

    @Transaction(propagation: .required, isolation: .readCommitted)
    func transfer(_ input: TransferInput) async throws -> TransferResult {
        try await accounts.transfer(input)
    }
}

let value = try await store.withTransaction { tx in
    try await tx.accounts.reserve(id: accountID, amount: amount)
}
```

A macro `@Transaction` deve gerar wrapper real que delimita a operação e preserva retorno, throw/cancellation. `@Transactional` pode ser alias público se adotado; documentar uma sintaxe canônica.

## Semântica mínima
- Função retorna normalmente -> tentar COMMIT; throw propagado -> ROLLBACK; COMMIT pode falhar ou ficar **desconhecido** quando conexão cai.
- `.required` participa da transação atual no mesmo store; `.requiresNew` e `.nested` só quando implementados e com semântica documentada; nested via SAVEPOINT onde suportado.
- Um erro capturado e ignorado não dispara rollback automaticamente; oferecer `markRollbackOnly`, e abortar quando a transação física ficou inválida.
- Conexão permanece ligada à unidade transacional e não pode ser utilizada livremente por tasks paralelas. TaskLocal carrega contexto, mas **não** substitui exclusividade/serialização do acesso à conexão.
- Evitar chamada de rede externa dentro de transação local; nenhum rollback do banco desfaz gRPC, mensagem enviada ou pagamento externo.
- Timeout/cancelamento: tentar abortar, liberar lease/pool; não assumir rollback consumado até saber resultado do banco.
- Transações read-only não são garantia de rejeição de escrita em todos os bancos.

## Retry
- Retries somente para erros e operações explicitamente seguros: deadlock/serialization failure conforme driver. Reexecutar a **unidade inteira**, não só último UPDATE.
- Não reexecutar operação financeira em estado de commit desconhecido antes de reconciliar por identidade idempotente.
- Retry não deve repetir efeitos externos irreversíveis dentro do callback transacional.

## Certificação de adaptadores
Capacidades não são apenas `Bool`: semântica de isolamento, engine, versão, configuração de durabilidade, DDL, constraints, lock timeout e storage topology fazem parte do perfil certificado. Se requisito não for atendido: fail-closed para operações críticas.

## Gates
Commit/rollback sob falhas; transação compartilhada entre repositories; propagation; concorrência; cancelamento; commit unknown; limpeza; driver real; testes de banco sob falha injetada.
