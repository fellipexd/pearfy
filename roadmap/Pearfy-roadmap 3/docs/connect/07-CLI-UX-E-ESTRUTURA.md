# CLI Pearfy Connect — comandos e estrutura de saída

## Interface-alvo

```bash
pearfy contracts build
pearfy contracts check --against contracts/baseline.pearfy
pearfy contracts inspect --group mobile

pearfy sdk generate --all
pearfy sdk generate --group mobile --target ios
pearfy sdk generate --group mobile --target android
pearfy sdk generate --group backoffice --target typescript
pearfy sdk check --all

pearfy export postman
pearfy export postman --group mobile
pearfy export postman --combined
pearfy export curl
pearfy export curl --group backoffice

pearfy request call --group mobile --operation payments.transfer --body transfer.json
```

`--all` gera apenas combinações **permitidas** pela configuração: não produzir TypeScript para `mobile` quando o grupo limita a iOS/Android. Pedido explícito inválido deve causar erro não-zero, com caminho para configuração do grupo. Comandos `export` podem aceitar `--out`, `--format` onde fizer sentido; arquivos gerados exigem diff limpo no CI se forem versionados no repo.

## Layout proposto

```text
dist/
  contracts/
    application.pearfy
    groups/
      backoffice.pearfy
      mobile.pearfy
      public.pearfy
    openapi/
      backoffice.json
      mobile.json
      public.json
    asyncapi/
      mobile.json
    protobuf/
      application.desc
      *.proto
  sdk/
    ios/PearfyMobileClient/
    ios/PearfyPublicClient/
    android/pearfy-mobile-client/
    android/pearfy-public-client/
    typescript/pearfy-backoffice/
    typescript/pearfy-public-client/
  postman/
    backoffice.postman_collection.json
    mobile.postman_collection.json
    public.postman_collection.json
    environments/{local,staging,production}.postman_environment.json
  curl/
    backoffice/auth/login.sh
    mobile/payments/transfer.sh
    public/users/find.sh
  reports/
    contract-compatibility.json
    sdk-coverage.json
    security-policy.json
```

O schema físico do arquivo `.pearfy` só será congelado depois da IR e de golden tests. Nunca inventar que `.pearfy` é executável binário ou que substitui biblioteca compilada: um contrato empacotado não executa rede sozinho.

## Environments / config

- Configuração do grupo em macros; config de ambiente (baseURL, timeouts, cert policy) no cliente ou variables, não no contrato invariável.
- Sem segredos em artefatos. Valores localhost/staging/prod são placeholders configuráveis.
- Modo `--dry-run` e relatório de alterações, inclusive operações removidas e target afetado.
- Output por padrão determinístico; manifests de versões de geradores e checksum.
- Versionamento do CLI e IR desacoplado dos SDKs publicados; suporte de migração para formatos anteriores.

## DX e erros

Relatório por grupo e alvo: número de REST methods, WS events, gRPC services/methods, endpoint intencionalmente excluído, não suportado, pendências de segurança e artefatos gerados. Nunca marcar geração como sucesso se um dos targets solicitados falhou; suportar execução parcial **com código de saída de falha** e artefatos temporários sem substituir release estável.
