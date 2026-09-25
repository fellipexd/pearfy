# PearfyContracts, PearfyMCP e projetos AI-ready

## Objetivo
Código reduzido e legível com contratos estritos, sem payloads `[String: Any]` no domínio. O modelo Swift é fonte de schema de persistência; DTOs/contratos de transporte específicos podem ser distintos quando houver necessidade de versionamento ou exposição pública.

## MCP
- `@MCPTool`, `@MCPResource`, `@MCPPrompt` como APIs propostas; gerar schemas de input/output tipados e validação no servidor.
- MCP SDK Swift como adaptador (transportes stdio e Streamable HTTP conforme suporte certificado), com versões de protocolo fixadas e testes de interoperabilidade.
- MCP **não** obriga uma LLM a chamar ferramenta nem é barreira de segurança isolada.
- Ferramentas de escrita exigem autorização efetiva no servidor, escopo, auditoria, classificação de risco e confirmação externa quando política requerer.

```swift
// API proposta
@MCPTool(name: "payments.find", readOnly: true)
func find(_ input: FindPaymentInput) async throws -> PaymentDTO {
    try await service.find(input.id)
}
```

## Contract-first entre transportes
- REST: JSON + OpenAPI; gRPC: `.proto` + Protobuf; MCP: JSON Schema tipado; TOON opcional para contexto de LLM, não substituto de Protobuf no transporte RPC.
- Nunca prometer que um único Swift DTO cobre todos os detalhes de compatibilidade de REST/gRPC/MCP sem mapping/versionamento.
- IDs UUIDv7 por padrão no ORM, mas API externa descreve string/UUID de modo compatível e versionado.

## Contexto do agente
`pearfy ai context` gera manifesto de módulos, services, contratos, referências e regras selecionadas; não despeja repositório inteiro. Fonte gerada a partir de metadados e arquivos vigentes, não YAML divergente editado em paralelo.

## Estado
Documentar APIs como contratos-alvo até testes provarem implementação real. Módulos ausentes não podem ser importados como se existissem.
