# 09 — PearfyLogs: logging estruturado e exportadores

**Instalação:** `pearfy add logs` -> núcleo do logger, sem Grafana/Datadog instalados. Foundation Swift `swift-log` / `Logger`, sem log runtime incompatível. Module independente, integração opcional com PearfyObservability.

## Responsabilidades

1. Evento estruturado (`timestamp`, severity, service, version, environment, instance, route template, operation, trace_id/span_id quando presentes, error_code e campos permitidos).
2. Contexto de request/TaskLocal propagation consistente em Swift 6 e nos workers (sem reter ciclo ou vazar contexto entre requests).
3. Privacy policy BEFORE console, file, OTLP e providers: allowlist de campos, regex redaction complementar, tamanho máximo, rejeitar request/response bodies, Authorization/cookie, token, SQL bind, conversa de clientes e input financeiro.
4. JSON stdout por padrão; integração OTLP por coletor/agente. Não forçar SDK proprietário do fornecedor em cada aplicação.
5. Buffer bounded, batch async, sampling/tail policy quando aplicável, drop counter, tempo máximo de flush, emergency stderr e falha do exporter isolada do request.
6. Distinguir logging operacional (best effort) de PearfyAudit (durável) e approvals/ledger (source of truth); stack trace bruto não segue para IA cloud.

## Destinos/presets CLI

| CLI | Fluxo proposto |
|---|---|
| `pearfy logs connect grafana` | OTLP/stdout -> Grafana Alloy/collector -> Loki; template datasource/dashboard |
| `pearfy logs connect datadog` | OTLP/stdout -> agent/collector -> Datadog Logs |
| `pearfy logs connect elastic` | collector -> Elasticsearch com exporter adequado |
| `pearfy logs connect opensearch` | exporter/adapter certificado do destino |
| `pearfy logs connect splunk` | collector -> Splunk HEC |
| `pearfy logs connect aws` | exporter -> CloudWatch Logs |
| `pearfy logs connect azure` | exporter -> Azure Monitor |
| `pearfy logs connect google-cloud` | exporter -> Cloud Logging |
| `pearfy logs doctor` | Egress, privacy, config, perda/export errors e collector health |

Nunca confundir **Grafana (UI)** com **Loki (armazenamento de logs)**; configurar datasource e destino. Para novos templates Grafana, preferir Alloy/Collector em vez de Promtail legado. Certificar nomes/exporters/compatibilidade por versão antes de prometer suporte a cada sink.

## API-alvo

```swift
@Service
final class TransferService {
    @Autowired var logs: PearfyLogger
    @Autowired var payments: any PaymentEngine
    func transfer(_ input: TransferInput) async throws -> TransferResult {
        logs.info("Transferência solicitada", fields: ["operation": "payments.transfer"])
        // Sem dados completos de input e sem IDs de clientes como labels.
        return try await payments.transfer(input)
    }
}
```

Exemplo ilustrativo: adaptar a DI, os macros e a interface do PaymentEngine que existirem na branch.

## Cardinalidade e UX

- Route template `/app/users/{id}`, não URL concreta; identificadores request/trace em metadata pesquisável quando aplicável, **não label indexada de Loki**.
- Não logar toda query normal em INFO; queries normais ficam em métricas/traces, logs WARN por slow query/timeout e debug temporário limitado.
- Correlação de request e trace atravessa jobs e eventos com propagação explícita de contexto, nunca extração de PII.

## Aceite

Mesmo evento gera JSON estruturado válido em duas instâncias; logs sem secrets sob falhas; Grafana Loki e Datadog env templates passam smoke tests se credenciais de teste disponíveis; exporter offline não derruba API nem aloca memória ilimitada; logs não substituem audit trail. Verificar métricas de drop e timeouts de flush.
