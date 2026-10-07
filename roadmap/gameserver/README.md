# Pearfy GameServer: roadmap de módulos

**Status:** implementação parcial. `PearfyGameServer`, `PearfyGameServerGRPC`, `PearfyGameServerTransport`, `PearfyGameServerRedisRecovery`, `PearfyGameServerPostgres`, `PearfyGameServerWorldPostgres`, `PearfyGameServerDevKit`, `PearfyGameServerNPCLearn`, `PearfyGameServerThreatDirector`, `PearfyGameServerTurnBased` e `PearfyGameServerTurnBasedPostgres` já têm produtos/APIs registradas. Os itens marcados como não disponíveis continuam no roadmap e não devem ser tratados como funcionais.

Este diretório descreve a evolução modular do `PearfyGameServer`. O estado executável inclui o produto opcional bounded de threat director, tickets HMAC, manager in-process de rooms, command reducer com sequência/idempotência, matchmaking local e fila PostgreSQL entre réplicas, buffers bounded de realtime, páginas AOI com índice espacial local, estado básico de co-op, registry local de zonas/entidades, leases e entity handoff PostgreSQL para world zones, manager assíncrono de estado, adapter Redis Streams/checkpoints, staging síncrono bounded de batches de tick com writer Redis assíncrono, integração paginada com DevKit, listener gRPC/TLS de controle, WSS/TLS, listener UDP server e codec UDP cliente PearfyNetwork com AEAD/replay/rate bounds e vetor de interoperabilidade compartilhado. Isso **não** equivale a simulação de gênero, MMO completo, captura automática de todos os efeitos da aplicação, key provisioning de aplicação ou UDP validado em produção. Confira [`docs/GAMESERVER.md`](../../docs/GAMESERVER.md), o Module Registry e as skills antes de tratar qualquer capacidade como produção.

**Validação mais recente em 2026-10-07:** o Registry contém 47 entradas de catálogo e 34 Skills canônicos, e `pearfy ai sync` concluiu sem instalar, atualizar ou remover Skills. `pearfy guardian verify` passou build, 320 testes e o gate `integration-environment`, com Redis 7 e PostgreSQL 16 configurados. A suíte exercitou os adapters de game server contra serviços locais; o PostgreSQL verifica rotação bounded de candidatos e redelivery idempotente de assignments, e os testes do Redis incluem durable tick batches, a ponte fixed-step síncrona com writer assíncrono, checkpoint, replay de sufixo e takeover de epoch. Os testes do driver fixed-step cobrem limites de taxa/trabalho, overrun sustentado com admissão fechada, falha fechada do reducer, ausência de rajada de catch-up e limites do perfil high. Isso verifica contratos e integrações locais, não disponibilidade/capacidade de produção: continuam sem validação as fronteiras de crash/ack, perda de host ou volume, failover, cluster Agones, benchmark e sobrecarga em hardware-alvo, integração de jogo real e provisioning da chave UDP.

## Princípio de arquitetura

Não criar um servidor diferente para cada gênero. Criar capacidades pequenas, que possam ser compostas, e oferecer perfis/receitas para os gêneros:

- **Point-and-click / aventura / turn-based:** comandos validados, eventos autoritativos, turnos ou ações assíncronas e persistência/replay.
- **FPS / ação competitiva:** simulação autoritativa de passo fixo, validação de input, snapshots/deltas, relevância espacial e transporte de baixa latência com proteção criptográfica.
- **MMO / mundo persistente:** autoridade por shard/zona, entidades e interesse espacial, persistência, presença e migração controlada de autoridade.
- **Friendslop / co-op horror de sessão:** grupo pequeno, partida fechada, objetivos cooperativos, exploração, NPCs/ameaças autoritativas, informação parcialmente oculta e resultado/extração.
- **Friends, parties, lobbies e rooms:** presença, convites, composição de party, descoberta e ciclo de vida de salas; capacidade social reutilizada pelo friendslop, mas não é o gênero.
- **Matchmaking:** filas, tickets, critérios, formação de partidas, cancelamento e atribuição de servidor.
- **Dedicated server hosting:** integração opcional com orquestradores; não é parte do runtime de simulação.

“Friendslop” foi esclarecido pelo usuário como o gênero de co-op limitado em sessões, como Phasmophobia. Neste roadmap ele é tratado como uma receita de co-op horror; friends/party/lobby permanecem uma capacidade de plataforma separada.

Os modos CLI `light`, `medium` e `high` continuam sendo presets de arquitetura e limites iniciais. **FPS e MMO pertencem à categoria `high`**: usam ownership explícito e caminhos de desempenho do Swift; o destino de gameplay é UDP/binário e o control plane pode usar gRPC/TLS. O runtime Swift usa ARC; ownership não desliga um garbage collector. `GameServerUDPAdmissionManager` autentica tickets, gera uma chave aleatória por canal e registra o principal validado. O harness `Integration/GameServerUDPInterop/run.sh` já valida o join TLS que entrega a chave e o socket real PearfyNetwork→Pearfy. O template mantém UDP desabilitado enquanto faltarem deployment Agones e validação de abuso/capacidade no hardware alvo. Um núcleo C pode ser avaliado para hot paths específicos, mas só entra após benchmark demonstrar ganho e com uma fronteira C ABI pequena, bounds/lifetimes explícitos e API pública segura em Swift. O caminho `high` não deve adicionar overhead não medido nem permitir sobrecarga sem limites: medir contra baseline, limitar filas/memória/ticks e degradar ou rejeitar carga de forma explícita. Perfis não são garantias de capacidade sem benchmark.

## Roadmap

| Ordem | Módulo proposto | Capacidades centrais | Receitas iniciais |
| --- | --- | --- | --- |
| 0a | `PearfyGameServerGRPC` | **parcial:** control plane gRPC/TLS unary com protobuf versionado, bearer authorization callback, limites de conexões/streams/payload e drain | FindGame, CreateRoom, Join, Leave |
| 0b | `PearfyGameServerTransport` | **parcial:** WSS/TLS e UDP com ChaCha20-Poly1305, HKDF direcional, anti-replay, limites de registry/rate/buffer, resposta limitada e admissão por ticket; harness local cobre TLS gRPC Join, entrega da chave, socket real PearfyNetwork→Pearfy e burst com quotas por jogador; deployment e benchmark de produção pendentes | WSS/JSON; UDP high continua desativado no template |
| 1 | `PearfyGameServer` rooms | **parcial:** rooms locais, capacity, convite privado e grace de reconexão | coop casual, friends/lobbies, sessões privadas |
| 2 | `PearfyGameServerTurnBased` + `PearfyGameServerTurnBasedPostgres` opcional | **parcial:** reducer async, append-before-publish e store PostgreSQL transacional com replay/concorrência testados | point-and-click, estratégia, board/card games |
| 3 | `PearfyGameServer` matchmaking | **parcial:** queue local, party indivisível, filtros mode/região/skill e cancelamento | ranked/casual, party queue, room browser |
| 4 | `PearfyGameServer` realtime | **primitivas parciais:** fila limitada, sequence e drain; driver monotônico com teto por tick e sem catch-up burst; sem regras/physics ou transporte integrado | FPS e ação competitiva |
| 4a | `PearfyGameServerRealtime` | **parcial:** índice espacial bounded, páginas AOI e deltas `upsert`/`remove` com base no conjunto visível anterior; páginas limitadas e inválidas após mutação; sem protocolo de transporte nem autoridade distribuída | snapshots e reconciliação incremental de entidades visíveis em zonas locais |
| 5 | `PearfyGameServer` coop | **primitivas:** lifecycle simples, objetivos idempotentes e estado privado por jogador | friendslop, co-op horror/PvE por sessão |
| 6 | `PearfyGameServer` world + `PearfyGameServerWorldPostgres` | **parcial:** registry local mais leases PostgreSQL cross-replica, fencing e entity handoff com limites; sem simulação, interest management ou recuperação de zona | MMO, perfil high obrigatório |
| 7 | `PearfyGameServerAgones` | **parcial:** SDK REST local mais cliente Agones Allocator gRPC com mTLS, timeout, limites e alocação single-attempt; sem deployment de Fleet ou teste em cluster | lifecycle e alocação de processos dedicados Agones |
| 8 | `PearfyGameServerRedisRecovery` | **parcial:** Redis Streams, checkpoints limitados, fencing e restore de registros | recuperação de estado após restart, em qualquer perfil |
| 9 | `PearfyGameServerDevKit` | **parcial:** manager singleton/instanciável, middleware assíncrono bounded e viewer bearer-protected | inspeção de estado |
| 10 | `PearfyGameServerPostgres` | **parcial:** middleware assíncrono com upsert por revisão e migration versionada | persistência do estado projetado mais recente |

Receitas `fps` e `mmo` selecionam o perfil `high` (gRPC/TLS para controle + UDP/binário seguro para gameplay quando habilitado); `fps` compõe `Realtime`, enquanto `mmo` compõe `Realtime` e `World`. `friendslop` combina `Rooms`, `Matchmaking` opcional, `Realtime` e `CoopSession`; seu alvo inicial é sessão segura em medium, sem impedir uma configuração high para cargas maiores.

Cada produto opcional aparece no Module Registry somente com status fiel ao código. A ordem é de dependência; os componentes não alegam capacidade de produção. Matchmaking, turn-based command storage e world zone/entity state têm adapters PostgreSQL parciais, enquanto rooms, presença, simulação e recovery do mundo seguem locais ou pendentes. Faltam deployment e validação em cluster Agones, benchmark em hardware alvo e simulação com jogo real. O harness local já integra o Join gRPC/TLS autenticado, entrega a chave da admissão e roundtrip UDP com o cliente PearfyNetwork; a aplicação ainda precisa aplicar sua própria política de ticket e regras autoritativas. A ponte de ticks cobre o staging não suspensível e o commit assíncrono, mas depende do app para converter inputs em transições autoritativas e filtrar/publicar o estado confirmado.

## Documentos

- [`01-MODULOS-E-FASES.md`](01-MODULOS-E-FASES.md): escopo, contratos planejados, dependências e critérios de aceite.
- [`02-REFERENCIAS-E-DECISOES.md`](02-REFERENCIAS-E-DECISOES.md): pesquisa por categoria, limites das referências e decisões recomendadas.
- [`03-RECUPERACAO-REDIS.md`](03-RECUPERACAO-REDIS.md): journal, checkpoints, recovery, bounds de memória e semântica de durabilidade.
- [`04-ANALISE-DE-IMPLEMENTACAO.md`](04-ANALISE-DE-IMPLEMENTACAO.md): análise de código aberto por módulo, padrões para adaptar e riscos/licenças.
- [`05-GRPC-CONTROL.md`](05-GRPC-CONTROL.md): contrato versionado, limites, TLS, autorização e gates do control plane.

## Critérios transversais para iniciar qualquer módulo

1. Declarar status `planned` no registry até existir API utilizável; não expor promessas roadmap como importáveis.
2. Definir fronteira de autorização no servidor, modelo de falhas, cardinalidades máximas e limites de memória/fila.
3. Manter tickets, chaves, payloads privados e identificadores sensíveis fora de logs e URLs.
4. Ter testes unitários e de integração determinísticos, cenários de concorrência, saturação e reconexão.
5. Medir CPU, memória, latência p50/p95/p99, bytes por cliente e comportamento sob perda/atraso antes de publicar números de capacidade.
6. Documentar compatibilidade do protocolo e uma estratégia de migração/versionamento.
7. Executar build/testes do módulo, `pearfy guardian verify` e declarar explicitamente cada gate como PASS ou INCOMPLETE com evidência.
