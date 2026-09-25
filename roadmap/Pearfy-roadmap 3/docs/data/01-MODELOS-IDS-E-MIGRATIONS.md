# PearfyData — modelos Swift como schema e migrations versionadas

**Estado:** contrato-alvo, não funcionalidade declarada como pronta.

## Fonte da definição
`@Entity`, `@ID`, `@Column`, `@Index`, `@BelongsTo` etc. em código Swift fornecem o schema desejado. Não exigir um arquivo de schema manual paralelo. Macros geram descritores locais e um passo de discovery compõe o schema completo entre targets. Não presumir que uma macro isolada varra todos os arquivos.

```swift
// Sintaxe pública desejada, não necessariamente compilável no protótipo.
@Entity("users")
struct User: Persistable {
    @ID var id: UUID                  // UUIDv7 por padrão
    @Column(length: 120) var name: String
    @Column(unique: true) var email: String
    @Column(precision: 19, scale: 4) var balance: Decimal
    @Column var phone: String?
}
```

## Política de ID
- `@ID` com tipo `UUID` => `.uuidV7` quando não houver estratégia explícita; geração pela aplicação por padrão.
- Permitir `.uuidV4`, `.uuidV6`, `.uuidV5(namespace/name)`, `.assigned`, `.autoIncrement` para `Int`/`Int64` e estratégias customizadas tipadas; ULID exige tipo/mapeamento apropriado.
- Validar em build/config o par tipo × estratégia. Não pressupor que `UUID()` gere UUIDv7.
- UUIDv4 e UUIDv7 em PostgreSQL compartilham tipo `UUID`; mudar somente gerador **não** equivale a ALTER TABLE, mas exige revisão de compatibilidade e metadados.
- IDs não são segredos; tokens de acesso usam geradores criptográficos próprios.

## Compiler e diff
1. Descobrir todas as entidades e validar nomes, chaves, nullability, precisão, relações e índices.
2. Emitir `SchemaIR` determinístico e canônico; versão do formato e hash.
3. Derivar schema anterior do histórico/snapshot versionado e comparar com o desejado.
4. Construir `MigrationPlan` tipado: operações, dependências, lock/risk, capacidade do dialeto e compatibilidade com deploy gradual.
5. Emitir SQL específico por dialeto, arquivo versionado, checksum e snapshot gerado.
6. Executar só após revisão/validação; histórico persistido no banco.

## Renomes e alterações de risco
- `renamedFrom` explícito ou passo manual revisado para coluna/tabela. Nunca inferir automaticamente drop+add como rename seguro.
- `NOT NULL` em tabela populada exige default/backfill e validação; backfill pesado em lotes/fora de transação prolongada conforme dialeto.
- Drop/alter type/PK/índice crítico exigem plano explícito; usar expand/backfill/contract em deploy com versões simultâneas.
- `migrate dev` gera plano/SQL; `migrate deploy` aplica migrations previamente versionadas; em produção não executar `schema sync` implícito no boot.
- `migrate drift` compara banco real com histórico, sem “corrigir” silenciosamente.
- Checksum impede edição invisível de migration aplicada; lock de migração serializa runners múltiplos.
- DDL transacional depende do driver; registrar passos parciais, retomada e compensação quando DDL não for atômico.

## CLI-alvo
`pearfy migrate dev --name ...`, `diff`, `check`, `plan`, `deploy`, `status`, `drift`; flags `--dry-run`, `--output sql`, `--environment` conforme suporte seguro.

## Aceite
- Modelo adicionado -> CREATE table correto; coluna opcional -> ALTER ADD sem perda; rename declarado -> RENAME ou plano seguro; alterações destrutivas sem aprovação -> não aplicar.
- Runners concorrentes não aplicam mesmo arquivo duas vezes; drift e checksums detectados; snapshots determinísticos entre builds.
- Certificar por dialeto; nenhum “dialeto genérico” promete DDL que banco não suporta.
