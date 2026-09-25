# ADR-PFY-002 — Opção A: todas as instâncias acessam o banco diretamente

**Estado:** decisão definitiva para réplicas da MESMA API.

```
Load Balancer
  ├── Pearfy API A ── seu pool ──┐
  ├── Pearfy API B ── seu pool ──┼── Banco transacional lógico compartilhado
  └── Pearfy API C ── seu pool ──┘
```

Cada processo contém o mesmo `PaymentEngine` (caso instalado), `PearfyTransactionalStore` e adaptador certificado. Nenhuma “instância principal” ou coordenador gRPC intercepta acesso ao banco. A integridade não depende de sticky session, memória local, semáforo da API ou afinidade de carga.

## Invariantes multi-instância
1. Idempotência e operação original são identificadas no armazenamento durável compartilhado por escopo + tipo + chave + fingerprint dos parâmetros.
2. Locks/conflitos são resolvidos pelo banco transacional; concorrência e retries do cliente não criam saldos duplicados.
3. Todas as escritas correlatas, ledger, resultado idempotente e outbox local usam a mesma transação física.
4. Cada réplica pode ser encerrada entre begin/lock/write/commit sem permitir uma segunda execução indevida.
5. Réplicas de leitura atrasadas não validam saldo disponível, idempotência nem autorização dependente de estado mutável.
6. Migrations são executadas por um migrator coordenado e versionado, não automaticamente por cada réplica ao iniciar.
7. Soma de `max pool size` de todas as réplicas respeita capacidade e reserva operacional do banco; HPA precisa considerar esse orçamento.
8. Releases com versões N/N+1 seguem schema expand/contract e contratos compatíveis durante deploy rolling.

## Multi-banco NÃO significa atomicidade entre bancos
Duas dimensões distintas:
- **Portabilidade:** a mesma API roda sobre um banco suportado diferente por deployment, por adaptador certificado.
- **Transferência cruzada:** uma única operação cruza bancos independentes/shards: transação local NÃO cobre ambos. Exigir protocolo distribuído explícito com estados, reserva, outbox/inbox, compensação possível, reconciliação e ownership; nunca declarar commit atômico por mera chamada gRPC.

Se bancos/shards oferecerem verdadeira transação distribuída suportada, tratá-la como outro adapter/protocolo certificado com requisitos de operação/failover e trade-offs explícitos, não suposição universal.

## Drivers
PostgreSQL inicial para validar arquitetura; MySQL/InnoDB, SQL Server e CockroachDB no backlog; MongoDB separado como store documental de semântica própria, com exigências de deployment. Cada um precisa passar **exatamente a mesma suíte de propriedades financeiras** na configuração declarada. SQLite para testes rápidos não substitui a certificação transacional do banco de produção.

## Fail closed
Banco sem constraints/isolamento/commit durável exigidos pelo perfil financeiro -> módulo financeiro não inicia ou operação é rejeitada; um adapter “conectado” não equivale a adapter “certificado”.
