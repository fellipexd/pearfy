# Pearfy Secure Payload — design de segurança

> Design alvo, **não** uma implementação criptográfica pronta. Revisão de threat model e auditoria especializada obrigatórias antes de produção. Não implementar primitivas criptográficas caseiras nem declarar E2EE usuário↔usuário: o backend descriptografa.

## Modelo em camadas

1. **Obrigatório em produção:** HTTPS, WSS, gRPC sobre TLS; verificar hostname/cadeia/certs; proibir fallback cleartext silencioso. mTLS opcional para serviços internos.
2. **Adicional/opt-in:** `@SealedPayload(.request|.bidirectional)` no grupo/controller/endpoint com prioridade dos mínimos de segurança do servidor. Protege corpo através de terminadores TLS intermediários até o ponto de descriptografia Pearfy. Não protege depois da descriptografia nem contra JS malicioso dentro do mesmo front.
3. Auth, authz, ownership, tenancy, replay, idempotência e auditoria são controles separados.

## Protocolo proposto

Selecionar criptografia híbrida padronizada (candidato: HPKE, RFC 9180), suites interoperáveis com bibliotecas **testadas** no Swift, Android e TypeScript; perfilar disponibilidade real do browser e algoritmos suportados antes de fixar suite. Chaves públicas distribuídas via endpoint de discovery autenticado sob TLS, com `kid`, validade, suite, data de depreciação, cache control e key-rotation. Suporte a pinning/assinatura de chave pública somente com plano operacional para rotação e recovery. Nunca gerar `privateKey`, client secret ou chave AES compartilhada hard-coded nos SDKs.

**Envelopes ilustrativos**: `protocolVersion`, `kid`, `enc`/material efêmero, `ciphertext`, `messageId`, `issuedAt`, `expiresAt`, `requestBinding` e parâmetros necessários. O envelope final segue encoding interoperável documentado e golden vectors. Evitar duplicar JSON e criptografar strings sem delimitação canônica.

**AAD / binding**: associar criptograficamente versão, método, caminho canonizado, grupo/operação, timestamp/expiry, messageId, client/auth context apropriado, tipo de resposta e id de correlação. Validar método/path antes de processar corpo; padronizar canonicalization de proxies/route params. Não depender exclusivamente de segredo JWT em AAD ou expor tokens por engano.

**Bidirectional**: define fluxo de resposta formal com separação de chaves por direção, request correlation e sequence/counter, usando mecanismo derivado/uso exportador do protocolo padronizado ou proteção equivalente revista por especialista. Não assumir que criptografar request com chave pública do servidor garante proteção automática da resposta. Respostas de erro também precisam de política de cifragem e formato recuperável; falhas de handshake/crypto não devem vazar payload.

**Nonce, replay, clock**: nonces exclusivos no escopo da chave, expiração curta, limite de skew, antirreplay compartilhado entre réplicas por mensagem/sessão conforme threat model. Garantia "executar transferência uma vez" continua sendo a **idempotência durável** do PaymentEngine, com request ID estável e payload hash escopado. Retransmissão legítima de mesmo pagamento pode ter novo envelope, mesma chave financeira.

## Múltiplas instâncias

Todas as réplicas autorizadas devem resolver `kid` e key material com controle de acesso central, preferencialmente KMS/HSM/secret manager; não exigir uma API primária ou sessão stickiness. Retenção temporária da chave antiga para mensagens válidas em trânsito, revogação de chaves comprometidas e respostas a client cache stale. Se KMS falhar, não rebaixar para texto claro.

## Clientes e operações

- Swift: CryptoKit ou biblioteca compatível após confirmar suite e API para target.
- Android: provider/biblioteca compatível e interoperável; Keystore quando adequado à gestão de chaves do cliente.
- TS browser: Web Crypto quando disponível + biblioteca auditável do protocolo, verificando ambientes reais; Node adapter próprio se necessário.
- Tamanho do payload, compressão antes/depois, attachments e streaming precisam de especificação própria; jamais usar um nonce fixo para frames repetidos.
- Streaming WS/gRPC exige framing, sequence e anti-replay explícitos. Não bloquear P0 por isso: recursos extra são P2 após o básico de REST estar certificado.

## Limites e observabilidade

Criptografia adicional não oculta URL, método, IP, tamanhos, timing e headers não protegidos; tokens devem permanecer protegidos por TLS e não ser registrados. Proxies que terminam TLS não podem inspecionar corpo cifrado; aplicar controles de tamanho/rate limit antes e validações semânticas depois da descriptografia. Logs decripto não podem conter PII/saldos/tokens. Fail closed quando política exigir cifragem e um client enviar JSON em claro.

## Gates de segurança

Testar tamper/AAD mismatch; troca de rota ou método; replay cruzando duas réplicas; stale/unknown kid; rotação; relógio; truncamento; tags inválidas; plaintext downgrade; resposta trocada; cancellation; limites de memória; key leak em artefatos; client comprometido como ameaça fora da garantia. Revisão formal de crypto antes de marcar `.bidirectional` pronto.
