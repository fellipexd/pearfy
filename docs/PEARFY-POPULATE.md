# PearfyPopulate v1.6 — implementação e limites

`PearfyPopulateCore` e `PearfyPopulatePostgres` são bibliotecas separadas; projetos só as recebem após selecionar o módulo `populate` (`pearfy add populate`). A CLI do framework oferece o fluxo PostgreSQL. A implementação usa o `SQLDatabase` real do Pearfy e não requer uma dependência de driver diferente.

## Preparação e comandos

Em um projeto com `.pearfy/modules.json`:

```bash
pearfy modules plan --add populate
pearfy add populate
pearfy ai sync
```

O arquivo `.pearfy/schema.json` contém a representação JSON de `SchemaIR` validada pela aplicação. Os artefatos versionados de migration ficam em `Migrations/` ou `.pearfy/migrations/`, no formato carregado por `SQLMigrationCatalog`. `plan`, `run`, `verify` e `schema check` falham fechados se a comparação com manifesto/migrations indicar drift; sem manifesto de modelo a CLI não certifica nem executa um plano.

Configure a conexão por `PEARFY_POPULATE_PGHOST`, `PEARFY_POPULATE_PGPORT`, `PEARFY_POPULATE_PGUSER`, `PEARFY_POPULATE_PGPASSWORD` e `PEARFY_POPULATE_DATABASE`, ou pelas variáveis PostgreSQL usuais equivalentes. Credenciais não são mostradas no plano/relatório.

```bash
pearfy populate inspect --environment local
pearfy populate schema check --environment local
pearfy populate profile --table public.notes --sample-local --environment local
pearfy populate plan --table public.notes --rows 100 --seed 42 --environment local
pearfy populate plan --recipe .pearfy/populate/recipe.yaml --environment local
pearfy populate plan --table public.notes --target-size 2GB --size-mode total --environment local --max-rows 10000000
pearfy populate preview --plan .pearfy/populate/plans/PLAN.json
pearfy populate approve --plan .pearfy/populate/plans/PLAN.json --environment local
pearfy populate run --plan .pearfy/populate/plans/PLAN.json --approve-plan-hash HASH --environment local
pearfy populate status --run populate-HASH
pearfy populate verify --run populate-HASH --environment local
pearfy populate report --run populate-HASH
```

`GB` representa bytes decimais e `GiB` bytes binários. `target-size` é tamanho final absoluto; o CLI mede `pg_total_relation_size`, `pg_table_size` ou `pg_relation_size` segundo `--size-mode`. A estimativa inicial é limitada por `--max-rows`; o executor reavalia bytes a cada batch, reduz o próximo lote conforme a aproximação de bytes/linha e relata se atingiu o alvo. O alvo físico pode não ser alcançado dentro dos limites.

O primeiro uso no CLI não escreve no banco: `plan` grava somente um artefato local e retorna hash; `run` exige `--approve-plan-hash` idêntico ao plano e `--environment` idêntico ao destino. MCP pode ser habilitado explicitamente com `pearfy ai mcp enable populate`, mas não expõe ferramenta de escrita no banco nem aceita tokens de aprovação. `approve` exige confirmação interativa da frase com o hash e gera um token de 7 dias vinculado ao plano/banco/ambiente para uso local; só o hash do token fica em `.pearfy/populate/approvals/` com permissão local restrita. O usuário deve executar esse comando diretamente em um terminal local privado, nunca por um agente ou relay; não copie tokens para argumentos MCP ou contexto de modelo. Cada lote é uma transação; falha preserva checkpoints de lotes já confirmados. O checkpoint local fica em `.pearfy/populate/runs/`; os IDs e valores gerados são determinísticos, e `ON CONFLICT` na chave primária permite reproduzir um batch se o processo cair entre commit e checkpoint.

Staging requer `PEARFY_POPULATE_ALLOW_STAGING=1`; conexões TLS são exigidas nessa modalidade. `local` aceita loopback/socket local; rede local isolada pode ser habilitada explicitamente por `PEARFY_POPULATE_ALLOW_REMOTE_LOCAL=1`. Alvos cujo host/database contenham marcadores production-like são recusados em ambos os modos.

## Proteções e capacidades atuais

- Introspecção do catálogo PostgreSQL: tabelas/colunas, tipos, enums, defaults, identities/generated, PK, índices UNIQUE simples/parciais/expressões, FK composta/deferrable, CHECK, triggers, RLS e partições. O fingerprint é calculado da estrutura mais identidade do banco.
- `SchemaIR` compara tabela/coluna/tipo/nullability; o catálogo de migrations verifica ID e checksum aplicada. Populate nunca executa DDL ou migration.
- Topological planner enumera dependências FK e rejeita ciclos. O executor atual trabalha em uma tabela por plano e só referencia pais existentes, lendo chaves dentro do processo; não envia registros/IDs ao MCP. FK obrigatório sem pai elegível falha.
- Geradores determinísticos para UUIDv7, text/varchar, enum, inteiros, decimal, boolean, date e timestamp. UNIQUE simples usa namespace/run ordinal; bases inteiras são consultadas durante planning. CHECK simples de limites inteiros é suportado e permanece habilitado no banco.
- Profile calcula somente contagem, nulos, cardinalidade e tamanho textual médio dentro de transação `READ ONLY`; nunca inclui amostras/categorias em respostas.
- MCP vem sem ferramentas Pearfy por padrão. Após `pearfy ai mcp enable populate`, o servidor anuncia somente `inspect/profile/plan/preview/status/verify/report` para esse módulo instalado. `plan` pode gravar um artefato local, mas não há ferramenta de escrita no banco; execute `run` diretamente pela CLI. `cancel` e `cleanup` não estão expostos.
- Guardian inclui build/testes da suíte; estes testes validam geradores, hash, drift, ciclos, aprovação, parcial/resume e reconciliação de schema. Existe um teste de introspecção PostgreSQL ativado quando `PEARFY_TEST_POSTGRES_HOST` está configurado.

O adaptador de escrita exige uma chave primária escalar UUID ou inteira sem identity/default, sem triggers, RLS ou particionamento. Rejeita UNIQUE parcial/expressão, overlap entre UNIQUE e FK, tipos/checks não suportados e relações circulares. Índices/constraints do banco permanecem ativos. A primeira versão usa INSERT parametrizado por linha dentro de transações de batch; não usa PostgreSQL COPY.

Não estão implementados: geração automática de tabelas-pai, múltiplos targets no mesmo plano, FKs diferíveis/backfill cíclico, amostragem de perfil de pequeno grupo, `cleanup`, cancelamento remoto, gerenciamento durável de leases/registry dentro do banco, ANALYZE automático, verificação exaustiva pós-carga, integração real PearfyMetric e benchmarks de 100k/2GB. Os resultados reportados são métricas observadas do banco; não há benchmark volumétrico executado nesta etapa.
