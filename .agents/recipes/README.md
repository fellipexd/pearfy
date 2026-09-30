# Pearfy integration recipes

Load a recipe only when its exact integration is part of the task. A recipe marked **planned** is a roadmap boundary, not an API suggestion. The module Registry and source/tests remain authoritative.

- [`social-with-identity.md`](social-with-identity.md) — planned: Identity and SocialLogin are not installable.
- [`social-with-moderation.md`](social-with-moderation.md) — partial: contracts/worker exist; durable content adapter does not.
- [`social-with-notifications.md`](social-with-notifications.md) — planned delivery; only notification contracts exist.
- [`payments-with-approvals.md`](payments-with-approvals.md) — planned: neither product exists.
- [`chatbot-with-crm.md`](chatbot-with-crm.md) — planned workflow; PearfyAI is only a chat client.
- [`chatbot-with-whatsapp.md`](chatbot-with-whatsapp.md) — planned; no chatbot or WhatsApp adapter exists.
- [`metric-with-guardian.md`](metric-with-guardian.md) — partial primitives only; no PearfyMetric analytics/Guardian policy gate.
- [`logs-with-observability.md`](logs-with-observability.md) — planned structured logging; current module supplies health and Prometheus metrics only.

These files record dependencies and availability, not proposed public APIs. Before coding, load Skills for the installed modules and inspect the actual contracts.
