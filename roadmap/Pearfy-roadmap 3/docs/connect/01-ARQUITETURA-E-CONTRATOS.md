# Pearfy Connect — arquitetura e compiler de contratos

## Pipeline

```text
Swift source + macros + route registry + semantic validation
  -> Pearfy Contract IR (intermediário tipado, determinístico)
  -> validação de grupos / auth / segurança / referências / compatibilidade
  -> artefatos abertos: OpenAPI, AsyncAPI, .proto / FileDescriptorSet
  -> .pearfy (pacote versionado)
  -> SDKs Swift, Kotlin, TypeScript + Postman + cURL
  -> contract tests + SDK tests + Guardian gates
```

**A macro Swift isolada não descobre todos os símbolos de um módulo automaticamente.** Compor macros locais com build plugin/source generation e registro verificável no build. O registro usado pelo servidor deve ser o mesmo usado pelo gerador; detectar divergência em CI. Metadados e schemas devem refletir o contrato **efetivo**, não apenas a árvore sintática: route collision, overload, auth, param binding, genéricos, optional, enum, status codes, erro e versionamento.

## IR mínimo

- `contractVersion`, `compilerVersion`, `buildRevision`, `schemaHash`.
- `groups[]`: nome estável, prefixos/identidades por transporte, SDK targets, políticas de exposição, auth, proteção de payload, compatibilidade.
- `operations[]`: id estável independente de pathname, group id, transport, verb/route OU service/method OU channel/event, request/response/errors, tipos, policies, scopes, deprecation, source reference.
- `types[]`: propriedades, nullability, IDs, decimal/money, enum, arrays, mapas, payload binário, datas e formatos com codecs definidos.
- `securitySchemes[]`, `examples[]`, `capabilities[]`, `dependencies[]`.

Operation IDs explícitos opcionais e autogerados estáveis apenas quando ausência não causar ambiguidade; colisões e renomeações precisam aparecer no diff. **Não** serializar reflection de runtime como contrato de compilação se ela não preservar informação suficiente.

## Formatos de saída

- REST: OpenAPI com headers, query/path/body, status codes, schemas, auth, exemplos e tags/grupos.
- Eventos WS: AsyncAPI, descrição de handshake, subprotocol, mensagem, cursor, ack, erros e limites; extensões versionadas Pearfy quando o formato não cobrir semântica específica.
- gRPC: fonte `.proto`/descriptor produzido com estratégia **estável de numeração**; não derivar field numbers arbitrariamente da ordem de propriedades Swift. Reaproveitar fonte `.proto` se ela for authoritative para serviço existente; guardar números, reserved fields/names, compatibilidade de wire.
- `.pearfy`: container versionado (implementação sugerida: ZIP determinístico com `manifest.json` + especificações/descritores). **Não** criar protocolo criptográfico próprio. Assinatura opcional de artefato distribuído, checksums e política de origem confiável.

## Bundle e segurança

O `.pearfy` inclui apenas contratos publicados para o alvo/grupo. Sem env secrets, token, chaves privadas, connection strings, stack traces, migrations, detalhes internos do ORM ou endpoints não exportáveis. Chaves públicas de criptografia podem ser distribuídas via **mecanismo autenticado de discovery**, com `kid` e expiração; não colocar chave privada no bundle. Classificação e política de redaction para exemplos.

## Reprodutibilidade

Mesma revisão de código + configurações + toolchain/versões fixadas = mesmo hash de contrato, nomes gerados e pacote. Arquivos ordenados e timestamp normalizado em artefatos determinísticos; formatos cujo gerador inclui timestamp por padrão devem ser configurados para removê-lo. Gerar duas vezes no CI e comparar bytes quando aplicável.

## Propriedade de erros

Erros de compile/generation claros: duplicação de rota, grupo inexistente, conflito de codec, tipo não representável, campo Protobuf incompatível, alvo não suportado, política de auth sem client flow correspondente, exemplo inválido. Nunca produzir SDK silenciosamente parcial com exit 0.
