# ADRs iniciais

## ADR-001 — Swift 6.x e strict concurrency

**Decisão:** Swift 6.2+ no starter e Swift 6.x no framework. Revisitar baseline antes de 1.0. **Motivo:** builds reprodutíveis e regras claras para `Sendable`, isolamento, async/await.

## ADR-002 — Núcleo independente de HTTP

**Decisão:** Core/DI/Context não importam NIO, banco ou CLI. **Motivo:** testar e executar processos não HTTP e oferecer adapters alternativos.

## ADR-003 — Constructor injection como mecanismo real

**Decisão:** macros geram construção por parâmetros; `@Autowired` é açúcar sintático sobre injeção pré-publicação. **Motivo:** segurança de inicialização, testes e isolamento de contexto.

## ADR-004 — Manifesto gerado em build

**Decisão:** macros fornecem metadados locais; plugin gera registry estático entre arquivos/targets suportados. **Motivo:** não depender de reflexão global inexistente.

## ADR-005 — PostgreSQL antes de ORM genérico

**Decisão:** Postgres com SQL parametrizado, pool e transações; repositórios e ORM crescem sobre contratos estáveis. **Motivo:** menor risco de semântica incorreta de transações.

## ADR-006 — Starters opt-in

**Decisão:** a fachada é leve; starters adicionam dependências concretas sem inflar aplicações que não os utilizam.

## ADR-007 — Segurança de produção depende de auditoria

**Decisão:** não rotular autenticação/authorization como prontas para fintech apenas por passar testes unitários. **Motivo:** falhas silenciosas de acesso são críticas.

## ADR-008 — Status honesto da API

**Decisão:** exemplos de annotations não existentes ficam exclusivamente em Markdown e indicados como contrato futuro. Sources contêm apenas código executável do protótipo atual.
