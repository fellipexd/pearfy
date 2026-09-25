# Transportes de Pearfy Connect

## REST / HTTP

Contract IR deve mapear: method, path com parâmetros, query, cabeçalhos, body, status codes (incl. 204), erros, paginação, cursor, media types, file upload/download/stream e auth. OpenAPI é artefato de intercâmbio; não usar string de URL duplicada como fonte paralela. HTTP client executa TLS/verificação por padrão e observa timeouts, redirect policy e cancelamento.

## WebSocket

`@SocketChannel(path, group)` e `@SocketEvent(name)` descrevem: handshake, server/client/bidirectional messages, formatos, payloads, erros, regras de autorização, ack, cursor, ordem, heartbeat, limites e retenção. Eventos tipados mapeiam `AsyncSequence` Swift, `Flow` Kotlin, callback/`AsyncIterable` TypeScript. Distinguir:

- reconexão de rede ≠ entrega confiável;
- um socket conectado ≠ autorização permanente (expiração/revogação de sessão);
- `on(event)` ≠ garantia de exactly-once;
- replay/cursor e dedup só existem se o backend publicar esse contrato e persistir o estado necessário.

Aplicar backpressure e limites de buffer; erro de parser/cripto encerra ou rejeita conforme política explícita. No browser, handshake auth respeita limitações da WebSocket API de navegadores. Postman pode ter request WS de acordo com o produto/versão, mas não inventar compatibilidade com collection HTTP JSON v2.1.

## gRPC

`@GRPCService(group: MobileAPI.self)` classifica exportação; a identidade wire é `package.Service/Method` definida por `.proto`. Protobuf field numbers/reserved names não podem ser renumerados em regeneração. gRPC streaming mapeia APIs assíncronas idiomáticas, deadline, cancellation, retry policy, compression e limits por chamada. Reutilizar canais, respeitar TLS/mTLS aplicável.

- Swift iOS: cliente gRPC nativo se runtime/arquiteturas suportados.
- Kotlin Android: cliente adequado ao target e bibliotecas escolhidas com teste em device/emulador.
- TypeScript Node: gRPC nativo/transport compatível.
- TypeScript browser: gRPC-Web/Connect/gateway compatível, **não** prometer gRPC HTTP/2 nativo irrestrito. Validar streaming browser por transport/backend específicos; client-side/bidi streaming pode não existir.
- Quando transport não oferece feature exigida, marcar `unsupported capability` e falhar ao gerar/compilar esse SDK, não gerar stub que falha somente em produção.

## Identidades, grupos e políticas

- Prefixos `/app` e `/bko` compõem paths HTTP e WS.
- gRPC não herda path prefix; herda grupo para seleção SDK, docs e políticas de geração.
- Uma operação pode ter mais de um transporte explícito, mas não presumir semântica igual para HTTP request/reply e stream.
- Servidor executa autorização por operação real, e não pelo nome do pacote cliente.

## Artefatos de teste auxiliares

REST -> Postman + cURL. WS -> mensagem de exemplo, documento AsyncAPI, exemplos `wscat`/cliente do projeto quando necessário. gRPC -> `.proto`, descriptor e exemplos `grpcurl`; metadados secretos via env/secure tooling. Não fingir que um arquivo `.sh` cURL cobre stream gRPC automaticamente.
