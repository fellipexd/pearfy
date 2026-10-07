# Roadmap de implementação dos módulos PearfyGameServer

**Status:** implementação parcial. A Fase 0 agora contém gRPC/TLS unary para controle e WSS/TLS para gameplay, ambos com autorização via callback, limites configuráveis e lifecycle. Os demais gates de produção permanecem planejados. Consulte o README desta pasta e o Module Registry para distinguir o que já existe. Contratos não citados no status parcial de um produto continuam planejados.

## Estado-base conhecido

`PearfyGameServer` fornece tickets HMAC vinculados a sessão/jogador/versão, managers bounded locais para room/commands/matchmaking/realtime/co-op/world e protocolos de estado. `PearfyGameServerGRPC` fornece métodos unary gRPC/TLS para o control plane; `PearfyGameServerTransport` fornece WSS/TLS e UDP server com datagrams autenticados/criptografados; `PearfyNetwork.SecureUDPTransport` no PearfyEngine agora implementa o codec cliente equivalente e compartilha vetor wire fixo entre repositórios. Ambos delegam autorização e regras de jogo à aplicação. `PearfyGameServerRedisRecovery` grava event stream/checkpoint via Redis e `PearfyGameServerDevKit` liga middleware assíncrono ao painel. Os managers de jogo e tickets continuam process-local; simulação de gênero, allocation, recovery multi-node, provisioning da chave pela aplicação e validação UDP de produção permanecem pendentes.

O produto Swift é modular. Cada novo módulo deve ter target/produto próprio, registro opcional, skill correspondente e dependências mínimas. Nomes abaixo são propostas sujeitas a revisão antes de se tornarem contratos públicos.

## Fase 0 — Transportes e conexão

### Módulo: `PearfyGameServerGRPC` (parcial)

**Objetivo:** oferecer o control plane unary versionado esperado por PearfyNetwork sem impor schema de jogo ou política de matchmaking.

**Implementado:** protos versionados `pearfy.matchmaking.v1` e `pearfy.game.v1` com `Matchmaking/FindGame`, `Matchmaking/CreateRoom`, `GameSession/Join` e `GameSession/Leave`; listener gRPC Swift 2 sobre TLS/ALPN; callback bearer obrigatório que produz um `GameSessionPrincipal`; dispatch assíncrono por método; limites de conexões, streams por conexão, payload e resposta; start/stop com drain.

**Limites:** payloads são `bytes` opacos e schema/regras são da aplicação. O módulo não cria tickets, matchmaking, salas ou sessão por conta própria. A API gRPC Swift 2 exige macOS 15+/iOS 18+; o POSIX transport é apropriado para dedicated servers Linux. A integração com a política real de ticket da aplicação deve ser validada pelo consumidor.

### Módulo: `PearfyGameServerTransport` (parcial)

**Objetivo:** fornecer adaptadores de servidor para conectar o contrato de sessão existente ao transporte real, sem misturar protocolo de jogo com listener.

**Escopo:**

**Implementado parcialmente:** além do listener WSS/TLS, o módulo fornece `GameServerUDPServer` com framing binário v1, ChaCha20-Poly1305, HKDF com chaves por direção/sessão, replay window de 64 pacotes, registry limitado, cap global rolling antes da AEAD para limitar custo de crypto e quota por sessão rolling aplicada somente após autenticação/replay, consumer serial sob backpressure e resposta não maior que o datagrama autenticado que a disparou. Pacotes inválidos com session ID conhecido não consomem quota da sessão; flood global ainda pode usar todo o cap de ingresso e descartar tráfego legítimo, então esses limites protegem recursos, não prometem disponibilidade sob demanda arbitrária. `PearfyNetwork.SecureUDPTransport` no PearfyEngine implementa a direção cliente com o mesmo contrato; um vetor binário compartilhado confirma compatibilidade do codec nos dois repositórios. `Integration/GameServerUDPInterop/run.sh` executa Join gRPC/TLS autenticado, entrega de chave por canal, roundtrip real com o cliente PearfyNetwork e burst com limites independentes por jogador. `GameServerUDPAdmissionManager` autentica ticket, gera segredo aleatório de 256 bits e registra o principal validado em canal independente por jogador. Deployment Agones e validação de abuso/capacidade em hardware alvo seguem pendentes; `udpEnabled` continua `false` no template high.

- abstração de listener/conexão e ciclo de vida start, drain, close;
- adapters de gameplay: WebSocket sobre TLS e UDP binário autenticado/criptografado; o módulo gRPC separado cobre operações de controle;
- validação de ticket e versão na admissão;
- limites configuráveis para frame, mensagens/segundo, clientes por listener, fila por conexão e tempo sem heartbeat;
- backpressure explícita, cancelamento, shutdown gracioso e instrumentação sem conteúdo de jogo ou credenciais;
- reconexão como nova admissão autenticada, com política de retomada definida por módulo/sessão.

**Fora do escopo:** simulação de jogo, matchmaking, store distribuído, negociação de chave e protocolo de um gênero específico.

**Dependências:** `PearfyGameServer`, módulo de segurança/HTTP apropriado e suporte de runtime Swift para listeners async.

**Aceite restante:** o codec nos dois repositórios rejeita pacote adulterado, replay e payload fora do limite e aceita reordenação apenas dentro da janela; a admissão já recusa tickets expirados/revogados antes de registrar codec. O harness local cobre Join TLS, entrega da chave e socket client/server. Seguem necessários deployment Agones e validação de flood/carga em cluster/hardware alvo; reconexão/perda deve ser exercitada no app; nenhum token/payload privado pode aparecer nos logs.

## Fase 1 — Rooms, lobbies e social de sessão

### Módulo proposto: `PearfyGameServerRooms`

**Objetivo:** lifecycle de salas de curta duração com participantes autorizados.

**Contratos candidatos:** `GameRoom`, `GameRoomID`, `GameRoomPolicy`, `GameRoomMembership`, `GamePresence`, `GameInvite`, `GameRoomStore`. Evitar exportar protocolo de transporte do provider.

**Escopo:** criação/descoberta/junção/saída, limites de capacidade, público/privado, dono/host, convites com expiração, presença online, heartbeat, disconnect temporário, reconexão e política de descarte. `GameRoomManager` oferece descoberta pública paginada sem IDs de membros; a autoridade e consistência ainda são process-local. O prazo de reconexão não é estendido por disconnect duplicado, e mutations/leitura/descoberta liberam membros expirados mesmo sem reaper. Estado efêmero deve ter bounds; sala persistente é responsabilidade de `World` ou store configurado.

**Friends/parties:** separar amizade persistente do agrupamento temporário. Party pode permanecer junta na fila, mas autorização para convidar/entrar deve ser feita no servidor. Não confundir presença efêmera com cadastro permanente de amigos/clãs.

**Aceite:** corrida entre joins respeita max capacity; convite é único, player-bound, expirável e preservado quando a sala está cheia; disconnect/reconnect respeita o prazo mesmo sem reaper prévio; auto-dispose só quando política permite. Teste de 1.000 rooms efêmeras passou; isso valida o limite funcional, não capacidade de produção ou throughput.

## Fase 2 — Jogos por comando, turnos e point-and-click

### Módulo opcional `PearfyGameServerTurnBased` (parcial)

**Objetivo:** oferecer um runtime de comandos validados e mudanças de estado determinísticas para partidas sem necessidade de atualização contínua em alta frequência.

**Modelo recomendado:** cliente envia intenção (`command`), nunca mutação direta do estado. O servidor autentica, valida turno/regras/versão, aplica o comando atomicamente e emite evento canônico com sequência monotônica. Repetições usam `commandID` idempotente. Snapshot + cursor de evento permitem retomar/reconstruir estado.

**Casos adequados:** apontar/clicar, interação com objetos, inventário e diálogo compartilhado, jogos de tabuleiro/cartas, estratégia por turnos e coop assíncrono. Animações podem ser disparadas por eventos/autoria do servidor, sem exigir tick de física.

**Persistência:** definir protocolos de store/event log e checkpoint sem fixar banco dentro do domínio. Se a escrita do evento e do estado exigirem atomicidade, usar transação/outbox conforme suporte já existente; declarar ordenação e política de recuperação. Replay de gameplay nunca deve reaplicar efeitos externos não idempotentes.

**Implementado parcialmente:** `GameTurnBasedSession` oferece reducer async, revisão esperada, limites de eventos/comandos/estado/histórico, append antes de publicar estado, replay que verifica cada estado e retry idempotente quando o store retorna o evento original após append ambíguo. `syncPage()` retorna snapshot e revisão; páginas posteriores usam cursor contíguo com limites de eventos/bytes e indicam `hasMore`. O consumidor deve aplicar a página inteira antes de avançar cursor, e a aplicação filtra o estado/payload por destinatário antes da serialização de rede. O contrato `GameTurnBasedCommandStore` exige compare-and-append transacional e dedupe pelo command ID vinculado a jogador e bytes exatos. O CLI registra `gameserver-turn-based` e a receita turn-based o inclui.

**Disponível parcialmente no core:** `GameCommandProcessor.checkpoint()` captura o estado e o histórico completo limitado; `GameCommandProcessor(replaying:from:reducer:)` reexecuta esse histórico no startup e rejeita gap de sequência, IDs repetidos, record fora do limite ou divergência do estado. A aplicação ainda deve persistir esse checkpoint completo e decidir atomicidade de commit/ack; Redis recovery genérico e snapshots projetados do state manager não se tornam automaticamente um event store transacional do processor.

**Aceite restante:** o adapter PostgreSQL concreto implementa compare-and-append, dedupe, checkpoint e serialização entre réplicas em transação. Em 2026-10-07, o teste de integração passou contra PostgreSQL 16 efêmero: migration, reopen/replay, retry duplicado, rejeição de ator obsoleto e corrida entre dois writers na mesma revisão. O adapter `PearfyGameServerTurnBasedRedis` agora compõe o journal Redis com o store de comandos sob lease/fencing, restaura checkpoint + sufixo contíguo e mantém o histórico completo limitado. Seus testes unitários cobrem reabertura e fencing; a integração com Redis real depende de `PEARFY_TEST_GAME_REDIS_HOST`. Permanecem reconexão após timeout com serviço real, política de efeitos externos via outbox e compactação incremental/arquivamento do histórico. O Guardian global pode marcar serviços externos como ausentes quando as variáveis `PEARFY_TEST_*` não estão configuradas. As páginas de sync são blocos server-side; autorização e projeção cliente por usuário continuam sob responsabilidade da aplicação.

## Fase 3 — Matchmaking e atribuição

### Módulo proposto: `PearfyGameServerMatchmaking`

**Objetivo:** implementar a fronteira deixada pelo protocolo `GameMatchmaking` sem forçar algoritmo ou banco no core.

**Disponível parcialmente:** `GameMatchmakingPlanner` compartilha a política determinística de party/skill-expansion entre adapters. O produto opcional `PearfyGameServerMatchmakingPostgres` fornece fila bounded entre réplicas, lock transacional por queue ID, unicidade de jogador/party enquanto queued, cancelamento, expiração somente antes de assignment e criação atômica de assignment persistido. O schema v2 mantém cursor por fila e gira a janela bounded de candidatos, em vez de consultar sempre o mesmo prefixo; dentro da janela, o planner considera tickets mais antigos primeiro e expande tolerância de skill com o tempo. Um teste PostgreSQL confirma que uma dupla compatível além do limite de candidatos é encontrada na chamada seguinte, mesmo que a primeira página não forme partidas. `reconcilePendingAssignments(maximumAssignments:ensureAssignment:)` passa uma quantidade limitada de assignments a um callback async fora da transação e só reconhece os bem-sucedidos; erro mantém a entrega pendente para retry pelo mesmo ID. Réplicas ainda podem executar o callback para o mesmo assignment, então o efeito externo precisa ser idempotente.

**Escopo restante:** a aplicação continua responsável por autenticar jogadores e validar modo/região/habilidade antes de enqueue. O adapter serializa por queue ID via advisory transaction lock, portanto é um control plane e não caminho de tick. A rotação evita starvation causada pelo limite de candidatos, mas fairness sob carga, integração concreta com room/instância, tratamento de timeout ambíguo do allocator e política de capacidade/retry permanecem responsabilidades da aplicação; a aplicação deve agendar `pruneHistory` para não acumular registros terminais.

**Não fazer:** confiar em rating/region enviados sem validação, criar partida antes de reservar idempotentemente os tickets, ou misturar match listing (salas já abertas) com matching de uma nova partida.

**Aceite:** um ticket não participa em dois matches; cancelamento concorrente e disconnect são coerentes; party é mantida junta ou recusada com motivo; critérios têm limites e expansão previsível; testes de fairness, carga, timeout e duas instâncias concorrentes.

## Fase 4 — Real-time autoritativo para FPS/ação

### Módulo proposto: `PearfyGameServerRealtime`

**Objetivo:** construir a base para jogo de alta frequência, em que o servidor decide estado, valida input e publica estado relevante.

**Perfil:** `high` para FPS e outros jogos de ação competitiva. Gameplay tem como alvo UDP/binário autenticado e criptografado; control plane pode usar gRPC/TLS. Usar os recursos de ownership do Swift nos tipos e APIs de hot path: `borrowing`/`consuming` quando reduzem cópias, buffers com ownership definido e tipos não copiáveis onde o modelo se beneficiar. Perfil high é um alvo de arquitetura, não a alegação de que ARC foi desligado ou que uma capacidade foi medida.

**Orçamento de overhead e overload:** o hot path não pode ganhar camadas genéricas, cópias, boxing, alocações transitórias, locks ou despacho dinâmico sem evidência de custo aceitável. Preferir buffers/filas limitados e reaproveitáveis, execução previsível e APIs que permitam ao compilador eliminar abstrações; só reter otimizações comprovadas por profiling. Definir capacidade máxima por sessão/zona e política de backpressure: descartar estado obsoleto quando seguro, reduzir frequência não crítica ou recusar novas entradas. Nunca deixar fila ou memória crescer sem limite, nem bloquear o tick à espera de I/O.

**Escopo inicial:** simulação fixed-step separada do executor de I/O; input com `clientSequence` e `serverTick`; validação de velocidade/alcance/estado; snapshots e delta state; interest management por célula/área; batching, limites de frequência, clock e métricas de jitter/atraso. O listener server e o codec AEAD/replay existem no módulo de transporte; o template só habilita UDP após chave/autorização e framing serem interoperáveis com PearfyNetwork.

**Disponível parcialmente no core:** `GameRealtimeSimulation` limita ingress global e por jogador em quantidade/bytes, valida sequência crescente e drena um número máximo de inputs por tick. `GameServerModeProfile` constrói essa fila com limites globais/per-jogador e cria o `GameRealtimeFixedStepDriver` usando a cadência e o teto de trabalho de cada template: 20Hz/128 inputs para light, 30Hz/1.024 para medium e 60Hz/8.192 para high. `makeRealtimeSimulation(initialTick:)` permite retomar o cursor do tick confirmado depois do restore. `GameRealtimeFixedStepDriver` avança o reducer síncrono da aplicação em cadência monotônica; quando o processamento alcança o próximo deadline, registra overrun e reancora o próximo deadline depois do trabalho, sem catch-up em burst. Três overruns consecutivos marcam o driver como sobrecarregado/falho, param o loop e fecham a admissão, preservando inputs pendentes para recuperação. Falha de tick ou do reducer também fecha a admissão. O app deve drenar ou recuperar a fila, chamar `resumeInputAdmission()` somente quando estiver vazia e criar outro driver. O handler não pode suspender nem executar I/O. Ao drenar inputs, o core libera referências aos payloads imediatamente; testes de pressão, callback lento, circuit breaker e perfil high validam limites, rejeição e ausência de rajada. Métricas têm cardinalidade fixa e contadores saturantes. Isso protege filas e falha fechado sob sobrecarga sustentada, mas não prova que o código da aplicação cabe no orçamento de CPU nem garante ausência de overload em hardware sem benchmark. Regras de gênero, validação de movimento, snapshots/deltas e integração automática com Redis seguem fora deste escopo.

**Produto opcional parcial:** `PearfyGameServerRealtime` indexa projeções de entidades em células inteiras e produz páginas AOI e deltas `upsert`/`remove` limitadas por raio, candidatos, quantidade e bytes. O delta reconcilia o estado visível atual contra uma lista capped de IDs anteriormente visíveis; o consumidor preserva a base e a lista original até aplicar todas as páginas. Um cursor inclui a revisão global do mundo; qualquer mutação invalida a continuação para evitar páginas inconsistentes. Isso não é um log de eventos de domínio, protocolo de transporte, simulação por gênero, persistência ou autoridade distribuída.

**Hot path em C, opcional:** só considerar após benchmark isolado localizar custo dominante e um protótipo mostrar ganho reprodutível no workload representativo. Manter lógica de jogo, autorização, lifecycle e APIs públicas em Swift; encapsular C atrás de target adapter com C ABI, tamanhos de buffer explícitos, regras de ownership/lifetime, nenhuma alocação liberada no allocator errado e nenhuma referência C escapando ao consumidor. Exigir testes de fuzz/limites, Thread Sanitizer/Address Sanitizer quando suportados, builds nas plataformas-alvo e comparação de latência p50/p95/p99, throughput e memória. Se o ganho não for significativo, manter implementação Swift.

**UDP seguro é gate obrigatório para transporte high:** servidor e cliente PearfyNetwork agora compartilham codec AEAD ChaCha20-Poly1305, chaves HKDF por direção/sessão, sequência autenticada, replay window e vetor binário fixo. O servidor também aplica MTU configurável, rate limiting, registry bounded e limita resposta ao tamanho do pedido. A admissão valida ticket e cria uma chave isolada por canal; ainda faltam entrega/rotação dessa chave pela aplicação, E2E de socket e validação de spoofing/flood/carga. Até esses gates passarem, manter `udpEnabled: false`.

**FPS e ação:** incluir ferramentas contra input impossível e divergência, não vender “anti-cheat completo”. Lag compensation/rewind é feature posterior, exige limites para janela histórica e teste de exploração.

**Integração parcial disponível:** `RedisDurableGameTickWriteAheadBridge` aceita `RedisDurableGameTickBatch` sincronamente e com limites de count/bytes no callback fixed-step, enquanto um único worker assíncrono executa o append/reducer e só chama `onDurableCommit` depois do ack. Falha ou saturação fecha o staging, mantém o batch pendente e exige rebuild do simulation a partir do cursor durável antes de reabrir. Testes verificam staging não suspensível, ligação direta ao driver, retomada de tick, saturação, retry idempotente e rejeição de ID reutilizado antes de publicar recibo antigo; Redis 7 real validou commit via ponte, checkpoint e restore. O app ainda codifica inputs em transições server-authored, inclui cada efeito confirmado e filtra/publica o estado no callback.

**Aceite restante:** teste de 60Hz sob atraso/perda/jitter artificiais; snapshots/deltas convergem; pacote inválido/replay/spam descartado; validar que a pressão de rede não bloqueia o tick; benchmark acima da capacidade confirma limites de fila/memória, política de backpressure e recuperação; benchmarks p95/p99 e memória com hardware/software identificados. O adapter de tick dá um append write-ahead por batch e reproduz movimentos, ações de NPC e RNG registrados, mas não captura ações automaticamente nem foi benchmarkado. Validar overhead do caminho de ownership contra baseline equivalente; medir qualquer núcleo C separado e integrado antes de mantê-lo.

## Fase 5 — Co-op por sessão / friendslop

### Módulo proposto: `PearfyGameServerCoopSession`

**Objetivo:** compor rooms, matchmaking e simulação autoritativa em partidas pequenas, cooperativas e com começo/fim definidos. O apelido de gênero “friendslop” fica nas receitas e exemplos; o módulo mantém um nome funcional e reaproveitável.

**Loop de referência:** lobby fechado → briefing/preparação → exploração/objetivos → escalada de ameaça → extração/derrota → resultado. Phasmophobia é exemplo de experiência: investigação cooperativa em locais, coleta de evidências/equipamentos, ameaças com comportamentos distintos e jogadores que podem cumprir papéis diferentes. Ela não é open source, portanto serve como referência de produto e não de implementação. Barotrauma tem código público e servidor multiplayer para estudar coordenação de tripulação, estado compartilhado, eventos e partidas co-op; seu EULA limita a redistribuição independente do jogo, por isso deve ser estudado como referência, não incorporado como código ou pacote.

**Escopo do módulo:**

- estados de sessão definidos pelo jogo via transições válidas e auditáveis;
- comandos de interação enviados pelo cliente e validados no servidor;
- objetivos com progresso, prerequisites e conclusão idempotente;
- eventos de ambiente/ameaça, seed de sessão e agenda de ações de NPC executados no backend;
- estado privado por jogador/role para evidências, pistas, inventário ou sensores, evitando enviar informação oculta a todos;
- reconexão com período de tolerância e retomada de snapshot autorizado; política explícita para abandono/host departure;
- limites de grupo, duração, frequência de input, entidades ativas e backlog de eventos;
- ganchos de observabilidade para tick, latência, progresso e desconexões, sem gravar payload privado.

**Composição:** depende de `Rooms` para party/lobby/capacidade, `Realtime` para estado e NPCs em movimento; pode usar `Matchmaking` para formar grupo aberto. O MVP pode usar WebSocket seguro. Não exige UDP, MMO/World, voice chat, procedural generation ou engine de IA; essas features são externas/opcionais.

**Primitiva disponível parcialmente no core:** `GameCoopSession` limita jogadores, objetivos e bytes agregados de estado público/privado. A janela de idempotência tem teto configurável, vincula o command ID ao jogador, objetivo, delta de progresso e digests dos estados, rejeita reuse conflitante e falha com `historyCapacityReached` sem mutar quando saturada. `objectivePrerequisites` aceita um grafo limitado a 16.384 arestas; a inicialização rejeita referências desconhecidas e ciclos. Metas positivas opcionais aplicam progresso monotônico e conclusão atômica ao atingir a meta, sempre após os pré-requisitos. A seed opcional fornece sequência SplitMix64 reproduzível; o snapshot de membro informa apenas o contador, sem vazar a seed. O scheduler de NPCs mantém ações opacas criadas pelo servidor em fila limitada por itens/bytes/histórico, ordena por tick/ID e drena no máximo o orçamento por chamada; finalizar a sessão descarta o backlog e enfileirar uma ação avança a revisão. `recoveryCheckpoint()` captura revisão + estado completo com encoding fora do actor; a restauração verifica bounds, grafo, progresso, dedupe, estado privado, seed/cursor e fila de ações. O módulo opcional `PearfyGameServerNPCLearn` usa decisões tipadas Jev fora do tick e converte a escolha em payload versionado `GameCoopScheduledNPCAction`, com fallback por baixa confiança/falha; a aplicação ainda valida IDs e executa as ações autoritativamente. `RedisGameServerStateMiddleware` faz checkpoints por número de projeções ou na primeira atualização após o intervalo configurado; um scheduler genérico também aceita captura periódica de estado com watermark do journal. `RedisDurableGameCoopSession` conecta lifecycle, objetivos, schedule, stage, acknowledgement NPC e decisões determinísticas seeded ao `RedisDurableGameCommandSession`, com idempotência por command ID, replay do reducer async e snapshots filtrados por jogador. `deterministicDecision(commandID:playerID:expectedRevision:)` exige jogador membro ativo e sessão seeded, persiste a intenção antes de derivar SplitMix64 da sequência confirmada; retry e replay retornam o mesmo valor. O `nextDeterministicValue()` direto permanece apenas em memória. Um teste de processo separado agora executa checkpoint + sufixo de comandos de co-op e outbox NPC não confirmado em Redis 7 com AOF `appendfsync always`, força `SIGKILL` no container e verifica takeover, replay, redelivery e acknowledgement idempotente. O teste AOF de dois processos cobre sobrevivência desse comando a reinício forçado do Redis. Isso não cobre perda de host/volume nem todas as fronteiras de crash. O produto opcional `PearfyGameServerThreatDirector` agora oferece scoring determinístico bounded, cooldown, hysteresis, dedupe de eventos e checkpoint; o app ainda possui sinais autoritativos, simulação e execução de ações. Ainda falta política de alocação/handoff e validação de crash/volume/hardware. Operações devem continuar fora do tick, e a aplicação ainda autentica retomadas e controla admissão após falha de lease/commit.

**Aceite:** backend controla ameaça, objetivos e resultado; cliente adulterando posição/objetivo não altera verdade do servidor; consumidores recebem somente campos permitidos para seu jogador; sequência repetida não conclui objetivo duas vezes; reconnect dentro da janela restaura sessão sem reset; expiração fecha a partida; testes reproduzíveis usam seed fixa e cobrem vitória, derrota, jogador ausente e restart/falha.

## Fase 6 — Mundo persistente e MMO

### Módulo proposto: `PearfyGameServerWorld` (parcial)

**Implementado parcialmente:** o produto opcional `PearfyGameServerWorldPostgres` fornece leases de zona PostgreSQL com epoch monotônico, mutações de entidade bounded e handoff transacional entre duas zonas com ambas as leases ativas. A aplicação deve renovar leases e parar mutações quando perder autoridade. Isso é autoridade/persistência no control plane, não simulação high.

**Perfil:** `high` obrigatório para a receita de MMO. Aplicar ownership orientado a throughput e latência ao update de entidades, interest management e serialização; conservar ARC ativo. Gameplay segue o transporte UDP/binário seguro do high; controle de sessão, matchmaking e alocação podem ficar em gRPC/TLS. Manter UDP desligado no template até o cliente e servidor oferecerem segurança interoperável.

**Orçamento de overhead e overload:** evitar alocação por entidade/tick, cópia de estado completo por jogador e fanout sem interesse; medir custo por entidade, zona e destinatário. Definir tetos para entidades ativas, filas, memória, trabalho por tick e conexões por zona. Ao atingir limite, aplicar admission control e backpressure observáveis, sem permitir que uma zona derrube o processo inteiro.

**Objetivo:** fornecer primitives para mundo persistente sem tentar reimplementar um engine de MMORPG inteiro.

**Escopo:** IDs e ownership de entidade; shards/zonas; interesse espacial e visibilidade; controle de autoridade por região; persistência/checkpoint; entrada/saída; transferência entre zonas com token/epoch de fencing; roteamento de presença; serviços de world lifecycle e recuperação. Persistência do estado durável precisa distinguir fonte de verdade, cache e projeções. O adapter PostgreSQL mantém bounds de zona/entidade/bytes e exige lease nos writes; interesse espacial, simulação, snapshot/delta, client handoff e recovery da zona permanecem pendentes.

**Não fazer na primeira versão:** mundo sem limite, autoridade distribuída por entidade sem fencing, replicação multi-region automática, economy/chat/social completo ou compatibilidade com protocolos proprietários de MMO.

**Aceite restante:** uma entidade tem autoridade única por epoch; handoff não perde/duplica comandos; zona recupera do último checkpoint e eventos posteriores; interesse não vaza entidades fora de política; testes de falha de processo, rejoin, migração e carga de entidades; benchmark high mede entidades ativas por zona, custo de tick, memória, serialização e fanout com hardware/software identificados; teste acima do limite confirma que filas e memória ficam bounded e que admissão/backpressure não espalham falha para outras zonas. Em 2026-10-07, os testes de lease/fencing, limites e transferência entre réplicas passaram contra PostgreSQL 16 local efêmero; crash/failover e workload high continuam não verificados. Avaliar C apenas pelos gates de hot path da Fase 4.

## Fase 7 — Hosting e orquestração de dedicated servers (parcial)

### Módulo proposto: `PearfyGameServerAgones`

**Status atual:** `PearfyGameServerAgones` integra o REST SDK local e o Allocator Service gRPC externo com mTLS, CA confiável, seleção/metadata limitadas, deadline e uma única tentativa. Deployment/configuração de Fleet, política de alocação regional, callbacks de cluster e teste em cluster real continuam como responsabilidades pendentes.

**Objetivo:** adaptador opcional que mapeia lifecycle/alocação Pearfy para Agones/Kubernetes.

**Escopo:** alocar um servidor pronto por seleção de labels/metadata, publicar assignment, marcar ready/allocated/shutdown, health checks e encerramento gracioso. Isolar tipos Kubernetes e SDK Agones fora dos protocolos centrais; o core deve funcionar sem Kubernetes. Uma alocação cujo resultado ficou ambíguo após deadline não é repetida automaticamente.

**Dependências:** `PearfyGameServerMatchmaking`, abstração de allocator e deployment Kubernetes do consumidor.

**Aceite restante:** integração em cluster de teste, falhas TLS/certificado inválido e timeout contra Agones real, política app-owned para reconciliar alocação ambígua, retorno de servidor à Fleet conforme estado, shutdown sem perder assignment e documentação local Docker versus Kubernetes.

## Fase 8 — Recuperação de estado com Redis

### Módulo opcional proposto: `PearfyGameServerRedisRecovery`

**Objetivo:** permitir que uma sessão autoritativa seja reconstituída após queda/restart do processo, lendo do Redis o último snapshot consistente e reaplicando os eventos posteriores.

**Dependências:** `PearfyGameServer` + `PearfyRedis`. Produto separado e opt-in. O atual `PearfyRedis` fornece cache e broker; o broker não deve ser tratado como journal de estado nem presumido como armazenamento durável. Este módulo precisa de protocolo de journal dedicado com sequência, deduplicação, ordenação, checkpoint e lifecycle de recovery.

**Contrato detalhado:** ver [`03-RECUPERACAO-REDIS.md`](03-RECUPERACAO-REDIS.md). Recovery persiste mudanças aceitas de estado de jogo e dados privados da sessão necessários à retomada; não persiste tickets, tokens de conexão, sockets, chaves de assinatura ou credenciais.

**Critério de durabilidade:** “assíncrono” descreve execução fora do loop de simulação, não promessa de persistência sem confirmação. O modo recomendado confirma uma mutação ao cliente somente após append durável/idempotente no journal. Um modo de confirmação antecipada pode existir apenas com RPO explícito em tempo/eventos e deve ser opt-in. A durabilidade após falha do processo depende também da configuração e operação do Redis; não anunciar crash recovery se a instância não satisfizer o nível de persistência configurado.

**Memory-safe e high:** journal queue e buffers são bounded; snapshots serializam em chunks; replay limita bytes/eventos por lote; ownership de valores e buffers é definido; não reter estado global duplicado na fila; backpressure age antes de exaurir memória. O caminho high não faz trabalho de rede nem serialização síncrona dentro do tick. Quando a fila satura ou Redis fica indisponível, seguir política explícita (suspender commit de ações duráveis ou rejeitar entrada), sem permitir crescimento ilimitado.

**Aceite:** crash em cada ponto entre append, apply, snapshot e ack recupera uma sequência válida sem perda/duplicação além do RPO escolhido; evento repetido é idempotente; restore aplica snapshot + sufixo do journal em ordem; schema incompatível falha fechado com diagnóstico redigido; duas instâncias não escrevem simultaneamente no mesmo session epoch; Redis indisponível/saturado não faz memória crescer nem confirma estado falsamente; testes incluem restart real do processo e Redis com persistência definida. Em 2026-10-07, um cenário real com dois processos de teste, Redis 7 em AOF `appendfsync always`, `SIGKILL` e restart validou recuperação de checkpoint + evento e takeover por epoch; as outras fronteiras de crash e falha de host/replica ainda não foram testadas.

## Fase 9 — Gerenciador assíncrono e painel de estado (parcial)

### Módulo opcional: `PearfyGameServerDevKit`

`GameServerStateManager.shared` oferece composição singleton, com instâncias isoladas disponíveis. O manager recebe projeções pequenas por mailboxes limitados por quantidade e bytes, atualiza uma visão atual limitada por quantidade/bytes e encaminha cada sink para um worker assíncrono independente. O publisher usa uma seção crítica curta em memória, sem suspender para Redis/SQL ou outro sink; saturação substitui estados pendentes mais antigos e é contabilizada. `stop()` fecha ingresso, drena os workers e aguarda `flush()`.

`PearfyGameServerDevKit.source(manager:merging:)` compõe os registros na fonte protegida do DevKit. O painel consulta páginas sob demanda, sem push realtime, e apresenta preview de até 1 KiB por estado. O operador continua sujeito à autenticação bearer do DevKit e as aplicações devem publicar projeções allowlisted.

**Limites:** snapshots são observabilidade do estado atual, não um log durável nem confirmação de commit. O atraso visível depende de filas e sinks; falhas são expostas por contadores sem payloads de erro. Não publicar tickets, segredos, requisições, dados pessoais, SQL bindings ou objetos de transporte.

## Fase 10 — Persistência PostgreSQL do estado projetado (parcial)

### Módulo opcional: `PearfyGameServerPostgres`

O adapter implementa `GameServerStateMiddleware` com upsert parametrizado por `(namespace, state_key)` e condição de revisão crescente. `PostgresGameServerStateMiddleware.migration()` fornece migration aditiva versionada, aplicada pelo `SQLMigrationRunner` da aplicação antes da inicialização. Lifecycle, pool e privilégios do banco permanecem sob controle da aplicação.

**Limites:** armazena o último estado por chave, não substitui o Redis journal/checkpoint, não grava cada tick/evento e não confirma persistência ao produtor. Configurar role de migração separada da role runtime; o trabalho de gravação permanece na fila assíncrona e pode falhar/substituir atualizações pendentes sob backpressure.

**Aceite atual:** migration usa identificador validado; valores SQL são binds; revisão antiga não substitui a nova; teste de integração real verifica migration, entrega via `GameServerStateManager` e leitura do estado persistido. Em 2026-10-07, os testes do GameServer/PostgreSQL passaram contra PostgreSQL 16 local efêmero. Permanecem pendentes testes de carga/falha e política operacional de retenção/backup do banco.

## Integração CLI e registry

- `pearfy gameserver recipe <turn-based|fps|friendslop|mmo|rooms|dedicated> [--output file]` now emits a Registry-module composition plan, ownership boundaries and remaining production gates. `fps`/`mmo` select `high`; these are plans, not implemented simulations, and high leaves UDP disabled.
- `pearfy gameserver modules` já lista o Registry atual, status e installabilidade. O status `partial` precisa permanecer explícito para produtos com integração ou gates de produção pendentes; a presença no Registry não certifica configuração ou operação.
- Recipes must remain aligned to actual Registry products. The `friendslop` plan composes current room/realtime/objective primitives and explicitly leaves NPC/threat simulation and hidden-state filtering to the application; no standalone `CoopSession` product exists yet.
- `pearfy gameserver recovery --store redis` agora gera plano dry-run por padrão; `--apply` seleciona `gameserver-redis-recovery` apenas em projeto gerenciado que resolva `gameserver` e `redis`, e grava configuração com limites, nomes de environment variables e política best-effort, sem credenciais. Não declara RPO garantido.
- Cada template deve conter protocolo, bounds, dependências e warnings seguros; não inserir chave secreta nem valor de benchmark não medido.
- `pearfy add gameserver-*` só deve ser permitido para produtos registrados como `implemented`.

## Gates de release

Para cada fase, rodar build e testes focalizados, integração do transporte real quando aplicável, testes de carga/falha correspondentes, compatibilidade de protocolo, `pearfy guardian verify` e inspeção do Module Registry. Reportar gates indisponíveis como INCOMPLETE; testes de ticket do módulo base não certificam listeners ou capacidade de produção.
