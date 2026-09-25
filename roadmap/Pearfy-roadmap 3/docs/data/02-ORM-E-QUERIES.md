# Pearfy ORM — contrato robusto, tipado e mensurável

## Objetivos
CRUD, query builder fortemente tipado, relações explícitas, projeções, paginação cursor/offset, transações, bulk, streaming, optimistic locking, auditing e SQL parametrizado. Nenhum `[String: Any]` nas interfaces públicas de negócio; metadados de entidades gerados no build, não reconstruídos por request.

## API-alvo (ilustrativa)
```swift
@Repository
struct UserRepository: Repository<User, UUID> {
    @Query("SELECT id, name FROM users WHERE email = :email")
    func findByEmail(email: String) async throws -> UserSummary?
}

let users = try await User.query(on: database)
    .where(\.active == true)
    .orderBy(\.createdAt, .descending)
    .limit(20)
    .all()
```

## Regras de query
- Valores dinâmicos separados do texto SQL por bindings; não interpolar dados não confiáveis em identificadores/tabelas/fragmentos arbitrários.
- Query builder monta AST tipada; não usar reflexão genérica para compilar key paths arbitrários.
- `SELECT *` não é default para projeções pequenas; o retorno corresponde aos campos selecionados.
- Relations usam carregamento explícito/prefetch/batch; N+1 automático proibido.
- Streaming com backpressure para conjuntos grandes; limites de paginação configuráveis.
- Prepared statements e caching de plano com invalidação e limites por conexão quando suportado.
- Métricas: count, duração, pool wait, rows returned, query template normalizado sem parâmetros sensíveis.
- `EXPLAIN` depende de banco de teste/contas restritas; `EXPLAIN ANALYZE` executa a operação e não roda indiscriminadamente em comandos mutáveis.
- SQL manual permanece disponível para consultas que o builder não representa sem perdas.

## Relações e domain
`@BelongsTo`, `@HasOne`, `@HasMany`, `@ManyToMany` mapeiam schema/constraints; separação de Domain e Entity é opcional quando não protege regras reais. Evitar relacionamentos recursivos implicitamente carregados.

## Dinheiro
`Float` e `Double` são proibidos em saldos/transferências; usar `Money` com precisão explícita e escala/rounding validado, ou inteiro em unidades mínimas com política de moeda. Sem converter cegamente `Decimal` entre dialetos.

## Critérios de aceite
CRUD e transação em banco real; N+1 testável, prepared bindings garantidos, query builder traduz tipos corretamente, streaming não explode RAM, compatibilidade por adapter, benchmarks vs SQL direto com overhead medido.
