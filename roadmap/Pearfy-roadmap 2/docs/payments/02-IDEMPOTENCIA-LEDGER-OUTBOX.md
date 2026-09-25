# Idempotência, ledger e outbox — invariantes financeiros

## Idempotência durável
Chave lógica deve conter `tenant/scope + operation type + client key` com índice UNIQUE. Armazenar fingerprint canônico dos parâmetros relevantes, status e resultado recuperável; comparar request repetido com intenção original.

Dois processos reclamando a mesma chave devem competir sob constraint e política de lock/UPSERT transacional certificada, **não** sob `SELECT` de ausência e `INSERT` desprotegido.

| Caso | Resultado |
|---|---|
| operação confirmada com mesma chave/payload | recuperar resultado original |
| operação em processamento | esperar/retornar estado recuperável conforme contrato |
| chave igual e payload distinto | erro de conflito |
| commit incerto | reconciliar no armazenamento antes de retry |
| expiração de chave | política por domínio; nunca expirar enquanto houver risco de reexecução prejudicial |

## Ledger
- Lançamentos de uma transferência interna na mesma moeda devem somar zero, sob a convenção de sinais definida.
- Ledger confirmado append-only; estorno cria novos lançamentos, não edita/apaga originais.
- Saldo disponível, reservado, pendente e contabilizado têm semântica explícita; saldo derivado/materializado reconciliável com ledger.
- Restrições simples em DB + serviço de postagem controlado + verificações transacionais/mecanismos por adapter: `CHECK` simples não valida soma de múltiplas linhas.
- Reconciliação agenda divergências para intervenção e não “conserta” dinheiro silenciosamente.

## Outbox/inbox
Na mesma transação local: registrar saldo/ledger/resultado da operação e evento outbox. Publicar depois do commit, potencialmente **mais de uma vez**; consumidores precisam de inbox/idempotência e tratamento de ordem/retries. Mensageria não garante exactly-once de ponta a ponta sozinha.

## Pagamentos externos
REQUESTED -> RESERVED -> DISPATCHED -> CONFIRMED/FAILED/UNKNOWN (grafo detalhado obrigatório por operação/provedor). UNKNOWN impede emissão cega de nova chamada; consultar status do provedor com referência estável, processar webhooks idempotentes, conciliar; compensação não é rollback físico de pagamento já efetuado.

## Segurança financeira
Proibir Float/Double em dinheiro, `requestId` inventado em retry, chamadas externas dentro de long transaction, atualização direta de saldo e `Task.detached` não supervisionada. Autorizar origem, destino, tenant e limites de operação em backend, não apenas pelo contrato MCP.
