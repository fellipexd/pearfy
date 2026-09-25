# Guardian v1.5 — enforcement por módulo e integração

MCP/skills orientam; compilador, testes, lint, contract checks, DB checks e CI decidem. Agente não pode se autopromover PASS. Não permitir atalho que desabilite gate para concluir entrega.

## Social

Privacidade por leitura e cache, block/mute em busca/feed, moderação com contentRevision, dedup reaction/comment notification, URL diretа não fura ACL, actor ownership, projeções convergentes.

## Identity

`issuer+sub` único, no auto-merge email, OAuth state/nonce/PKCE, session local, unlink last login guard, callbacks allowlist, secrets fora sdk, concorrência first login.

## DevKit

Installed API ≠ roadmap, registry e skill versionados, ferramentas scope, no shell genérico, tests reais. Queda de MCP = status INCOMPLETE para gates dependentes.

## Evolução de schema e contracts

Contracts versionados, migrations com checksum/drift, constraints, reconciliação de dados de teste, compatibility checks, observabilidade e ownership claro dos recursos.

## Gates mínimos

- Build Swift release e Linux CI, Swift strict concurrency onde viável; regressão de memória e bounded tasks.
- Unit, integration e fault injection multi-instance em banco real certificado.
- Paridade HTTP: method/path, params, headers, auth, status/error, JSON shapes e ordenação/paginação.
- Dados: migrations checksums, constraints, count reconciliation, no loss, id preserved.
- Connect: diff grupos e SDK TS/mobile, coleção Postman por grupo e curl individuais.
- Cloud AI export strict; jamais copiar dados de produção para prompt/cloud nem reusar OAuth secrets.
