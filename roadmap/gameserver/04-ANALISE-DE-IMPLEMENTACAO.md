# Análise de implementação: referências open source para PearfyGameServer

**Consultado em:** 2026-10-06. Este documento analisa código/documentação públicos como referências técnicas. Não propõe adicionar esses projetos como dependências do Pearfy nem copiar código. Confirmar a licença do arquivo/versão antes de qualquer reutilização.

## Conclusão executiva

Não há um único projeto que seja o “melhor gameserver” para todos os gêneros. Os projetos mais úteis resolvem camadas diferentes:

- **SwiftNIO** é a referência mais direta para transporte server-side nativo Swift.
- **Colyseus** tem abstrações concretas de rooms, lifecycle e state sync.
- **Nakama** demonstra match handlers autoritativos, sessões realtime, party e matchmaking sem acoplar matcher a um gênero.
- **Open Match + Agones** mostra separação entre formação de match e alocação de processos dedicados.
- **ioquake3 + GameNetworkingSockets** ensina server tick, snapshots e transporte para FPS, cada um em camada distinta.
- **Space Station 14** é um bom código aberto para estudar sessões/rounds cooperativos com simulação de jogo e conteúdo server-authoritative; **Barotrauma** é um caso co-op multiplayer relevante, mas seu código público é regido por EULA restritiva, não deve ser tratado como dependência open source permissiva.
- **Veloren e TrinityCore** são estudos de mundo persistente/MMO, com diferenças grandes de linguagem, escala e licença.
- **Redis Streams** dá primitives de journal, porém não é por si só uma garantia de backup/failover sem política explícita de persistência e confirmação.

O desenho Pearfy mais coerente é compor contratos menores e manter a lógica de domínio em Swift. FPS e MMO usam `high`; o caminho Swift com ownership é a baseline, e C só entra em hot path medido. Transporte UDP/binário, durabilidade Redis e limites de overload são gates separados de implementação.

## Referências por módulo

### 1. `PearfyGameServerTransport`

**Código a estudar:**

- [SwiftNIO `NIOWebSocketServer`](https://github.com/apple/swift-nio/tree/main/Sources/NIOWebSocketServer) e [UDP echo server](https://github.com/apple/swift-nio/tree/main/Sources/NIOUDPEchoServer) como exemplos de I/O server-side Swift.
- [SwiftNIO examples README](https://github.com/apple/swift-nio-examples) documenta aplicações pequenas e Apache-2.0.
- [Valve GameNetworkingSockets README](https://github.com/ValveSoftware/GameNetworkingSockets) e [API `ISteamNetworkingSockets`](https://github.com/ValveSoftware/GameNetworkingSockets/blob/master/include/steam/isteamnetworkingsockets.h).

**Lições para Pearfy:** fazer listener e codec adapters independentes do estado de jogo; validar tamanhos antes de alocar/decodificar; usar limites de frame, conexões, fila de saída, frequência e timeout; separar gRPC/TLS para control plane de gameplay UDP; tratar canal confiável e não confiável separadamente.

**Risco/decisão:** UDP echo só demonstra I/O, não criptografia. GameNetworkingSockets oferece transporte orientado a mensagens, mas a API pública é C++/interface virtual, não uma C ABI pronta. Se for adotado do Swift, comparar Swift C++ interop versus um shim C estreito; validar licença, integração de build e plataformas. Não escrever implementação própria de criptografia nem considerar UDP pronto porque o preset `high` o nomeia.

**Recomendação:** começar por adapters SwiftNIO para TLS WebSocket e lifecycle; prototipar a camada UDP segura de high isoladamente antes de estabilizar contrato público.

**Revalidação de transporte (2026-10):** [SwiftNIO QUIC](https://github.com/apple/swift-nio-quic) já expõe suporte a QUIC DATAGRAM, mas continua em desenvolvimento ativo, requer Swift 6.3+, macOS 26+ ou Linux, e declara API instável. A issue upstream ainda lista mTLS como trabalho aberto. O package raiz Pearfy continua em Swift tools 6.2 e o PearfyEngine suporta iOS 16/macOS 13; adotar essa dependência agora elevaria requisitos incompatíveis com os produtos existentes e não resolveria autenticação mTLS interoperável do cliente. [Network.framework](https://developer.apple.com/documentation/network/nwprotocolquic) pode atender endpoints Apple, mas não é implementação para o dedicated server Linux.

[Valve GameNetworkingSockets](https://github.com/ValveSoftware/GameNetworkingSockets) continua sendo referência de transporte de jogo: API message-oriented, mensagens reliable/unreliable, criptografia AES-GCM-256 e troca Curve25519; o upstream fornece também uma interface C. Isso não substitui identidade autenticada: criptografia sem certificado ou segredo out-of-band não impede man-in-the-middle. O build C++ depende de CMake e dependências nativas como OpenSSL/protobuf; não há produto SwiftPM oficial. Decisão atual: usar o codec AEAD Swift pareado entre PearfyGameServerTransport e PearfyNetwork, evitando adicionar C++ sem evidência de profiling. UDP permanece desligado até a app autenticar/provisionar a chave, os sockets passarem E2E e limites de abuso/overload serem exercitados.

### 2. `PearfyGameServerRooms` e presença

**Código a estudar:**

- [Colyseus `Room.ts`](https://github.com/colyseus/colyseus/blob/master/packages/core/src/Room.ts) para criação, join/leave, reconexão, timer/update e disposição.
- [Colyseus `MatchMaker.ts`](https://github.com/colyseus/colyseus/blob/master/packages/core/src/MatchMaker.ts) para room listing, seat reservation, escolha de processo, retries e prevenção de criação duplicada.
- [Nakama `party_registry.go`](https://github.com/heroiclabs/nakama/blob/master/server/party_registry.go) e [party docs](https://heroiclabs.com/docs/nakama/concepts/parties/) para grupos temporários distintos de grupos persistentes.

**Lições para Pearfy:** tratar room como unidade com capacidade finita e owner/epoch; reservar lugares antes de permitir join; lifecycle explícito created → authenticated → joined → dropped/reconnected → left → disposed; separar listagem de rooms de fila matchmaking; parties devem sobreviver em fila como grupo indivisível segundo policy.

**Adaptação:** drivers distribuídos de presença/cache do Colyseus são detalhes do seu stack. Pearfy deve definir protocolos `GameRoomStore`/`PresenceStore` bounded e providers opt-in, sem exportar objetos de framework externo.

### 3. `PearfyGameServerTurnBased` / point-and-click

**Código/padrões a estudar:**

- [Nakama server-authoritative matches](https://heroiclabs.com/docs/nakama/concepts/multiplayer/server-authoritative/) e [sample Go runtime](https://github.com/heroiclabs/nakama/tree/master/sample_go_module) demonstram handler de partida com estado, join, leave, mensagem, tick e saída.
- [Battle for Wesnoth multiplayer server](https://wiki.wesnoth.org/Multiplayerservers) mostra um servidor/lobby para jogo multiplayer por turnos.
- O guia do Nakama também descreve turnos ativos e passivos, incluindo partidas que persistem entre sessões: [authoritative multiplayer source docs](https://github.com/heroiclabs/nakama-docs/blob/master/docs/nakama/concepts/server-authoritative-multiplayer.md). Esse repositório de docs está arquivado; tratar o exemplo como desenho histórico e validar conceitos, não como API atual.

**Lições para Pearfy:** comandos semânticos versionados, sequência monotônica, `commandID` idempotente, validação de turno e autorização no servidor, mudança de estado determinística, log de eventos/checkpoint e replay. Para point-and-click, enviar `interact(objectID)` ou `choose(dialogueOption)` é melhor que aceitar mutação arbitrária de estado enviada pelo cliente.

**Recomendação:** command/event core sem transporte obrigatório. Um jogo offline deve continuar tendo domínio local; multiplayer envia intenção ao servidor, que responde eventos autorizados e snapshots de recuperação.

### 4. `PearfyGameServerMatchmaking`

**Código a estudar:**

- [Open Match Director demo](https://github.com/googleforgames/open-match/blob/main/examples/demo/components/director/director.go), [Open Match source](https://github.com/googleforgames/open-match) e [matchmaker guide](https://open-match.dev/site/docs/guides/matchmaker/).
- [Nakama match handler](https://github.com/heroiclabs/nakama/blob/master/server/match_handler.go), [match registry](https://github.com/heroiclabs/nakama/blob/master/server/match_registry.go) e [matchmaker docs](https://heroiclabs.com/docs/nakama/concepts/multiplayer/matchmaker/).
- [Colyseus `MatchMaker.ts`](https://github.com/colyseus/colyseus/blob/master/packages/core/src/MatchMaker.ts) para joinOrCreate, reservation/idempotência e seleção de processo.

**Lições para Pearfy:** fila usa ticket autenticado e cancelável; ticket guarda critérios explícitos, expiração e party; evaluator determina combinação e fairness; Director pede allocation somente após compor o match; players recebem assignment/offer e ainda precisam entrar; usar claim/lease/dedupe distribuído para não consumir ticket duas vezes.

**Evitar:** formar match dentro do hot path de simulação; considerar um match encontrado como jogador já conectado; expor propriedades privadas do ticket; manter filas exclusivamente em memória ao declarar operação multi-réplica.

### 5. `PearfyGameServerRealtime` — FPS, perfil `high`

**Código a estudar:**

- [ioquake3 `sv_main.c`](https://github.com/ioquake/ioq3/blob/main/code/server/sv_main.c) para servidor dedicado, rate limiting, heartbeat, timeout e contenção de overflow.
- [ioquake3 `sv_snapshot.c`](https://github.com/ioquake/ioq3/blob/main/code/server/sv_snapshot.c) para snapshots; [server protocol declarations](https://github.com/ioquake/ioq3/blob/main/code/qcommon/qcommon.h) distingue snapshots e mensagens confiáveis.
- [Valve GameNetworkingSockets](https://github.com/ValveSoftware/GameNetworkingSockets) para transporte message-oriented e modos reliable/unreliable sobre datagramas.
- [Nakama match handler](https://github.com/heroiclabs/nakama/blob/master/server/match_handler.go) para filas limitadas de mensagens deferred e lifecycle de match autoritativo.

**Lições para Pearfy:** separar input, estado simulado e snapshot; sequenciar inputs por cliente e tick de servidor; calcular o estado no servidor; filtrar destinatários por interesse; limitar reliable command queue e datagrams/s; estado não confiável pode coalescer posições antigas, mas eventos autoritativos confiáveis precisam de ordenação/deduplicação.

**Ownership/C:** desenhar primeiro uma pipeline Swift de valores/buffers com `borrowing`/`consuming`, sem boxing/cópias não medidas no hot path; não adicionar abstrações com overhead sem benchmark. Se profiling justificar C, atravessar a fronteira em batches (ex.: encode/compact delta), não em chamadas por entidade; deixar regra/segurança/lifecycle em Swift, usar C ABI com tamanhos e allocator definidos, wrap seguro e sanitizers. GNS é C++; isso pode requerer C++ interop ou shim.

**Licença:** ioquake3 deriva do código GPLv2-or-later; estudar comportamento, sem copiar trechos para Pearfy sem análise legal/licença. Jogo e protocolo são referência de gênero, não biblioteca Swift.

### 6. `PearfyGameServerCoopSession` — friendslop/co-op horror

**Código open source prioritário:**

- [Space Station 14 (MIT)](https://github.com/space-wizards/space-station-14) para round lifecycle, entidades, conteúdo que roda server/client e estado de sessão compartilhado; seu foco é multiplayer de rounds e relações sociais/sigilo, não simulação específica de investigação paranormal.
- [Space Station 14 GameMapManager](https://github.com/space-wizards/space-station-14/blob/master/Content.Server/Maps/GameMapManager.cs) como ponto de entrada para gerenciamento server-side de mapa; estudar junto com engine/conteúdo, não portar o manager isolado.
- [Barotrauma server `GameServer.cs`](https://github.com/FakeFishGames/Barotrauma/blob/master/Barotrauma/BarotraumaServer/ServerSource/Networking/GameServer.cs) e [GameMain.cs](https://github.com/FakeFishGames/Barotrauma/blob/master/Barotrauma/BarotraumaServer/ServerSource/GameMain.cs) para lifecycle dedicado, reconnecting clients, input e simulação coop.
- [Phasmophobia official description](https://www.playstation.com/en-us/games/phasmophobia/) como exemplo de experiência de quatro jogadores, investigação, evidência e equipamentos; é referência de produto, não projeto de código aberto.

**Lições para Pearfy:** fase de missão explícita; estado de objetivo versionado; threat director/NPC controlados pelo servidor; dados por jogador/role separados antes de montar payload; reconnect grace window; vitória/derrota/extraction idempotentes; seed para reprodução de testes; limites de NPCs, rooms, duração e eventos. Voice/spatial audio são um serviço separado.

**Cuidado de licença:** Barotrauma publica source code, mas seu FAQ/EULA restringe distribuição standalone. Não é referência de código permissivamente reutilizável. Preferir SS14 para padrões realmente open source, e estudar Barotrauma sem incorporar/copiar código; conferir EULA vigente.

### 7. `PearfyGameServerWorld` — MMO, perfil `high`

**Código a estudar:**

- [Veloren repository](https://github.com/veloren/veloren), em particular [terrain persistence versioning](https://github.com/veloren/veloren/blob/master/server/src/terrain_persistence.rs) e [character persistence conversions](https://github.com/veloren/veloren/blob/master/server/src/persistence/character/conversions.rs), como exemplos Rust de ECS/world + dados persistentes versionados.
- [TrinityCore WorldUpdateLoop](https://github.com/TrinityCore/TrinityCore/blob/master/src/server/worldserver/Main.cpp) e [worldserver configuration](https://github.com/TrinityCore/TrinityCore/blob/master/src/server/worldserver/worldserver.conf.dist) para loop de mundo, threads de mapas, tempos/configuração operacional e salvamento.
- [Space Station 14 NetEntity separation discussion](https://github.com/space-wizards/space-station-14/discussions/19986) exemplifica que IDs locais de entidade não devem ser enviados diretamente como IDs de rede.

**Lições para Pearfy:** IDs de rede explícitos separados de handles locais; autoridade single-writer por shard/zone e fencing epoch; simulação e persistência desacopladas; salvar dados por unidade de domínio; schema de snapshot versionado e conversores legados; interest management e custos de fanout medidos.

**Licença/adequação:** TrinityCore é framework completo GPL-2.0 e inspirado em um MMO específico; útil para observar mapa/world loop e operação, não como base de código Pearfy. Veloren é Rust e é mais útil para estudar ECS/persistence, mas seu layout/licença são do projeto e precisam de revisão. Não concluir que copiar uma arquitetura de MMO clássico resolve necessidades de qualquer jogo.

### 8. `PearfyGameServerAgones`

**Código a estudar:**

- [Agones SDK server `Ready`/`Allocate`/`Shutdown`](https://github.com/agones-dev/agones/blob/main/pkg/sdkserver/sdkserver.go) para lifecycle assíncrono e fila de mudanças de estado do GameServer.
- [Agones system diagram](https://github.com/agones-dev/agones/blob/main/site/content/en/docs/Advanced/system-diagram.md) para separar Allocator, SDK sidecar e Dedicated Game Server.
- [Open Match + Agones global demo](https://github.com/googleforgames/global-multiplayer-demo) para fluxo Director → alocação regional.

**Lições para Pearfy:** adapter para allocator, readiness, health e shutdown; Agones aloca processos/fleets, não decide regras nem state replication. O adapter fica no produto opcional e core funciona sem Kubernetes.

### 9. `PearfyGameServerRedisRecovery`

**Código e especificações a estudar:**

- [Redis Streams docs](https://redis.io/docs/latest/develop/data-types/streams/) e [XADD semantics](https://redis.io/docs/latest/commands/xadd/) para append log, cursors, read e trim.
- [Redis persistence docs](https://redis.io/docs/latest/management/persistence/) para RDB/AOF; [Streams message safety section](https://redis.io/docs/latest/develop/data-types/streams/) explica persistência/replicação assíncronas, requisito de fsync forte quando persistência importa e que failover não garante promoção da réplica mais atual.
- [Redis `t_stream.c`](https://github.com/redis/redis/blob/unstable/src/t_stream.c) e [AOF stream rewrite](https://github.com/redis/redis/blob/unstable/src/aof.c) para ver implementação nativa, não para duplicá-la em Pearfy.
- Base local: [Pearfy `RedisCacheStore`](../../Sources/PearfyRedis/RedisCacheStore.swift), [RedisMessageBroker](../../Sources/PearfyRedis/RedisMessageBroker.swift) e [recovery design](03-RECUPERACAO-REDIS.md).

**Lições para Pearfy:** journal por sessão/epoch com sequência lógica e dedupe independente do stream timestamp; snapshots com watermark/schema/checksum; replay bounded; trims só depois de snapshot confirmado; lease/fencing; AOF/RDB/replica e backup são operação do Redis. Redis Streams não devem ser presumidos como durable ack cross-failover; definir se confirmação ao cliente espera Redis e qual RPO o modo assíncrono permite.

**Adaptação high:** capturar todos os deltas autoritativos que foram confirmados, em batches por tick; manter writer queue bounded e processamento fora do tick. Batch async reduz chamada por evento, mas durableCommit pode elevar latência; medir e definir capacidade em vez de esconder esse custo. Não persistir sockets/tickets/credentials.

## Recomendações de implementação Pearfy derivadas da pesquisa

1. Fazer `Transport` em SwiftNIO com WebSocket TLS primeiro; manter o contrato transport-neutral.
2. Entregar `Rooms` e `TurnBased` sem exigir stack Kubernetes/Redis; suportar stores locais testáveis e adapters opcionais.
3. Definir `Matchmaking` como serviço separado e store/claim distribuído; Open Match é modelo de boundaries, não biblioteca para incorporar por padrão.
4. Para `high`, estabelecer benchmark do tick e do codec Swift ownership-first; implementar UDP binário seguro como adapter isolado. C somente por decisão de profiling e teste comparativo.
5. Construir `CoopSession` sobre Rooms + Realtime, usando state visibility server-side e lifecycle de missão. SS14 é a referência permissiva principal; validar legalmente qualquer estudo de Barotrauma.
6. Começar MMO com autoridade zone/shard e versão/fencing; testar persistência/migração antes de interesse multi-node complexo. Não iniciar com microservices globais.
7. Fazer recovery Redis como produto independente; modelar append, snapshots, replay e durabilidade antes da CLI. Não reutilizar CacheStore ou MessageBroker como persistência implícita.
8. Em todos os módulos: teste concorrente/fault injection, limites de memória, backpressure, reconexão, observabilidade redigida, migrações de protocolo e gate `pearfy guardian verify`.

## Referências adicionais

- [Swift ownership: borrowing/consuming](https://docs.swift.org/latest/documentation/the-swift-programming-language/declarations/).
- [Swift safe C/C++ interoperability](https://www.swift.org/documentation/cxx-interop/safe-interop/); a documentação descreve APIs de C++ interop como uma área em evolução.
- [Agones official docs](https://www.agones.dev/site/docs/) e [Open Match official docs](https://open-match.dev/site/docs/).
- [Barotrauma FAQ sobre source code e EULA](https://barotraumagame.com/ufaqs/public-source-code/).
