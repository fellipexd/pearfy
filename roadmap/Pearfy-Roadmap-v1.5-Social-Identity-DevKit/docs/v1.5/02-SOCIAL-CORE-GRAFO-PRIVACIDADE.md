# PearfySocialCore + Graph — identity, actors, relacionamentos

Contratos e tipos do grafo são independentes de uma aplicação; identidades e regras específicas chegam por adapters explícitos.

## Identidade separada

`User` (autenticação/conta) != `SocialActor` (perfil pessoal, página, comunidade). Ligações de owner/admin são verificadas em backend; ator não implica permissão automaticamente. Conteúdo referencia `actorId`, autor da ação auditável como principal autenticado.

## Entidades sugeridas

`social_actors(id,type,owner_ref,handle,status,visibility,created_at)`; `social_profiles(actor_id,display_name,bio,avatar_ref,...)`; `social_follows(source_actor,target_actor,status,created_at)`; `social_friend_requests` quando modelo amizade ativa; `social_blocks`; `social_mutes`; `social_actor_members` para atores coletivos. Não presumir que todas redes oferecem amizade recíproca ou follow livre.

Constraints: handles normalizados e únicos por namespace acordado; `source_actor != target_actor`; unique do par e estado; política de soft delete/anonymization; bloqueio exclui do feed, search, mention e notification segundo regras e escopo. Impedir enumeração e IDOR.

## Escopo da audiência

`public`, `followers`, `friends`, `community`, `private`, `custom` apenas quando implementado; negar por padrão visibilidade não suportada. Revalidar visibilidade no READ: bloquear depois da publicação precisa surtir efeito em índices, caches, feed, URLs e SDKs.

## Concorrência

Follow/unfollow com chave única e semântica idempotente; friend request sob transação; relações A/B canônicas; concorrência cross-instance precisa de DB constraints/transaction, não locks locais. Evitar fanout notificações duplicadas.

## Contracts e erros

DTOs não incluem e-mail real, sessão ou dados privados por padrão. Erros tipados `ACTOR_NOT_FOUND_OR_NOT_VISIBLE`, `FOLLOW_RESTRICTED`, `BLOCKED` conforme threat model que evita enumerar existência.
