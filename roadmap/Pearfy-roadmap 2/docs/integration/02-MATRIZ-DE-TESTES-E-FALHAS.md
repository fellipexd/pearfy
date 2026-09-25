# Matriz de conformidade — bancos, concorrência, pagamentos e agentes

## Ambiente de teste
Rodar database adapters em instâncias REAIS, com configurações explicitadas (versão, engine/isolamento/durabilidade, pool e topologia). Para multi-instância, processos separados (não somente tasks dentro de um processo). SQLite in-memory não prova concorrência do PostgreSQL/MySQL/SQL Server.

## Suite DB agnostic
| Cenário | Invariante |
|---|---|
| mesmo schema gerado 2x | diff vazio/idempotente |
| create/add nullable/rename explícito | não perde dados |
| DROP não autorizado | não aplica |
| 2 migrators concorrentes | única aplicação por migration/checksum |
| `@Transaction` com duas escritas | ou ambas persistem ou nenhuma |
| 1 repositório falha | todos writes da unidade rollback |
| falha durante commit | status UNKNOWN quando não se sabe, depois reconciliação |
| lock timeout, deadlock | transação limpa e retry classificado |
| 10 processos, mesmo registro | sem lost update/double debit |
| 1000 chaves iguais simultâneas | uma operação efetiva, demais resultado/rejeição coerentes |
| 1000 operações com chaves distintas | integridade financeira e progresso justo |
| conexões esgotadas | backpressure/erro tipado, sem crescimento ilimitado |
| kill -9 antes/durante/depois do commit | nenhuma confirmação falsa/duplicação |
| atualização em rolling deploy | schemas N/N+1 convivem conforme plano |

## Suite financeira
- 2 débitos de 80 e 50 contra saldo 100 -> somente um se primeiro debita 80; saldo não negativo e ledger equilibrado.
- A -> B e B -> A em paralelo -> sem deadlock sistemático; se ocorrer deadlock, retry seguro sem duplicação.
- Ledger impossivelmente desequilibrado -> operação não confirma.
- Disponível, reservado, pendente e contabilizado coerentes após reserva, liquidação e estorno.
- Repetição de mesma chave/payload -> mesmo resultado; chave/payload diferente -> conflito.
- Timeout no provedor externo e webhook duplicado/fuera de ordem -> UNKNOWN + reconciliação, sem reenvio cego.
- Alteração não autorizada entre tenants ou contas -> rejeição sem mutação.
- Queda de worker e expiração lease -> worker antigo não grava resultado com geração vencida.

## Benchmarks
Comparar ORM vs SQL direto no mesmo driver; lock pessimista vs conditional/optimistic quando ambos forem certificados; 1/3/10 instâncias, carga sustentada e saturação. Registrar throughput, p50/p95/p99, RSS, CPU, queries/operação, pool wait, lock wait/deadlocks, retries, allocs/request, rows e backlog. Orçamento definido após baseline real, sem inventar SLA.

## Evidência de gate
Salvar SHA da revisão, versão da toolchain, banco e configuração, lista de suites executadas, warnings, bloqueantes, artefatos de benchmark e quem aprovou ações destrutivas. Falha de setup/timeout do teste = INCOMPLETE, não PASS.
