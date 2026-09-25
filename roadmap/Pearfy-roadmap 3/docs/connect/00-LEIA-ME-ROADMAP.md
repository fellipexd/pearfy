# Pearfy Connect — roadmap de produto e implementação v1.3

> Documento de **planejamento incremental**, não comprovação de implementação. Este adendo complementa o roadmap consolidado v1.2, preservado no ZIP. O repositório atual do usuário — não a fotografia de `Sources/` incluída neste pacote — determina o estado real do projeto. Exemplos de macros, CLI e SDKs são **APIs-alvo ilustrativas**.

## Visão

Uma API Pearfy em Swift declara endpoints e eventos uma única vez. O **Pearfy Contract Compiler** produz uma representação intermediária versionada; o **Pearfy Connect** gera SDKs nativos para iOS (Swift), Android (Kotlin) e TypeScript (browser/Node), além de collection Postman e cURL por grupo. Os transportes cobertos são REST, WebSocket e gRPC, com adaptação às capacidades de cada plataforma. **PearfyFlow** poderá consumir esses SDKs futuramente, mas não é pré-requisito para geração de clientes.

## Decisões confirmadas

1. `@RouteGroup` define um grupo lógico com nome estável, prefixo REST/WS e alvos do SDK; controllers e canais declaram associação tipada a ele.
2. Exemplos: `/bko` -> TypeScript; `/app` -> iOS e Android; `/public` -> os três; `/internal` -> nenhum SDK externo.
3. A unidade de exportação é **grupo + alvo + operação**. Grupo não é uma barreira de segurança: todas as autorizações são verificadas no servidor.
4. O mesmo contrato gera SDKs, OpenAPI, AsyncAPI (quando aplicável), Protobuf descriptors, collections Postman HTTP e cURLs individuais.
5. TLS obrigatório em produção para todos os transportes. Proteção extra de payload é opt-in/política por grupo ou endpoint, bidirecional quando suportado; sem criptografia caseira nem segredo permanente embutido em cliente.
6. O artefato `.pearfy` é pacote versionado de contratos e metadados públicos; não armazena segredos nem implanta código executável.
7. `pearfy sdk generate --all` é ponto de entrada; comandos granulares `contracts build`, `export postman`, `export curl`, `contracts check` e `sdk check`.
8. Guardian verifica contratos, compatibilidade com aplicativos publicados, políticas de exposição, geração determinística, segurança e nenhuma divergência entre código e artefatos.
9. A arquitetura **Opção A** segue intocada: réplicas da MESMA API acessam diretamente banco transacional compartilhado; Pearfy Connect não cria coordenador gRPC nem serviço financeiro separado.
10. A geração de cliente **não** garante a existência de runtime servidor; registrar handlers, policy enforcement, DI e transporte precisam de gates verificáveis.

## Comece por aqui

| Documento | Escopo |
|---|---|
| `01-ARQUITETURA-E-CONTRATOS.md` | Compiler, IR e pacote `.pearfy` |
| `02-ROUTE-GROUPS-E-POLITICAS.md` | Anotações Swift, prefixos e regras de exportação |
| `03-SDK-IOS-ANDROID-TYPESCRIPT.md` | APIs geradas, autenticação e distribuição |
| `04-REST-WEBSOCKET-GRPC.md` | Semântica por transporte e streams |
| `05-SECURE-PAYLOAD-E-CHAVES.md` | TLS, HPKE, resposta, replay, rotação e limites |
| `06-POSTMAN-CURL-E-EXEMPLOS.md` | Collection por grupo, cURL por rota, ambientes |
| `07-CLI-UX-E-ESTRUTURA.md` | Comandos, flags, layout, versionamento |
| `08-GUARDIAN-E-COMPATIBILIDADE.md` | Análise obrigatória de alterações e gates |
| `09-IMPLEMENTACAO-E-BACKLOG.md` | Marco P0/P1/P2 e dependências |
| `10-TESTES-E-CRITERIOS-DE-ACEITE.md` | Matriz e2e, cobertura e segurança |
| `11-ADRS-E-ANTI-PADROES.md` | Trade-offs resolvidos |
| `examples/01-SWIFT-BACKEND-E-GRUPOS.md` | Sintaxe Swift projetada |
| `examples/02-IOS-ANDROID-TYPESCRIPT.md` | Métodos gerados na prática |
| `examples/03-MANIFEST-POSTMAN-CURL.md` | Artefatos ilustrativos |
| `integration/PROMPT-PARA-AGENTE.md` | Integração incremental na branch existente |

## Regra de precedência

1. Implementações e testes vigentes: fonte factual.
2. ADRs e requisitos deste adendo: decisão de **Pearfy Connect** e aspectos de segurança que refinam discussões anteriores.
3. Roadmap consolidado v1.2: decisões da infraestrutura de backend, dados, concorrência e pagamentos.
4. Roadmap histórico e exemplos antigos: referência, nunca motivo para regredir código pronto.

## Não escopo inicial

- Fluxo visual nativo gerado a partir de telas ou compilação remota de código iOS/Android.
- Criptografia proprietária, E2EE entre usuários ou promessa de ocultar dados de um dispositivo comprometido.
- Transação distribuída via gRPC, RPC por instrução SQL ou instância primária obrigatória.
- Suporte universal a todo browser/transporte sem adaptação.
