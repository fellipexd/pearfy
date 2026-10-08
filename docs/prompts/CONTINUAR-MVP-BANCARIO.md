# Prompt para continuar o MVP bancário

Copie o bloco abaixo para a conversa ou agente que terá acesso ao repositório
do MVP:

```text
Continue meu MVP bancário existente usando o Pearfy Framework. Primeiro
inspecione o repositório real da aplicação, seus produtos Pearfy instalados,
rotas, modelos, migrations, testes e estado do Git. Não presuma que o MVP está
neste repositório do framework; se não encontrar a aplicação no workspace,
peça o caminho antes de editar.

A base do Pearfy está pronta para continuar o desenvolvimento da aplicação
usando os contratos implementados PearfyLedger e PearfyLedgerPostgres, junto
com PearfyTransactions, PearfyData, PearfyPostgres e PearfySecurity. Use
LedgerMoney com unidades menores inteiras, moeda e escala explícitas; faça a
operação de domínio, o resultado idempotente e lançamentos equilibrados na
mesma transação física. Para qualquer leitura/escrita concorrente, informe
todos os resourceKeys antes de consultar estado. Autentique separadamente da
autorização por recurso, carregue o recurso dentro do escopo de tenant/posse e
revalide a autorização na transação quando ela puder mudar concorrentemente.
Depois de TransactionCommitOutcomeUnknown, reconcilie com a mesma chave antes
de tentar novamente.

Regras de conta, cliente, transferência, limites e produto pertencem ao MVP,
não ao Pearfy. O módulo `payments` continua planejado; não invente suas APIs
nem use roadmaps como código implementado. Não use Double/Float para dinheiro,
não execute efeitos externos dentro de callbacks retriáveis e não trate role
global como autorização de acesso a recurso. Se publicação confiável for
necessária, proponha um outbox da aplicação na mesma transação e consumidores
idempotentes.

Valide contratos nas Skills `pearfy-banking-mvp`, `pearfy-ledger`,
`pearfy-security`, `pearfy-transactions`, `pearfy-data` e `pearfy-postgres`,
lendo somente as necessárias. Preserve o escopo do MVP; não altere exemplos ou
projetos independentes de teste sem necessidade. Faça uma mudança vertical
pequena, adicione testes unitários e integração com PostgreSQL real para as
garantias financeiras tocadas e execute as verificações aplicáveis.

Estado conhecido do framework: os contratos e o adapter de ledger foram
implementados, então é possível continuar a integração no MVP. Porém os testes
de integração PostgreSQL ainda não foram executados nesta máquina porque
PEARFY_TEST_POSTGRES_HOST não estava configurado; round-trip NUMERIC, DDL,
concorrência multi-cliente e falha real de commit desconhecido ainda precisam
ser validados contra PostgreSQL. A última suíte geral também mostrou uma falha
intermitente existente no teste de scheduler Redis. Não declare essas gates
como aprovadas nem chame o sistema de produção financeira ou regulatoriamente
certificado. Reexecute-as no ambiente adequado e reporte PASS/INCOMPLETE com
os comandos e resultados reais.

Não faça commit, push, deploy ou operações externas até revisar o diff e
confirmar explicitamente quais diretórios do MVP devem entrar na publicação.
Ao terminar, informe arquivos alterados, invariantes cobertas, testes realmente
executados e bloqueios restantes.
```
