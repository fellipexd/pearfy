# ADRs e anti-padrões do Pearfy Connect

## ADR-C01 — contrato primeiro

Swift typed route registry + Contract IR como fonte única de SDK, coleção, cURL e docs. Não manter descrições duplicadas dos mesmos endpoints em 3 geradores. OpenAPI/AsyncAPI/Protobuf são formatos de interoperabilidade, não equivalentes semânticos automáticos.

## ADR-C02 — público alvo via grupo

`@RouteGroup` com `sdk: []` para interno, `backoffice` TypeScript, `mobile` Swift/Kotlin, `public` os três. Override não amplia alvos sem alteração explícita de policy. SDK visibility ≠ server authorization.

## ADR-C03 — arquivo `.pearfy`

Bundle binário é empacotamento de manifest/specs/descritores públicos com formato versionado, hash e policy; não código executável nem chave privada. Não forçar app publicado a baixar contratos novos para modificar funcionalidades nativas em runtime.

## ADR-C04 — REST MVP primeiro

Provar exportação + SDK compilável + collection + cURL para REST antes de streams. WS/gRPC são camadas adicionais; gRPC browser exige adaptador e capability check.

## ADR-C05 — proteção por camadas

TLS obrigatório; sealed payload apenas para threat model justificável, algoritmo padronizado/interoperável, keys KMS, AAD, replay e rotacionamento. Não chamar esse desenho de criptografia ponta a ponta entre pessoas, nem inserir chave secreta nos clientes.

## ADR-C06 — experiências nativas

Swift Package, Kotlin Gradle/AAR e TypeScript npm. Não reduzir todos à API de lowest common denominator. `async`/`suspend`/`Promise`, streams respectivos, cancellation e errors idiomáticos.

## ADR-C07 — legado em produção

Contrato publicado é baseline de compatibilidade; a compatibilidade não é conferida somente com o client gerado mais recente. App mobile pode permanecer desatualizado.

## ADR-C08 — multi-instância inalterada

Todas as réplicas da mesma API acessam banco compartilhado diretamente conforme docs/data/distributed; cliente gerado e sealed payload não criam "main instance" ou transação distribuída por RPC. PaymentEngine e idempotência mantêm suas garantias server-side.

## Anti-padrões

- Copiar as rotas manualmente dentro dos SDKs ou exportar endpoint interno por conveniência.
- Mapear `/bko` e `/app` apenas por regex/pasta sem group metadata.
- Considerar ausência no SDK como proteção contra acesso remoto.
- Fazer `POST` financeiro com retry automático gerando novo idempotencyKey.
- Reusar um nonce fixo; colocar chave AES privada em app; inventar cifrador proprietário.
- Presumir que TLS em proxy torna todo payload opaco ao proxy.
- Declarar suporte a gRPC browser bidi streaming sem teste no browser alvo.
- Gerar cURL de corpo plano para rota sealed obrigatória.
- Usar collection Postman HTTP como representação integral e portável de qualquer WebSocket/gRPC.
- Gerar resposta `TransferResult.completed` quando commit status é desconhecido.
- Criar um segundo mecanismo de roteamento que não corresponde ao servidor real.
