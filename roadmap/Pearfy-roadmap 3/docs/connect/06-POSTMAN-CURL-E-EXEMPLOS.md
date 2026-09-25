# Geração de Postman Collections e cURL por grupo

## Objetivo e fonte de verdade

Gerar documentação executável dos mesmos contratos HTTP/REST que originam os SDKs. Postman/cURL **não** são fontes separadas: nenhuma requisição configurada manualmente deve se tornar pré-requisito para gerar pacotes de clientes.

Exemplo de grupos: `/bko` -> `backoffice.postman_collection.json`; `/app` -> `mobile.postman_collection.json`; `/public` -> `public.postman_collection.json`. Cada collection é autônoma, com nome, versão, variáveis e pastas por resource/controller. `--combined` gera uma collection única **com primeira camada de pastas por grupo**, sem misturar autenticações inadvertidamente.

## Pastas planejadas

```text
postman/
  backoffice.postman_collection.json
  mobile.postman_collection.json
  public.postman_collection.json
  combined.postman_collection.json          # sob demanda
  environments/
    local.postman_environment.json
    staging.postman_environment.json
    production.postman_environment.json
curl/
  backoffice/auth/login.sh
  backoffice/auth/refresh.sh
  mobile/auth/login.sh
  mobile/payments/transfer.sh
  mobile/payments/history.sh
  public/users/find.sh
```

Postman: `{{baseUrl}}` **sem** path de grupo no default recomendado e cada request usa `/bko/...` ou `/app/...`, evitando dupla concatenação. Environments contêm URLs/variáveis inofensivas e placeholders, não chaves reais, refresh tokens, senhas ou cookies. Bearer token em variable definida pelo usuário ou runtime auth; nunca em JSON committed. Verificar formato exportável Postman collection usado na versão escolhida.

## O que gerar para cada rota

- Método HTTP, path, variáveis, query, headers, content type, schema de body, status esperados, erros, exemplo **sintético/redigido** e identificação de grupo.
- Auth herdada quando se aplicar, com override apenas onde a policy permitir.
- Exemplo de body válido e test assertions opcionais; parametrizar datas/IDs sem invocar endpoints reais no build.
- Nome de arquivo cURL estável e sem colisões (operação/version quando mesmo path aceitar métodos diferentes).
- Script shell com `set -euo pipefail`, `PEARFY_BASE_URL`, exemplos de path/query escapados, `curl --fail-with-body` se suportado, headers apropriados e leitura de token por env (sem valor real hard-coded).
- Em operações de escrita idempotentes, mostrar `requestId` estável fornecido pelo usuário ao repetir a mesma intenção; não gerar UUID diferente a cada retry financeiro.
- Upload binário e corpos grandes: preferir arquivo local (`--data-binary @file`), não embutir secrets em texto.

## Proteção de payload habilitada

Collection HTTP comum com body JSON não cumpre `@SealedPayload`. Documentar necessidade de helper interoperável com protocolo e limitações reais do script runner Postman. `pearfy request call --group ... --operation ... --body arquivo.json` pode ser a referência segura e testável; cURL individual protegido deve acionar helper do CLI para criar um **envelope novo** por envio e usar dados temporários seguros. Não distribuir chave privada, não prometer Postman automático antes de testes e não gerar um script que ignore a proteção.

## WebSocket e gRPC

REST: collection HTTP e cURL por operação. WebSocket: exemplos de eventos e AsyncAPI, arquivos auxiliares e eventual export nativo apenas se verificavelmente compatível com formato/versão Postman. gRPC: `.proto`, descriptor e exemplos `grpcurl` usando variáveis em runtime; não fingir export universal em collection HTTP v2.1. A CLI deve avisar na saída quais transportes são cobertos por cada arquivo.

## Verificações

Para grupo exportado, cada operação HTTP exportável gera exatamente uma request collection e um cURL individual (salvo exclusão explicitamente documentada). Comparar método/path/DTO/auth entre registry, OpenAPI, collection e script. Determinismo e secret scanning obrigatórios.
