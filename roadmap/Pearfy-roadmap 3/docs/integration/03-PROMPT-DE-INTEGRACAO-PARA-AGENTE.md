# Prompt de integração incremental para agente de implementação

> Cole este texto para um agente que tenha acesso real ao repositório Pearfy já em evolução. É um plano, não autorização para operações destrutivas.

Você está implementando Pearfy. Leia `AGENTS.md`, `docs/09-ROADMAP-ATUALIZADO.md` e os arquivos de decisões, data, distributed, payments, ai e integration deste pacote. Antes de editar, inventarie o estado atual do repositório: branches/arquivos/código de DI/macros/schema/web/DB/Guardian, versões Swift e testes. Não pressuponha que o protótipo incluído no ZIP é o repositório mais atual. Mapeie conflitos com documentação anterior. Preserve APIs funcionais e implemente incrementalmente.

Requisitos obrigatórios:
1. `PearfyTransactionalStore` substitui qualquer naming financeiro para abstração genérica; `PearfyPayments` contém domínio financeiro.
2. Réplicas da mesma API acessam banco transacional compartilhado diretamente; não instalar líder/coordenador gRPC para serializar cada transação. gRPC apenas para serviços distintos quando fizer sentido.
3. Drivers são adapters certificados; não prometer mesma semântica de todos os bancos; fail closed se garantias necessárias não forem demonstradas.
4. Entidades Swift definem schema desejado; UUIDv7 default no `@ID` UUID, sobrescrita por estratégia tipada; diff e migrations SQL versionadas/auditáveis.
5. `@Transaction` delimita tx física única para todos os repositories participantes e oferece commit/rollback/cancellation/commit unknown sem mentir sobre sucesso.
6. PaymentEngine oferece intenção tipada, autorização, idempotência compartilhada, locking por banco, conditional write, ledger equilibrado e outbox na mesma tx.
7. Semáforo/filas/Redis não são proteção única do dinheiro; transações/constraints e idempotência durável pertencem ao store.
8. MCP fornece contexto e análises para IA, mas CLI/CI devem impor gates mesmo quando o agente ignora MCP.
9. Padrão de arquitetura `clean` organizada por funcionalidade; presets alternativos suportados sem impor clean a todos.
10. Sem referências a Spring Boot ou outros produtos em código específico; comparação só em arquivos `.md`.

Para cada mudança: planeje contratos/invariantes/testes; pesquise implementação existente; faça um vertical slice mínimo; execute lint/build/testes de banco real quando pertinentes; reporte provas, falhas, benchmark e pendências. NÃO marque contratos-alvo como implementados sem código compilável e testes. Não invente funcionamento/resultado de ferramentas. Solicite revisão humana para migrations destrutivas ou alterações financeiras com efeitos externos irreversíveis.
