# PearfyIdentity + PearfySocialLogin — social login independente de rede social

## Instalação

```bash
pearfy add identity
pearfy add social-login --providers google,apple,microsoft
pearfy identity social-storage enable --database postgres --user-table users
```

Comandos propostos; CLI deve identificar modelo/ID real do projeto e gerar diff de migration. Storage é **opcional**: projetos com identity adapter próprio implementam `SocialAccountLinkStore`; não expor `link/list/unlink` persistentes sem store.

## Modelo relacional (adapte schema/schema names reais)

```sql
CREATE TABLE user_social_accounts (
  id UUID PRIMARY KEY,
  user_id UUID NOT NULL REFERENCES users(id),
  provider VARCHAR(40) NOT NULL,
  issuer VARCHAR(255) NOT NULL,
  provider_subject VARCHAR(255) NOT NULL,
  email_at_link_time VARCHAR(320),
  linked_at TIMESTAMPTZ NOT NULL,
  last_login_at TIMESTAMPTZ,
  UNIQUE (issuer, provider_subject)
);
CREATE INDEX idx_user_social_accounts_user_id ON user_social_accounts(user_id);
```

Adicionar tenant scope se o modelo de identidade exigir; `issuer` exato normalizado com política provider; `sub` é identificador, não email. UUIDv7 padrão para `id` onde aplicável e compatível com schema. O adapter não deve impor um nome/tipo de tabela de usuários ao projeto consumidor.

## Segurança

Authorization Code + PKCE quando aplicável, state/nonce, validar issuer/audience/signature/exp e binding de fluxo, clock skew, JWK cache/rotation, callback allowlist; verificar se provider retorna profile completo só na primeira autenticação; autorização/concessões são da conta local. Login externo autentica usuário, mas a API emite a sessão própria. Não vincular contas somente por email, exigir auth recente dos dois lados (ou recovery dedicado). Impedir unlink da última autenticação viável. `UNIQUE(issuer,sub)` elimina vinculação cross-user concorrente; first login create/link na mesma transação.

## SDKs

`/app` iOS+Android, `/bko` TS se configurado, `/public` conforme export policy; SDKs geram iniciar/finalizar fluxo OAuth nativo/browser correto para a plataforma, sem embutir client_secret em mobile; credenciais em config central backend. SDK export ≠ policy de acesso.

## Integração genérica

Preservar IDs e relações já definidos pelo adapter de identidade. Reutilizar vínculos existentes antes de propor nova persistência. Testar múltiplos provedores para a mesma conta, email alterado, relay address, replay, concorrência no primeiro login e reversão de associação não autorizada.
