# Guardian, MCP e compatibilidade do Pearfy Connect

## Invariantes que a IA não pode contornar

- A criação/modificação de controller, DTO, evento, RPC ou policy exige regenerar e comparar contratos relevantes; gate CI verifica que o SDK do mesmo `contractHash` é reprodutível.
- SDK target só é exportado se pertence à política `@RouteGroup`; `@SDKOnly` apenas restringe, sem ampliar exposição; `@SDKIgnore` **não** configura autorização.
- Falha de metadata de auth/criptografia = contrato inválido, nunca reduzir silenciosamente requisito de segurança.
- Alteração de path, method, operation ID, nome/campo de DTO, tipo, nullability, status code, evento WS ou field number Protobuf gera análise de breaking changes por população de clientes suportada.
- Não pressupor que todos os usuários instalaram a versão mais nova do app; golden contracts das versões publicadas fazem parte da suíte.
- Nenhum generated artifact deve conter token, senha, private key, connection string, PII real ou script que ignora proteções exigidas.
- Modos de criptografia bloqueiam downgrade para plaintext. Browser gRPC usa adapter compatível; streaming não suportado deve ser erro documentado.
- Retry financeiro não pode alterar chave de idempotência nem assumir que timeout significa rollback.
- Cobertura por operação HTTP: OpenAPI, SDKs autorizados, Postman por grupo, cURL individual; WS/gRPC por formato correspondente.
- Recursos já implementados não são substituídos por mocks apenas para passar no checklist.

## CI pipeline mínimo

1. Inventário do código/registry atual, estado das macros/CLI/SDKs; não alegar coisas que só constam dos docs.
2. Compilar e validar IR; static security policy check.
3. Build `.pearfy` determinístico; diff versus contratos publicados (versionamento/compat).
4. Gerar todos os targets/grupos permitidos; SDKs devem compilar nos toolchains suportados.
5. Conformance client↔server: exemplos válidos, erros tipados, TLS, tokens, auth e paths.
6. E2E multi-instância em rotas protegidas + KMS/replay conforme implementação de crypto.
7. Secret scanning, schema lint, public API diff, tests e benchmarks quando aplicável.
8. Relatório com revision+hash, tool versions, passes/fails/skips, evidência. Falha/indisponibilidade de gate obrigatório = FAIL/INCOMPLETE, nunca APPROVED.

## MCP do Guardian (auxiliar, enforcement fora do modelo)

Operações-alvo: `connect.describeGroups`, `connect.inspectOperation`, `connect.diffContract`, `connect.checkSecurity`, `connect.planSDKRegeneration`, `connect.verifyGeneratedArtifacts`. Os nomes são propostas; MCP não obriga agente externo a invocar ferramenta, e a aprovação efetiva deve ocorrer via compiler/CLI/test/CI/branch protection.

## Testes específicos de segurança de API

App mobile tentando chamar rota administrativa diretamente; usuário não autorizado reutilizando URL, path alterado em envelope protegido, corpo plaintext em rota sealed, token expirado durante WS, RPC sem permissão, nome de grupo falsificado, query maliciosa, replay em duas réplicas. **A ausência de método em SDK não é um controle de autorização.**
