# Segurança transversal para código implementado com IA

## PearfySecurity
Autenticação e autorização declarativas não substituem checagem de ownership, tenancy, escopo e estado mutável de cada operação. REST, gRPC e MCP passam pelo mesmo domínio de permissão aplicável, embora tenham adaptadores diferentes.

## Políticas de implantação
- Fail closed se JWT/OIDC issuer/audience/chaves ou autorização exigida não validarem.
- Dados sensíveis não aparecem em logs, traces, métricas nem contexto enviado à LLM.
- Configuração de dev não desabilita TLS/auth em prod por fallback oculto.
- Contas/tenants não são selecionados apenas pelo ID informado pelo chamador.
- Tools MCP de escrita exigem autorização efetiva no servidor; anotações MCP são metadados, não um mecanismo de enforcement.
- Controles de acesso do banco complementam o Guardian, sobretudo escrita no ledger e saldos.
- Revisões de dependências, detecção de secrets e testes de endpoints protegidos entram na CI.

## Matriz de testes
- Usuário A tentando debitar conta de usuário B.
- Tenant A consultando/alterando transação de tenant B.
- Token inválido, expirado e de emissor/audience não autorizados.
- Retry com requestId de outro escopo.
- Tool MCP de escrita invocada por agente sem permissão.
- Vazamento de bearer token, CPF/PII e saldos em logs.

## Gate
Não rotular `PearfySecurity` como apto para uso financeiro apenas porque compila; exigir implementação auditada, testes de integração e política operacional.
