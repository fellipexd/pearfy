# Arquitetura de pacotes e política de dependências

## Monorepo inicial

```text
Pearfy/
├── Package.swift
├── Sources/
│   ├── Pearfy/                     fachada
│   ├── PearfyCore/                 tipos fundamentais
│   ├── PearfyDI/                   resolução e escopos
│   ├── PearfyContext/              bootstrap, registry, lifecycle
│   ├── PearfyConfiguration/        profiles e env
│   ├── PearfyMacros/               interface pública de macros
│   ├── PearfyMacrosImpl/           implementação SwiftSyntax
│   ├── PearfyDiscovery/            manifesto/registro gerado
│   ├── PearfyWeb/                  contratos HTTP
│   ├── PearfyNIO/                  adaptador HTTP SwiftNIO
│   ├── PearfyData/                 modelo de persistência
│   ├── PearfyPostgres/             driver inicial
│   ├── PearfySQLite/               driver testes/desenvolvimento
│   ├── PearfySecurity/
│   ├── PearfyValidation/
│   ├── PearfyCache/
│   ├── PearfyRedis/
│   ├── PearfyMessaging/
│   ├── PearfyRabbitMQ/
│   ├── PearfyKafka/
│   ├── PearfyJobs/
│   ├── PearfyBatch/
│   ├── PearfyActuator/
│   ├── PearfyCloud/
│   ├── PearfyAI/
│   ├── PearfyTesting/
│   └── PearfyCLI/
├── Plugins/PearfyDiscoveryPlugin/
├── Tests/
├── Examples/
└── docs/
```

A árvore descreve **organização pretendida**; apenas `PearfyCore` e `HelloPearfy` existem neste ZIP. Módulos opcionais podem migrar para packages próprios após a estabilização dos contratos.

## Regra de dependência

`Core` não conhece rede, banco, logger concreto ou tooling. `DI` depende de Core; `Context` de Core + DI; Web abstrai request/response; NIO é adapter. Persistência, segurança, cache, mensageria e observabilidade dependem de contratos e nunca do CLI. Nenhum starter traz drivers externos sem necessidade.

## Dependências técnicas planejadas

- Swift Package Manager, SwiftSyntax/macros, build-tool plugin (discovery).
- SwiftNIO e componentes de transporte HTTP; TLS via pacotes compatíveis.
- Async HTTP Client para outbound HTTP.
- PostgresNIO e driver SQLite adequado; MySQL posterior.
- Swift Service Lifecycle e Swift Log / Metrics / Tracing / OTel.
- Swift Testing para unitários; banco/broker reais para integração em CI.

Versões serão fixadas com política de atualização e auditoria de supply chain; escolher versão concreta na issue de cada módulo.

## Deploy

Mac/Linux development; runtime Linux container first; health/readiness e sinais; dev server com rebuild+restart; docker e chart exemplar depois dos gates web/data.

## Observação sobre o protótipo

O container síncrono atual mantém mutex recursivo durante a factory. Essa simplificação permite resolução aninhada num protótipo, mas restringe concorrência e não dá suporte a factory async. Reprojetar a resolução sob concorrência antes do gate 0.1.
