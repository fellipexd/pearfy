# Arquitetura de performance do Pearfy

## Princípio central

**Remover trabalho desnecessário e controlar trabalho inevitável.** Não criar um scheduler concorrente alternativo, GC, substituto de SwiftNIO ou protocolo HTTP próprio antes de evidência muito forte. A performance final depende de rede, banco, DNS, TLS, JSON, segurança, log e aplicação, não só da linguagem.

## Divisão de responsabilidades

```text
Application / Starters
      |
Generated Registry / Factories / Route Descriptors
      |
Application Context / Scope Manager / Lifecycle
      |
HTTP Adapters ------ Async Work Admission ------ Resource Pools
      |                       |                        |
SwiftNIO             Swift Concurrency         DB / Cache / HTTP
      \_______________________|________________________/
                              |
               Metrics / Traces / Benchmarks
```

**Módulos propostos** (não criar arquivos vazios apenas para cumprir nomes):

- `PearfyBenchmarks`: cenários, drivers de carga, relatórios e budget de regressão; ferramenta de desenvolvimento, não dependência de runtime.
- `PearfyRuntime`: contratos pequenos de admission control, deadline, cancellation e lifecycle; só extrair se mais de um módulo precisar deles.
- `PearfyMemory`: utilitários para buffers/leases/diagnóstico se benchmarks justificarem; não encapsular ARC.
- `PearfyHTTP`: roteamento, codecs e middleware, mantendo `PearfyNIO` como adaptador.

## Política de hot path

- Resolver dependências singleton em bootstrap, não em todo request.
- Evitar reflection, strings e construções de regex repetidas no tratamento de rotas.
- Minimizar conversões byte↔String e cópias de bodies.
- Não alocar `Task` sem necessidade; limitar fan-out por requisição.
- Configuração, logging, autenticação e observabilidade devem ter custo medido e controlável.
- Segurança e correção prevalecem sobre micro-otimização.

## O que NÃO significa “mais rápido”

Baixo RSS em idle pode coexistir com throughput ruim; alto RPS pode esconder p99 degradado; um benchmark JSON em memória não representa um CRUD com Postgres. Medir sempre latência, throughput, RAM, CPU, alocações quando acessíveis, erro e custo operacional juntos.
