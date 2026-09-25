# Prompt de integração incremental — Pearfy Connect v1.3

Você é um agente sênior de framework Swift responsável por integrar o **Pearfy Connect** ao repositório real do usuário. Leia `AGENTS.md`, `docs/09-ROADMAP-ATUALIZADO.md`, a documentação `docs/connect/00-LEIA-ME-ROADMAP.md` até `docs/connect/11-ADRS-E-ANTI-PADROES.md` e docs existentes de DI, security, transactions e Guardian conforme o escopo.

## Regras inegociáveis

1. Inventarie o código/CLI/testes atuais antes de editar; docs/ZIP contêm protótipo histórico, não a branch atual. NÃO substituir implementações prontas por exemplo/documentação/stub.
2. Planeje incrementalmente PCON-000...018, começando de grupos/registry e REST. Não prometer full-stack WS/gRPC/HPKE enquanto faltarem recursos concretos.
3. Implementar grupos tipados e target restrictions: `/bko` TypeScript, `/app` Swift iOS/Android, `/public` os 3, `/internal` nenhum. Rota sem grupo não exporta. SDK target NÃO é autorização de servidor.
4. Compiler IR único e determinístico gera specs, `.pearfy`, SDKs, Postman collection HTTP por grupo e cURL individual por endpoint; validar paridade com registry real.
5. Não inserir segredos em bundle/SDK, coleção, cURL, docs de exemplo ou logs. TLS obrigatório em prod; sealed payload só após implementar/testar protocolo auditável + gerenciamento compartilhado de chaves. Não simular criptografia com base64.
6. gRPC browser não é gRPC nativo irrestrito; WebSocket reconnect sem cursor não significa entrega garantida; não falsificar suporte em targets não certificados.
7. Preservar multi-instância opção A; nada de coordenador gRPC único para a mesma API nem altera semantics do PaymentEngine.
8. Guardian gates ficam em Swift/CLI/test/CI; MCP ajuda mas não prova enforcement. Falha ou teste não realizado é FAIL/INCOMPLETE, nunca PASS.
9. Swift 6 strict concurrency, DTOs tipados, tratamento de cancelamento, backpressure e idempotência financeira estável.
10. Referências a outros frameworks somente em `.md`; símbolos, código, config e arquivos gerados devem possuir nomenclatura Pearfy/neutra.

## Entregas por rodada

- Relatório: prontidão real por módulo e dependências existentes.
- Implementação da menor fatia vertical viável (preferir rota de exemplo com grupos reais).
- Testes: `swift build`, `swift test`, integração HTTP, compilação SDK Swift+Kotlin+TS, validações Postman/cURL conforme ferramentas disponíveis; listar comandos realmente executados.
- Artefatos: contract diff, coverage, hashing, security scan, log de falhas e limitações.
- Próximo incremento priorizado sem reescrever recursos já prontos.

## Fim da rodada

Reportar arquivos alterados, decisões técnicas, riscos, testes executados com resultado, gates incompletos e motivo. Nunca alegar release completo com base em esqueleto, documentação ou código ilustrativo.
