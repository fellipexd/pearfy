# 01 — Pearfy Module Manager e CLI

## Contrato de instalação

- Produtos SwiftPM independentes e versionados por SemVer; manifestos de módulo com id, namespace Swift, constraints, capacidades, plataforma, dependências obrigatórias/opcionais, migrations, scaffolding, rotas, policy e hooks de validação.
- CLI aplica **plan -> diff -> approve -> apply -> verify** em alterações potencialmente destrutivas; operações idempotentes. Preserva código de aplicação e histórico de migration existente.
- Só grava dependências necessárias em `Package.swift`; não exigir baixar/compilar SDKs proprietários não selecionados. Pinagem/reprodutibilidade via `Package.resolved` e manifesto `pearfy.modules.lock` (proposta).
- Registry assinado/verificado, checksums, origem e versão; bloquear dependência circular, conflito de versões, target incompatível e colisão de rota.
- Comando remove desconecta pacote e scaffolding gerado sob gestão do CLI; **nunca drop automático** em tabelas, histórico, arquivo customizado ou segredos.

## Interface CLI-alvo

```bash
pearfy modules list
pearfy modules info chatbot
pearfy add ai
pearfy add chatbot
pearfy add whatsapp
pearfy add telegram
pearfy add backoffice
pearfy add approvals
pearfy add crm
pearfy add crm-insights
pearfy add logs
pearfy add metric
pearfy add webhooks
pearfy add jobs --store postgres
pearfy modules plan --add crm-insights
pearfy modules doctor
pearfy modules update --dry-run
pearfy remove chatbot --dry-run
```

**Não usar `--ai ollama` em módulos consumidores.** Configurar IA em `pearfy ai ...` e/ou config do backend; CLI do módulo instala dependência e exige profile válido quando ativado.

## Manifesto de exemplo (esquema conceitual)

```yaml
id: pearfy-crm-insights
package: PearfyCRMInsights
requires:
  - pearfy-crm
  - pearfy-ai
optional:
  - pearfy-metric
capabilities: [crm.insights]
configuration:
  - pearfy.crm.insights.ai-profile
migrations: []
validation:
  - no-cloud-export-without-approval
```

## Compatibilidade e segurança

- Validar mínimo Swift/OS e recursos específicos; distinguir Linux server de iOS/Android SDK.
- Plugins de terceiros devem passar por verificação de supply chain; não executar scripts de instalação remotos irrestritos sem consentimento.
- Mostrar árvore de dependências, plano de alterações e status parcial; falha permite rollback dos arquivos de configuração **sem fingir reversão de migration já aplicada**.

## Aceite

Projeto mínimo compila sem módulos especializados; adicionar CRM não instala payments/chatbot; adicionar WhatsApp isolado não instala AI; reexecutar add não duplica registros; remove preserva dados; conflitos produzem erro recuperável e plano; CI valida lock.
