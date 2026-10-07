# PearfyGameServerRedisRecovery — roadmap

**Status:** implementação parcial. `PearfyGameServerRedisRecovery` expõe `RedisGameStateRecoveryStore` (Streams, checkpoint, lease com epoch monotônico, append/checkpoint fenced), `RedisGameServerStateMiddleware` (restore e checkpoints assíncronos por número de eventos ou na primeira atualização após o intervalo configurado), `GameStateRecoveryCheckpointScheduler` (captura periódica genérica fora do tick), `RedisDurableGameCommandSession` (write-ahead commit discreto), `RedisDurableGameCoopSession` (lifecycle/objetivos co-op) e `RedisDurableGameTickSession` (batches write-ahead de ticks autoritativos com movimento, ações de NPC, timers e draws RNG registrados). Os batches são limitados por bytes/itens, exigem números contíguos e usam o mesmo reducer async em commit e replay; um batch corresponde a um append e só pode ser publicado após confirmação. `RedisDurableGameTickWriteAheadBridge` aceita batches sincronamente do callback fixed-step usando staging bounded por count/bytes, e um único worker assíncrono faz commit e chama a publicação após o ack. Erro de stage fecha admissão; append/publicação ambíguos retêm o mesmo batch ID para retry. A aplicação ainda deve autenticar inputs, montar todas as transições server-authored e reagir a backpressure sem descartar estado confirmado. `makeBoundedQueue()` segue disponível como API de nível mais baixo. O middleware do manager continua best-effort. Crash em todas as fronteiras, perda de host/volume Redis, failover e workload high ainda não estão validados.

**Validação local (2026-10-07):** os 8 testes com prefixo `redisRecovery` passaram contra Redis 7 em container efêmero local, incluindo checkpoint chunked de 700 KiB, escrita idempotente, substituição/remoção de chunks antigos, restore e fencing após takeover, journal em múltiplas páginas, lease expirado, overflow e retomada após checkpoint. O container foi removido após o teste. Isto valida a integração de protocolo com Redis 7, mas não crash de processo, AOF/RDB persistente, failover de réplica ou RPO operacional.

**Restart abrupto com AOF validado (2026-10-07):** `redisRecoverySurvivesProcessAndRedisRestartWithAOF` passou em duas invocações de processo de teste separadas contra Redis 7 configurado com `appendonly yes` e `appendfsync always`. A fase `write` salva checkpoint e um evento; o Redis recebe `SIGKILL`, reinicia mantendo o mesmo diretório de dados e a fase `recover` adquire o lease seguinte (epoch 2), validando checkpoint, evento e sequência. Repetir com prefixo novo e o mesmo prefixo nas duas fases: `PEARFY_TEST_GAME_REDIS_CRASH_PHASE=write`, reiniciar o Redis sem limpar o diretório AOF, depois `...=recover`, com `PEARFY_TEST_GAME_REDIS_CRASH_PREFIX` igual em ambas. Isso comprova um caminho AOF específico, não crash em cada fronteira do jogo, falha de host/disco, réplica, failover ou garantia geral de RPO.

**Ordenação de projeções:** `RedisGameServerStateMiddleware` rejeita revisões menores que a revisão retida para a mesma chave antes de anexar ao journal; repetição da mesma revisão e payload é idempotente, enquanto payload diferente na mesma revisão é conflito. O teste com store em memória prova que stale/conflict não acrescentam eventos e que a projeção mais nova continua após restore. Isso protege a ordem do snapshot projetado, sem alegar durable commit de comandos do jogo.

**Gate de durable commit discreto:** `RedisDurableGameCommandSession` aceita reducer síncrono ou async; o gate de commit é levantado antes de executar qualquer reducer suspensível, e só libera após append ou erro. O evento guarda comando versionado e digest SHA-256 do resultado, não uma cópia integral do estado; checkpoints guardam estado atual + janela bounded de idempotência. Falha ambígua mantém a revisão em memória e permite retry do mesmo command ID; conflito de sequência falha fechado. Testes cobrem append confirmado-com-erro/retry idempotente, ausência de mutação antes do append e concorrência tanto durante append quanto durante suspensão do reducer async.

**Integração co-op:** `RedisDurableGameCoopSession` usa o async reducer para restaurar `GameCoopSession`, aplicar uma transição discreta e codificar o checkpoint privado resultante. Suporta join/start, disconnect/reconnect/abandon/expiry, progresso/conclusão de objetivo, finish e close. O command ID do journal é propagado para a deduplicação interna do objetivo. O encoder ordena coleções `Set` antes do JSON para que digest do replay seja estável entre processos. Testes cobrem mudança de estado somente após append, replay do sufixo, takeover, dedupe, visibilidade privada por jogador, conjunto com ordens de inserção diferentes e bloqueio concorrente durante reducer suspenso. Um teste real Redis 7 em container também validou journal/recovery/takeover do comando co-op. Esse adapter isolado ainda não persiste movimento/NPC/RNG; `RedisDurableGameTickSession` fornece agora o caminho genérico de batches para isso, desde que a aplicação inclua cada efeito confirmado na transição autoritativa.

**Commit de ticks autoritativos:** `RedisDurableGameTickSession` agrupa ticks consecutivos, ações opacas validadas pelo reducer da aplicação e draws RNG num único evento fenced; ele verifica limites, cursor contínuo e digest do estado em replay. `makeBoundedQueue()` mantém head e bytes limitados, oferece sinais coalescidos e não remove o batch se o append falhar; `commitNext()` é a única operação que faz I/O e deve rodar numa tarefa separada. `RedisDurableGameTickWriteAheadBridge` acrescenta staging síncrono para callback de tick, worker serial de commit e callback após confirmação; antes de publicar, valida que o recibo corresponde ao último tick do batch, impedindo que ID reutilizado publique estado antigo. `GameRealtimeSimulation(initialTick:)` retoma do cursor recoverable. Os testes locais e com Redis 7 cobrem ligação do driver, staging não suspensível, saturação, retry de append ambíguo, colisão de ID, movimentos/NPC/RNG, gaps, limites, sufixo após checkpoint e takeover. Isso ainda não conecta automaticamente o transporte ou scheduler de NPCs, não garante que todos os efeitos de um app entrem no batch e não valida crash em cada fronteira, volume/host, failover ou workload high.

**Gate de retenção concluído:** o append usa limite exato do stream e compara o número de eventos posteriores ao último checkpoint. Ao atingir `maximumEventsPerSession`, retorna `journalCapacityReached` sem remover eventos ainda necessários ao restore. Ao salvar checkpoint, o evento que define seu watermark é removido explicitamente; somente eventos estritamente posteriores ficam no journal, mantendo o limite de replay exato. A aplicação deve reagir com política de durable commit/backpressure; o manager best-effort não converte esse erro em confirmação durável. Redis real validou restore e saturação após liberar o prefixo coberto.

**Gate de lifecycle concluído:** `RedisGameStateRecoveryStore.stop()` espera uma inicialização de conexão já em andamento, impede nova inicialização durante o fechamento e compartilha a conclusão do fechamento do pool/event loop entre chamadas concorrentes. O teste de integração com Redis real exercita dois `stop()` simultâneos. Isso cobre lifecycle local; não cobre restart/failover do Redis nem aquisição de lease distribuído.

**Gate de leitura bounded concluído:** restore percorre o journal em páginas `XRANGE` de até 128 eventos e estima até 8 MiB por resposta, reduzindo o tamanho da página conforme `maximumRecordBytes` e `maximumRecoveryBytes`. Registro base64 e JSON decodificado são verificados contra o limite de record antes do decode; o snapshot também é limitado. Sessão nova sem checkpoint/sequence/journal continua válida, enquanto metadados parciais, journal sem snapshot, base64 inválido e snapshot grande falham fechado em vez de serem tratados como mundo vazio. Um teste com Redis real recupera 257 eventos em múltiplas páginas sem perder/duplicar sequência. Esse gate não valida restart/failover nem replay da lógica de jogo.

**Gate de checkpoint chunked concluído:** checkpoints acima de 256 KiB são divididos em strings Redis de no máximo 256 KiB, identificadas por digest SHA-256 do JSON original. O writer grava candidatos com TTL, então um script Lua verifica lease/epoch, revision, presença e byte count dos chunks antes de trocar o manifest e watermark; só depois remove chunks da geração anterior. Chunks candidatos de tentativas interrompidas expiram após uma hora. Restore busca no máximo 256 chunks em um `MGET`, valida tamanho/base64/digest e só então decodifica o checkpoint. O formato legado de valor base64 único continua aceito. Testes unitários cobrem limites e corrupção; Redis 7 real validou roundtrip chunked, substituição do checkpoint e compatibilidade com o fluxo single-value. Limite restante: `JSONEncoder` e base64 ainda são materializados antes da divisão, sob `maximumRecordBytes`; serialização incremental e aplicação do restore em lotes continuam pendentes.

## Objetivo

Adicionar uma integração opcional para salvar de forma assíncrona as transições autoritativas de estado do game server em Redis e recuperar a sessão se o processo do gameserver cair. O adapter precisa operar fora do tick de simulação, ter limites rígidos de memória e restaurar estado em sequência determinística.

O journal cobre **todas as mudanças autoritativas de estado que o servidor confirma**: mundo, movimento/transformações de entidades, NPCs, objetivos, inventário, progresso, RNG/seed, timers de gameplay e dados privados de jogador necessários à continuidade. Mudanças ocorridas no mesmo tick podem ser agrupadas num único delta/batch, mas só podem ser coalescidas se o replay restaurar exatamente o último estado confirmado e preservar eventos observáveis necessários ao domínio. Estado transitório de transporte (socket, fila de pacotes em trânsito) é reconstruído; presence derivada é recalculada. Tickets, bearer tokens, chaves e credenciais nunca são copiados para o backup.

## Módulo e dependências

- Produto SwiftPM implementado: `PearfyGameServerRedisRecovery`.
- Seleção opcional: depende do contrato `PearfyGameServer` e da biblioteca RediStack, sem acoplar `PearfyRedis` cache/broker.
- Não ativar automaticamente quando o app adiciona `gameserver` ou `redis`.
- Não usar `RedisCacheStore` para state journal: TTL/eviction de cache não é contrato de durabilidade.
- Não usar `RedisMessageBroker` como journal: sua semântica de entrega não substitui um log ordenado por sessão, checkpoint e restore.
- O módulo deve exigir Redis como serviço externo. Deve validar configuração e falhar na inicialização quando o backend ou nível de persistência requerido não estiver disponível.

## Dados e sequência

Definir contratos internos equivalentes a:

- `GameStateEvent`: `sessionID`, `sessionEpoch`, `sequence`, `eventID`, `schemaVersion`, instante lógico e payload codificado com tamanho máximo;
- `GameStateSnapshot`: `sessionID`, `sessionEpoch`, `throughSequence`, `schemaVersion`, tamanho/chunks e checksum;
- `GameStateJournal`: append idempotente com sequência esperada, ler após cursor, gravar snapshot e recuperar watermark;
- `GameStateRecoveryPolicy`: durabilidade, queue bounds, intervalo/eventos entre checkpoints, retenção e comportamento quando Redis falhar.

O append deve ser atomicamente ordenado por sessão/epoch. Uma reentrega com mesmo `eventID` não produz um segundo efeito. Um evento com sequência concorrente ou gap não deve ser aceito silenciosamente. Usar operação atômica Redis adequada (por exemplo script/server-side transaction conforme as capacidades do adapter implementado), com dedupe e compare de sequência; não implementar o protocolo apoiado em vários comandos que possam deixar estado parcial.

Formato recomendado:

1. Journal append-only de mudanças confirmadas, chaveado por sessão e epoch.
2. Snapshot versionado, gravado em chunks bounded quando o estado exceder o limite de payload único.
3. Watermark de snapshot que aponta até qual sequência o estado foi incluído.
4. Restore escolhe o último snapshot válido, verifica checksum/schema, então reproduz só o journal posterior e valida continuidade de sequência.
5. Apagar/truncar prefixo do journal somente após snapshot durável e watermark validado; respeitar retenção e política de recuperação.

Não persistir cópia completa do estado a cada frame: registrar deltas compactos para cada transição confirmada e snapshots completos em checkpoints. Não gravar comandos ainda não validados. Para movimento contínuo, cada tick de movimento que faça parte do estado confirmado precisa estar no delta ou ser reconstruível deterministicamente; o domínio documenta a regra, sem omitir silenciosamente alterações por custo de storage. O intervalo de checkpoints afeta o tempo de replay, não pode criar perda de eventos já confirmados.

## Async, commit e durabilidade

“Backup async” deve significar que I/O e encoding/chunking não bloqueiam o loop do jogo. Não significa que o gameserver pode confirmar uma mudança antes de salvá-la e ainda garantir recuperação integral.

### Política recomendada: `durableCommit`

O jogo valida o comando; o escritor assíncrono anexa evento ao Redis; só depois do append confirmado o evento entra na sequência comprometida e pode ser confirmado ao cliente/publicado como mudança irrevogável. O tick não aguarda socket/Redis: mudanças podem ser staged e commitadas no ponto seguro seguinte; se isso for incompatível com o ritmo do jogo, retornar estado de pending/retry em vez de mentir sucesso. Definir tempo máximo de confirmação e timeout.

Se Redis falhar em `durableCommit`, não aplicar/confirmar mutações duráveis. O jogo pode continuar apresentando estado anterior, pausar a sessão ou recusar inputs, conforme política do app; nunca aceitar silenciosamente estado não recoverable como persistido.

### Política opcional: `boundedAsyncWindow`

Pode confirmar mudança em memória antes de Redis para menor latência somente se o consumidor aceitar e configurar claramente um RPO não-zero, expresso como tempo máximo e/ou número máximo de eventos que podem ser perdidos num crash. O writer queue continua bounded e o status de durabilidade deve ser observável. Não usar essa política quando a exigência do jogo for recuperar toda ação já confirmada.

### O que “durável no Redis” exige

Redis não é backup por si só. O operador escolhe e documenta AOF/RDB, fsync, réplica, failover, backup externo, retenção, criptografia at-rest e restauração. O módulo expõe a política que requer e testa a configuração adotada; não afirma garantias maiores que o Redis/deployment oferece. Redis e PostgreSQL não compartilham transação no Pearfy; qualquer consistência cruzada exige um protocolo explícito adicional.

## Memory safety e perfil high

- Usar valores `Sendable` e ownership explícito no caminho de eventos; preferir `borrowing`/`consuming` quando elimina cópias comprovadamente.
- Fila do writer tem limites configurados de contagem e bytes. Serialização e payload têm tamanho máximo. Ao alcançar limite, backpressure é explícita.
- Snapshot usa serialização incremental/chunked; restore lê e aplica em lotes. Nunca materializar um world dump ilimitado mais fila ilimitada mais payload serializado ao mesmo tempo.
- Proibir ponteiros, slices ou buffers emprestados de sobreviverem à chamada/lifetime documentado. Se um encoder C for avaliado, isolá-lo por C ABI, contrato de allocator/lifetime/bounds, fuzz e sanitizers; sem ponteiro C na API pública Swift.
- Para FPS/MMO `high`, journal e checkpoint não rodam dentro do tick nem fazem bloquear o hot path em I/O. `durableCommit` usa staged command/commit e budgets; snapshot é trabalho de background com limites de CPU/bytes por ciclo.
- Sobrecarga de Redis, writer ou storage não pode crescer a memória nem impactar outras sessões sem limite. Definir admission control e política de degradar/recusar mutações antes do limite.

“Memory safe” aqui quer dizer memória bounded, lifetimes/ownership claros e ausência de acesso inválido; não elimina risco de OOM, bug de serialização, perda por configuração do Redis nem necessidade de benchmark.

## Recovery e concorrência

1. Na inicialização, chamar `acquireLease(sessionID:ownerID:durationMilliseconds:)` antes de aceitar comandos e renovar com margem antes da expiração. Append e checkpoint verificam atomicamente owner/epoch ativos; uma instância antiga não pode continuar gravando depois que outra assumiu autoridade. Lease perdido implica parar de aceitar mutações e recuperar/quarentenar a sessão antes de reabrir.
2. Carregar snapshot e journal sob limites máximos de eventos/bytes e deadline. Validar versão, checksum, sequência e referências de entidade.
3. Reaplicar eventos com handler determinístico/idempotente. Efeitos externos não são replayados; se houver side effects, usar eventos idempotentes/outbox implementado separadamente.
4. Recriar estado derivado e só então marcar a sessão pronta e admitir clientes.
5. Se restore falhar, manter sessão fechada ou quarantined para recuperação/inspeção; não criar mundo vazio silenciosamente sob o mesmo session ID.
6. Renovar fencing lease durante execução. Encerrar/graceful drain deve flushar eventos e snapshot dentro de deadline, mas recovery não depende de shutdown gracioso.

## Observabilidade sem vazamento

Medir lag do journal, último sequence durável, duração/bytes de snapshot, tamanho da fila, idade do evento mais antigo, recovery duration, replay count e falhas/retries. IDs podem ser redigidos/hashed conforme política do projeto. Nunca emitir payload de evento, snapshot, ticket, token, posição pessoal ou segredo no log.

Alertar quando:

- writer queue se aproxima dos limites;
- lag excede o RPO configurado;
- snapshot está atrasado ou inválido;
- recovery precisa replay acima do alvo;
- Redis rejeita gravações, perde lease ou volta de failover com dados abaixo do watermark esperado.

## CLI e configuração

`pearfy gameserver recovery --store redis` gera plano dry-run por padrão e, com `--apply`, seleciona o módulo opcional e grava configuração sem segredos. O schema 3 do template inclui cadência de checkpoint, política best-effort das projeções, contrato de durable command e os limites do tick writer/queue. `GameStateRecoveryCheckpointScheduler` implementa captura temporal genérica, mas a aplicação ainda deve conectar sua captura autoritativa e garantir que o watermark só cobre eventos persistidos. O CLI não cria credenciais nem garante RPO: a política de reducer/ack continua no domínio, e a durabilidade final depende da operação do Redis.

## Testes e aceite

- Teste unitário e Redis real para ordem, gap, duplicata, dedupe, schema versioning, saturação anterior ao checkpoint e retomada depois que um checkpoint libera capacidade.
- Teste de crash/restart real do processo em cada fronteira: antes/depois append, durante apply, durante snapshot e antes/depois ack.
- Teste Redis real com política de persistência de teste declarada; restart de Redis e gameserver, restore e replay.
- Teste de falha de rede, timeout, failover e lease split-brain/fencing.
- Teste de carga/saturação prova queue e bytes bounded, resposta previsível e recuperação pós-saturação.
- Teste high demonstra tick sem I/O bloqueante, restauração exata do último tick confirmado e contabiliza CPU/allocations/bytes adicionados pelo journal.
- Teste de compatibilidade de snapshot/evento entre versões do servidor e política de migração/quarantine para versões sem decoder.
- Teste de exclusão/retention garante que sessões expiradas e seus dados são removidos sem afetar sessão ativa.

Em 2026-10-07, o Guardian passou com Redis 7 e PostgreSQL 16 disponíveis e 320 testes aprovados; os testes Redis reais incluem durable tick batch, ponte fixed-step, checkpoint, sufixo do journal, takeover de epoch e lifecycle concorrente. A nova cobertura do driver fixed-step valida rate/work bounds, overrun detectado e ausência de burst de catch-up; não mede throughput nem garante o custo por tick. Permanecem pendentes crash em cada fronteira de commit/ack, restart/falha de host ou volume Redis, failover, retenção e workload high em hardware identificado. O produto continua `partial`: não afirmar que recupera todo o estado do jogo ou garante RPO zero. O middleware do manager é best-effort assíncrono; drops podem ocorrer em saturação e devem ser monitorados.

## Dependências e fontes locais

- [`docs/GAMESERVER.md`](../../docs/GAMESERVER.md) — tickets/session boundary e limite in-memory atual.
- [`Sources/PearfyGameServerRedisRecovery/RedisGameStateRecoveryStore.swift`](../../Sources/PearfyGameServerRedisRecovery/RedisGameStateRecoveryStore.swift) — adapter implementado e respectiva middleware.
- [`Sources/PearfyGameServer/GameServerStateManager.swift`](../../Sources/PearfyGameServer/GameServerStateManager.swift) — fila bounded e workers isolados.
- [`Sources/PearfyRedis/RedisCacheStore.swift`](../../Sources/PearfyRedis/RedisCacheStore.swift) e [`RedisMessageBroker.swift`](../../Sources/PearfyRedis/RedisMessageBroker.swift) — adapters que não substituem state journal.
- [Skill Pearfy Redis](../../.agents/skills/pearfy-redis/SKILL.md) — não confundir Redis persistence com transação/outbox ou exactly-once.
- [Skill Pearfy GameServer](../../.agents/skills/pearfy-gameserver/SKILL.md) — estado atual e limites do módulo.
