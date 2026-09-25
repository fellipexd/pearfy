# PearfyConcurrency — locking e conflitos sem acoplar o domínio ao SQL

## Responsabilidades
`PaymentEngine`/caso de uso determina **quais recursos** precisam de proteção. `TransactionManager` detém unidade/lease. `PearfyConcurrency` aplica ordem, estratégia e política de retry. O adapter executa lock/conditional write concreto. O banco compartilhado arbitra concorrência entre todas as réplicas.

## Contrato tipado-alvo
```swift
let locked = try await tx.accounts.lock(
    ids: [input.sourceAccount, input.destinationAccount],
    mode: .exclusive
)
```
As contas devem ser bloqueadas em ordem canônica comparável em todos os drivers e code paths. No adapter SQL inicial, adquirir um ID por vez de forma ordenada é uma opção; não assumir que `ORDER BY` com `FOR UPDATE` sempre garante a ordem física em todas as situações.

## Estratégias por banco
| Família | Recurso possível | Cuidado |
|---|---|---|
| PostgreSQL | `SELECT ... FOR UPDATE`, UPDATE condicional, versão | deadlocks, `40001`, `40P01`, timeouts; mesmo tx/connection |
| MySQL/InnoDB | locking read, UPDATE condicional | engine, índice, isolation/gap locks |
| SQL Server | UPDLOCK/HOLDLOCK conforme caso | escopo e isolamento, escalonamento de locks |
| CockroachDB | tx serializável + retry de conflito | repetição segura da transação inteira |
| MongoDB | transações e escrita condicional/versionada | topology, retries e limites de transações multidocumento |

A tabela é escopo de implementação/certificação, **não declaração de suporte já aprovado**. Sem emulação silenciosa de garantias indisponíveis.

## Proteção combinada
- Lock pessimista ou estratégia transacional certificada.
- Check condicional na escrita (`balance >= amount`) e verificação do número de linhas afetadas.
- Constraints duráveis no banco, identidade idempotente única, ledger consistente.
- Lock do banco dura até commit/rollback. Em crash/queda de conexão, considerar resultado de commit desconhecido quando aplicável.
- Mutex/semaforo em memória só limitam carga; fila ajuda a reduzir contenção; Redis lease não é a fonte de verdade para saldos.
- Fencing tokens protegem workers antigos em storage que verifica o token, mas não desfazem efeitos externos já enviados.

## Observabilidade
Métricas de `lock_wait_duration`, `lock_timeout_total`, `deadlock_total`, `serialization_retry_total`, `transaction_duration`, `pool_wait_duration`; labels limitadas (nunca accountId/userId/requestId como labels de alta cardinalidade).

## Aceite
Duas transferências cruzadas não causam deadlock sistemático; débitos concorrentes não deixam saldo negativo; 10 processos diferentes observam os mesmos invariantes; retries e expiração liberam recursos. Benchmarks com e sem fila/limite de concorrência medem throughput e p99 sem sacrificar correção.
