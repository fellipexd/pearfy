# Plano de integração com o roadmap já em execução

## Não interromper o marco atual

O roadmap original (`docs/01-ROADMAP.md`) continua como fonte de verdade para **ordem de recursos**. Este adendo define condições de arquitetura, medição e segurança operacional para etapas ainda abertas. Não renumerar lançamentos 0.1–1.0, não descartar trabalho concluído, não refazer DI e HTTP sem perfil ou defeito demonstrável.

## Aplicação sem conflito

1. Fazer snapshot de commit/branch e identificar o estado atual de `PearfyCore`, DI, macros, discovery e HTTP.
2. Adicionar estes documentos sob `docs/performance/` ou como pasta de adendo referenciada pelo README existente. Não sobrescrever `docs/06-BACKLOG.md`.
3. Criar issues `PPERF-*` com links para as issues existentes `PDI-*`, `PMAC-*`, `PDIS-*` e `PWEB-*`.
4. Abrir primeiro uma PR de **medição sem alteração de comportamento**: benchmark + instruções de reprodução + baseline.
5. Implantar melhorias pequenas, uma por PR, com perfil antes/depois e testes funcionais preservados.
6. Marcar como opcional/experimental qualquer recurso que demande nova API pública ou integração operacional ainda não disponível.

## Pontos de encaixe

| Roadmap existente | Aditivo recomendado | Regra de integração |
|---|---|---|
| `PDI-001`–`PDI-007` | `PPERF-DI-001`–`004` | DI correto antes de DI rápido; não manter lock durante `await`. |
| `PMAC-001`–`003`, `PDIS-001`–`002` | `PPERF-AOT-001`–`003` | Medir custo de build e impacto do manifesto gerado. |
| `PWEB-001`–`005` | `PPERF-HTTP-001`–`004` | Baseline SwiftNIO equivalente antes de otimização. |
| `PDAT-001`–`003` | `PPERF-IO-001`–`002` | Pool, timeout e transação antes de tuning de SQL. |
| `POPS-001` | `PPERF-OBS-001`–`002` | Telemetria deve medir sua própria sobrecarga. |
| Gates 1.0 | `PPERF-QA-001`–`004` | Carga, soak, shutdown, stress e regressão em CI. |

## Entrega mínima agora (durante marco DI)

- Medição de bootstrap e RSS de um processo de demonstração **sem HTTP**.
- Testes de 1/10/100 resoluções concorrentes do mesmo singleton; sem deadlock, sem duplicate factory.
- Factories async com tratamento de erro e cancelamento; não bloquear threads à espera de async.
- Falhas de dependência detectadas antes da aceitação de tráfego (quando houver HTTP).
- Uma decisão registrada sobre quais componentes são Sendable e como o contexto protege mutabilidade.

## Definição de integração completa

O adendo foi incorporado quando a equipe consegue apontar para issues rastreáveis, baselines reproduzíveis e documentação dos limites de recursos, **sem precisar substituir ou reiniciar o projeto inicial**.
