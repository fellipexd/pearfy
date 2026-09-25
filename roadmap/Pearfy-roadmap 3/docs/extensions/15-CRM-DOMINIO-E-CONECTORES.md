# 15 — PearfyCRM: gestão e acompanhamento de clientes

`pearfy add crm` inclui domínio CRM independente; pode funcionar sem Chatbot, WhatsApp, Payments ou IA. Utiliza PearfyBackoffice/PearfySecurity conforme integração de auth escolhida; autorização e tenant isolation sempre obrigatórios no deployment BKO.

## Áreas

- Customer/contact profile, organizações/segmentos, responsável e equipes, extensibilidade de campos com política de dados.
- Leads, oportunidades, estágios/funil e atividades de transição auditadas.
- Timeline consolidada de interações, tickets, notas, campanhas quando conectores instalados; proveniência e ID de origem para dedup.
- Tasks, reminders, follow-up, relatórios determinísticos e agregados.
- Lifecycle e retention/delete por política aplicável; busca por campos permitidos, PII indexada apenas quando justificável e protegida.

## Relação com outros módulos

`pearfy add crm-whatsapp`, `crm-telegram`, `crm-chatbot`, `crm-payments` instalam bridges; não importam magicamente todos os providers. Customer timeline contém referência/summary autorizado, não cópia irrestrita do evento original de IA/pagamento.

## Contratos

`Customer`, `Contact`, `Lead`, `Opportunity`, `Activity`, `CRMTask`, `Assignment`. Cada agregado tem tenant, owner/group scope, version e campos de auditoria. Identidades externas mapeadas por provider+account+external_id, com merge/dedup explícito e reversível. `CustomerInsights` não é campo mutável por IA no domínio core; módulo separado.

## Banco e ACL

Migrations com FK/tenant constraints e índices por (tenant,assigned_group,updated_at) para queries reais; impedir enumeração de outros tenants ou IDOR, evitar N+1 na timeline. Soft-delete ou hard-delete de dados conforme política e retenção; não presumir que “audit forever” vence obrigações de privacidade.

## Aceite

CRUD com roles/scopes, timeline multicanal sem duplicata, rerouting de responsável sem perder histórico, cross-tenant negado, import CSV parcial/erros reportados, nenhum módulo especializado carregado quando apenas CRM instalado.
