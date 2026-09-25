# gRPC opcional, sem líder para réplicas da mesma API

## Decisão
**Não** colocar RPC no caminho de cada `BEGIN`, `SELECT`, `LOCK`, `UPDATE` e `COMMIT`; **não** criar API primária que centraliza as gravações da mesma aplicação. Cada réplica fala diretamente com seu banco transacional compartilhado.

`PearfyGRPC` segue válido para microsserviços DISTINTOS, quando cada serviço detém uma responsabilidade e um armazenamento lógico.

```
API A / API B / API C --> Banco da API (direto)
API A -- gRPC/Protobuf --> Serviço de estoque replicado --> Banco do estoque
```

- Transportar **operação de negócio tipada e autocontida** em uma chamada; o serviço proprietário executa transação local integral.
- Não passar closure Swift, conexão SQL, objeto ORM vivo ou lock em várias RPCs.
- Deadlines/cancelamento/tracing e auth de serviço, contrato `.proto` versionado e clientes gerados.
- Não confundir timeout gRPC com rollback confirmado; tratar resultado desconhecido por consulta/idempotência.
- Sem fallback remoto->banco direto que contorne ownership.

## gRPC não substitui
Atomicidade, banco transacional, idempotência, ledger, filas duráveis nem orquestração de transferência interbancos.

## Benchmarks de decisão
Comparar acesso direto vs RPC de operação completa no mesmo rack/rede e sob carga: p50/p95/p99, throughput, CPU, RSS, conexões, fila, erro e custo operacional. Não inventar números de latência antes de executar benchmark; uma RPC extra só se justifica quando a separação de responsabilidades oferece benefício.
