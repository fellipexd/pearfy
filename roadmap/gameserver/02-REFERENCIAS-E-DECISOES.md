# Referências abertas e decisões de arquitetura para PearfyGameServer

**Pesquisa consultada em:** 2026-10-06. Projetos listados como referências são estudos de padrão; não são dependências recomendadas automaticamente, nem afirmação de que Pearfy já implementou suas capacidades.

## Matriz por tipo de jogo/capacidade

| Categoria | Referência pública | O que estudar | Limite da referência para Pearfy |
| --- | --- | --- | --- |
| Point-and-click, aventura e turn-based | [Battle for Wesnoth multiplayer servers](https://wiki.wesnoth.org/Multiplayerservers) | lobby, descoberta de servidor, sessões e protocolo de jogo por turnos | é um jogo/protocolo específico; não há um servidor point-and-click genérico para reutilizar |
| Friendslop / co-op horror por sessão | [Barotrauma source repository](https://github.com/FakeFishGames/Barotrauma), [public source code FAQ](https://barotraumagame.com/ufaqs/public-source-code/), [Phasmophobia product description](https://www.playstation.com/en-us/games/phasmophobia/) | Barotrauma como implementação pública para estudar coordenação co-op, servidor e estado de missão; Phasmophobia como referência de produto para investigação em grupo, evidências, equipamentos e ameaça assimétrica | Phasmophobia é proprietária. O código público de Barotrauma está sujeito ao seu EULA e não pode ser redistribuído como jogo standalone; nenhum dos dois deve virar dependência de Pearfy |
| Point-and-click web / rooms / coop | [Colyseus Rooms](https://docs.colyseus.io/room), [State Synchronization](https://docs.colyseus.io/state) | sala como fronteira de isolamento; estado mutado no servidor; mensagens de intenção; callbacks de lifecycle e sincronização de mudanças | implementação TypeScript e schema do Colyseus não são contrato Swift; adotar os princípios, não copiar tipos |
| FPS / ação dedicada | [ioquake3](https://github.com/ioquake/ioq3), [server sysadmin guide](https://ioquake3.org/help/sys-admin-guide/) | ciclo de servidor dedicado, tick e configuração operacional de um FPS maduro | engine e protocolo são específicos; não é uma biblioteca de backend Pearfy |
| Transporte de baixa latência | [Valve GameNetworkingSockets](https://github.com/ValveSoftware/GameNetworkingSockets) | mensagens confiáveis e não confiáveis sobre UDP, fragmentação/reassembly e camada criptográfica documentada | camada de transporte, não serialização nem regras de jogo; verificações de disponibilidade/licença/plataforma exigem avaliação separada |
| MMO / mundo persistente | [TrinityCore](https://github.com/TrinityCore/TrinityCore), [configuração do world server](https://github.com/TrinityCore/TrinityCore/blob/master/src/server/worldserver/worldserver.conf.dist) | separação login/world, configuração extensa de rede/performance, persistência e domínio rico de MMORPG | framework completo e GPL-2.0; referência de arquitetura operacional, não dependência ou fonte de código para Pearfy |
| MMO por zonas/rooms | [Colyseus MMO tutorial](https://docs.colyseus.io/learn/tutorial/cocos/mmo), [scalability](https://docs.colyseus.io/scalability) | particionar mundo em rooms/zones, roteamento e escala por processos; explicitar a unidade de autoridade | prova que rooms podem compor uma experiência MMO; não garante persistência/handoff global por si só |
| Friends, parties, presence | [Nakama Parties](https://heroiclabs.com/docs/nakama/concepts/parties/), [architecture and presence](https://heroiclabs.com/docs/nakama/getting-started/architecture/) | party efêmera, liderança, convites, presença e diferença entre party e grupo persistente | Nakama oferece backend amplo; Pearfy deve manter fronteiras opcionais e autorização dentro do jogo/servidor |
| Matchmaking e browser de salas | [Nakama Matchmaker](https://heroiclabs.com/docs/nakama/concepts/multiplayer/matchmaker/), [Open Match guide](https://open-match.dev/site/docs/guides/matchmaker/) | tickets de busca, critérios, cancelamento, formação de match, evaluator e atribuição; separar queue de listagem de partidas abertas | Open Match/Nakama oferecem stack/serviços próprios; Pearfy deve priorizar contratos, store adapter e algoritmo extensível |
| Fleet e dedicated server hosting | [Agones docs](https://www.agones.dev/site/docs/), [Fleet allocation](https://agones.dev/site/docs/reference/fleet/) | ciclo Ready/Allocated, fleet de servidores aquecidos e alocação por orquestrador | Agones hospeda e escala processos no Kubernetes; não é simulação, matchmaking completo nem obrigatório para self-host local |

## Síntese da análise

### O que muda de um gênero para outro

- **Point-and-click:** a unidade de rede tende a ser uma ação semântica (clicar em objeto, dialogar, mover para destino), validada contra o estado e a sequência da partida. Não precisa de datagramas por frame. O desenho deve priorizar idempotência, ordem, eventos e persistência. Para single-player, manter o modo offline independente.
- **Friendslop / co-op horror:** sessões pequenas e finitas, normalmente com trabalho em equipe, objetivos, ameaça/NPCs e informação assimétrica. É tempo real, mas não precisa importar todos os requisitos de um FPS competitivo; WSS é suficiente para o MVP. Servidor é autoridade sobre objetivo, spawn/IA, ameaça, resultado e informação oculta. Reconectar deve retomar sessão dentro de uma grace window, enquanto o mundo continua segundo política definida.
- **FPS:** categoria `high`. Inputs chegam continuamente e precisam de validação em um tick previsível. O servidor simula, calcula o estado e distribui apenas o necessário. Aplicar ownership e reduzir cópias nos hot paths Swift; UDP pode ajudar com perda tolerável e baixa latência, mas protocolo criptográfico, abuso e interoperabilidade são pré-condições, não otimização posterior.
- **MMO:** categoria `high`. Escala de mundo, presença e durabilidade são problemas distintos do throughput de uma sala. Aplicar ownership ao update e à distribuição de entidades; a fronteira inicial saudável é shard/zona com dono único e handoff explícito. Gameplay segue UDP/binário seguro e operações de controle usam gRPC/TLS; evitar “MMO” como sinônimo de muitos sockets. UDP só pode ser habilitado após segurança interoperável e validação de carga.
- **Overhead e sobrecarga em `high`:** não adicionar custo às rotas críticas sem benchmark. Manter CPU por tick, allocations, bytes enviados, filas e memória dentro de orçamento por sessão/zona. Quando saturar, rejeitar/admitir menos ou aplicar degradação definida; nunca crescer buffers sem limite ou deixar uma zona bloquear as demais.
- **Rooms/lobbies:** sala representa lifecycle e isolamento. Descoberta/listing responde “quais partidas já existem”; matchmaking responde “com quem devo formar uma partida”. Devem ter APIs e métricas separadas.
- **Friends/parties:** amizade pode ser persistente; party normalmente é temporária e pode fazer fila em conjunto. Presence é uma observação temporária, não fonte de autorização.
- **Matchmaking:** jogadores submetem tickets e criteria; matcher precisa de cancelamento, deduplicação, justiça e alocação atômica. Para multiplas réplicas, memória local não basta.
- **Hosting:** Agones ou similar aloca processos dedicados; matchmaking decide composição e o jogo mantém autoridade. Essas capacidades devem continuar desacopladas.

### Priorização sugerida

1. Fechar runtime mínimo de transporte seguro e lifecycle de conexão sobre WSS.
2. Implementar Rooms/Presence e TurnBased/Command Event, que cobrem grande variedade de jogos sem exigir transporte experimental.
3. Implementar matchmaking sobre store/leases e conectar com allocator abstrato.
4. Implementar realtime autoritativo para `high`, medindo baseline Swift e desenhando desde o início o destino UDP/binário seguro; manter WSS disponível até os dois endpoints passarem os gates criptográficos. Compor em seguida `CoopSession` para missão PvE e friendslop.
5. Construir World/Zone após existir persistência durável, observabilidade e uma aplicação piloto que necessite dela.
6. Adicionar adapter Agones como produto opcional quando houver integração de deployment a validar.

Essa sequência reduz risco: primeiro valida sessão, autorização, backpressure e recuperação; em seguida adiciona requisitos de performance e distribuição com métricas reais.

## Decisões que precisam de ADR antes de estabilizar APIs

1. **Protocolo de mensagem:** envelope versionado, framing, tipos, sequência, tamanho máximo e negociação. Não acoplar domínio a JSON ou Protobuf; escolher encoding por perfil, com interoperabilidade client-server testada.
2. **Recuperação de sessão:** retomar identidade/partida versus criar nova sessão. Definir quais módulos oferecem resume, token de retomada, janela de grace e política para session ID depois de reinício do processo.
3. **Autoridade e persistência:** fonte de verdade por módulo, store adapter, consistência e ordenação. Tickets em memória atual não podem ser apresentados como multi-instância.
4. **Transporte UDP:** escolher biblioteca/implementação somente após validar suporte real no PearfyEngine e threat model, não a partir do nome do modo `high`.
5. **Métricas públicas:** workload e hardware de benchmark, cenário aberto/fechado, número de entidades, payload, latência de rede e limites de memória; até lá os limites são presets conservadores, não capacidade certificada.
6. **Licenças de referência:** não copiar código nem protocolo sem revisão de licença/compatibilidade. A GPL-2.0 do TrinityCore é um motivo adicional para usá-lo apenas como referência de arquitetura.
7. **Swift versus C nos hot paths:** baseline Swift com ownership explícito vem primeiro; só criar target C se profiling provar gargalo e benchmark comparativo comprovar ganho material. Definir C ABI, contrato de alocação/lifetime, bounds, estratégia de sanitizer e fallback Swift antes de integrar.
8. **Orçamento de overload:** para cada recipe high, publicar limites medidos e comportamento de saturação. A abstração de transporte não deve criar fila ilimitada ou cópia de payload; métricas precisam permitir separar saturação da simulação, rede, serialização e persistência.
9. **Recovery em Redis:** journal + snapshots e replay são um novo produto opcional; Redis cache/broker atuais não bastam. Definir confirmação durável versus janela assíncrona com RPO, persistência/failover exigidos do deployment, fencing multi-instância e política quando Redis está indisponível antes de expor APIs.

## Fontes principais

Para avaliação de arquivos e técnicas concretas por módulo, consulte [`04-ANALISE-DE-IMPLEMENTACAO.md`](04-ANALISE-DE-IMPLEMENTACAO.md). A tabela acima é uma matriz rápida, não um ranking universal de “melhores servidores”.

- Pearfy local: [`docs/GAMESERVER.md`](../../docs/GAMESERVER.md), [`Sources/PearfyGameServer/GameSessions.swift`](../../Sources/PearfyGameServer/GameSessions.swift), [`Sources/PearfyGameServer/GameServerProfiles.swift`](../../Sources/PearfyGameServer/GameServerProfiles.swift).
- Swift ownership: [borrowing and consuming parameters](https://docs.swift.org/latest/documentation/the-swift-programming-language/declarations/) e [safe C/C++ interoperability](https://www.swift.org/documentation/cxx-interop/safe-interop/).
- [Colyseus rooms](https://docs.colyseus.io/room), [state sync](https://docs.colyseus.io/state), [lifecycle](https://docs.colyseus.io/room/lifecycle) e [scalability](https://docs.colyseus.io/scalability).
- [Nakama authoritative/relayed multiplayer](https://heroiclabs.com/docs/nakama/concepts/multiplayer/), [matchmaker](https://heroiclabs.com/docs/nakama/concepts/multiplayer/matchmaker/) e [parties](https://heroiclabs.com/docs/nakama/concepts/parties/).
- [Open Match matchmaking architecture](https://open-match.dev/site/docs/guides/matchmaker/).
- [Agones overview](https://www.agones.dev/site/docs/) e [Fleet](https://agones.dev/site/docs/reference/fleet/).
- [ioquake3 source](https://github.com/ioquake/ioq3) e [dedicated server guide](https://ioquake3.org/help/sys-admin-guide/).
- [Valve GameNetworkingSockets](https://github.com/ValveSoftware/GameNetworkingSockets).
- [TrinityCore](https://github.com/TrinityCore/TrinityCore) e [world server config](https://github.com/TrinityCore/TrinityCore/blob/master/src/server/worldserver/worldserver.conf.dist).
- [Battle for Wesnoth multiplayer servers](https://wiki.wesnoth.org/Multiplayerservers).
- [Barotrauma public repository](https://github.com/FakeFishGames/Barotrauma) e [FAQ sobre acesso ao código e limites do EULA](https://barotraumagame.com/ufaqs/public-source-code/).
- [Phasmophobia product description](https://www.playstation.com/en-us/games/phasmophobia/) como referência de experiência co-op, não como código aberto.
