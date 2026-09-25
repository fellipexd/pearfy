# Exemplos de artefatos gerados (representações ilustrativas)

## Manifest `.pearfy` (trecho JSON interno conceitual)

```json
{
  "formatVersion": 1,
  "application": "sample-pearfy-app",
  "groups": [
    {"name": "backoffice", "httpPrefix": "/bko", "targets": ["typescript"]},
    {"name": "mobile", "httpPrefix": "/app", "targets": ["ios", "android"], "payloadProtection": "bidirectional"},
    {"name": "public", "httpPrefix": "/public", "targets": ["ios", "android", "typescript"]}
  ],
  "operations": [
    {"id": "backoffice.auth.login", "group": "backoffice", "transport": "rest", "method": "POST", "path": "/bko/auth/login"},
    {"id": "mobile.payments.transfer", "group": "mobile", "transport": "rest", "method": "POST", "path": "/app/payments/transfer", "payloadProtection": "bidirectional"},
    {"id": "public.users.find", "group": "public", "transport": "rest", "method": "GET", "path": "/public/users/{id}"}
  ]
}
```

Formato final terá tipos, auth, version, hashes e erros definidos em documentação do IR; esse trecho não é um schema congelado.

## Postman por grupo

```text
Pearfy — Backoffice [collection própria]
  Auth
    POST Login                 /bko/auth/login
    POST Refresh               /bko/auth/refresh
Pearfy — Mobile [collection própria]
  Auth
    POST Login                 /app/auth/login
  Payments
    POST Transfer              /app/payments/transfer   (helper sealed obrigatório)
Pearfy — Public [collection própria]
  Users
    GET Find                   /public/users/{{userId}}
```

## cURL individual básico

Arquivo gerado previsto: `dist/curl/public/users/find.sh`

```bash
#!/usr/bin/env bash
set -euo pipefail
BASE_URL="${PEARFY_BASE_URL:-https://localhost:8080}"
: "${USER_ID:?Informe USER_ID}"
curl --fail-with-body \
  --request GET \
  "${BASE_URL}/public/users/${USER_ID}" \
  --header "Accept: application/json"
```

`USER_ID` deve ser validado/escapado como path component pelo gerador final; o snippet é legível, não especificação completa de URL escaping. URLs usam HTTPS por padrão inclusive em examples (localhost dev pode optar por config explícita apropriada).

## cURL de rota sealed

Arquivo previsto: `dist/curl/mobile/payments/transfer.sh`

```bash
#!/usr/bin/env bash
set -euo pipefail
: "${PEARFY_BASE_URL:?Informe a URL HTTPS}"
: "${PEARFY_ACCESS_TOKEN:?Informe um token de teste autorizado}"
: "${TRANSFER_BODY_FILE:?Informe o JSON de teste}"
pearfy request call \
  --group mobile \
  --operation mobile.payments.transfer \
  --base-url "$PEARFY_BASE_URL" \
  --body "$TRANSFER_BODY_FILE"
```

O CLI deverá fornecer auth via provider/env seguro sem registrar valores, ou receber o token por canal protegido explícito; esse exemplo mantém `PEARFY_ACCESS_TOKEN` apenas como contrato de ambiente do comando futuro. Não imprimir o token em log e não usar segredo real hard-coded. O CLI usa o protocolo sealed; **não** faz POST simples com JSON ao servidor.

## Environment de Postman

Somente `baseUrl`, exemplos de IDs sintéticos e variáveis vazias (`accessToken` sem valor). Nunca guardar credenciais reais, especialmente em export automático ou em git.
