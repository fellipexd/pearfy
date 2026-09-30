import Foundation
import PearfyData
import PearfyMacros
import Testing

@Test func schemaIRFingerprintIsStableAcrossDeclarationOrder() throws {
    let accounts = SchemaEntity(table: "accounts", columns: [
        SchemaColumn(name: "id", type: .uuid, primaryKey: true),
        SchemaColumn(name: "balance", type: .decimal(precision: 19, scale: 4))
    ])
    let users = SchemaEntity(table: "users", columns: [
        SchemaColumn(name: "email", type: .text, unique: true),
        SchemaColumn(name: "id", type: .uuid, primaryKey: true)
    ])
    let first = try SchemaIR(entities: [accounts, users])
    let reordered = try SchemaIR(entities: [
        SchemaEntity(table: "users", columns: Array(users.columns.reversed())),
        SchemaEntity(table: "accounts", columns: Array(accounts.columns.reversed()))
    ])

    #expect(try first.canonicalJSON() == reordered.canonicalJSON())
    #expect(try first.fingerprint() == reordered.fingerprint())
}

@Test func postgresSchemaCompilerGeneratesDeterministicCreateStatements() throws {
    let schema = try SchemaIR(entities: [SchemaEntity(
        table: "accounts",
        columns: [
            SchemaColumn(name: "id", type: .uuid, primaryKey: true),
            SchemaColumn(name: "balance", type: .decimal(precision: 19, scale: 4)),
            SchemaColumn(name: "name", type: .text, nullable: true, defaultValue: .text("Pearfy's"))
        ],
        indexes: [SchemaIndex(name: "accounts_name_idx", columns: ["name"], unique: true)]
    )])

    let plan = try PostgresSchemaCompiler().plan(from: nil, to: schema)
    #expect(plan.fromFingerprint == nil)
    #expect(plan.toFingerprint == (try schema.fingerprint()))
    #expect(!plan.requiresDestructiveApproval)
    #expect(plan.upStatements == [
        "CREATE TABLE \"accounts\" (\"balance\" NUMERIC(19, 4) NOT NULL, \"id\" UUID NOT NULL, \"name\" TEXT NULL DEFAULT 'Pearfy''s', PRIMARY KEY (\"id\"))",
        "CREATE UNIQUE INDEX \"accounts_name_idx\" ON \"accounts\" (\"name\")"
    ])
}

@Test func postgresSchemaCompilerGeneratesACompleteModelBaselineInDependencyOrder() throws {
    let owner = SchemaEntity(
        table: "accounts",
        columns: [SchemaColumn(name: "id", type: .uuid)],
        primaryKey: ["id"]
    )
    let child = SchemaEntity(
        table: "account_links",
        columns: [
            SchemaColumn(name: "id", type: .postgres("bigint"), defaultValue: .sql("nextval('account_links_id_seq'::regclass)")),
            SchemaColumn(name: "account_id", type: .uuid)
        ],
        primaryKey: ["id"],
        checks: [SchemaCheckConstraint(name: "account_links_id_positive", expression: "id > 0")],
        uniqueConstraints: [SchemaUniqueConstraint(name: "account_links_account_key", columns: ["account_id"])],
        foreignKeys: [SchemaForeignKey(
            name: "account_links_owner_fk",
            columns: ["account_id"],
            referencedTable: "accounts",
            referencedColumns: ["id"],
            onDelete: .cascade
        )]
    )
    let schema = try SchemaIR(
        entities: [child, owner],
        preTableSQL: ["CREATE EXTENSION IF NOT EXISTS pgcrypto"],
        postTableSQL: ["CREATE TRIGGER account_links_touch BEFORE UPDATE ON account_links FOR EACH ROW EXECUTE FUNCTION set_updated_at()"]
    )

    let plan = try PostgresSchemaCompiler().plan(from: nil, to: schema)
    #expect(plan.upStatements == [
        "CREATE EXTENSION IF NOT EXISTS pgcrypto",
        "CREATE TABLE \"account_links\" (\"account_id\" UUID NOT NULL, \"id\" bigint NOT NULL DEFAULT nextval('account_links_id_seq'::regclass), PRIMARY KEY (\"id\"))",
        "CREATE TABLE \"accounts\" (\"id\" UUID NOT NULL, PRIMARY KEY (\"id\"))",
        "ALTER TABLE \"account_links\" ADD CONSTRAINT \"account_links_id_positive\" CHECK (id > 0)",
        "ALTER TABLE \"account_links\" ADD CONSTRAINT \"account_links_account_key\" UNIQUE (\"account_id\")",
        "ALTER TABLE \"account_links\" ADD CONSTRAINT \"account_links_owner_fk\" FOREIGN KEY (\"account_id\") REFERENCES \"accounts\" (\"id\") ON DELETE CASCADE",
        "CREATE TRIGGER account_links_touch BEFORE UPDATE ON account_links FOR EACH ROW EXECUTE FUNCTION set_updated_at()"
    ])
}

@Test func postgresSchemaCompilerAddsNullableColumnsAndRequiresBackfillForRequiredColumns() throws {
    let original = try SchemaIR(entities: [SchemaEntity(
        table: "users",
        columns: [SchemaColumn(name: "id", type: .uuid, primaryKey: true)]
    )])
    let nullableAddition = try SchemaIR(entities: [SchemaEntity(
        table: "users",
        columns: [
            SchemaColumn(name: "id", type: .uuid, primaryKey: true),
            SchemaColumn(name: "nickname", type: .text, nullable: true)
        ]
    )])

    let plan = try PostgresSchemaCompiler().plan(from: original, to: nullableAddition)
    #expect(plan.upStatements == ["ALTER TABLE \"users\" ADD COLUMN \"nickname\" TEXT NULL"])

    let requiredAddition = try SchemaIR(entities: [SchemaEntity(
        table: "users",
        columns: [
            SchemaColumn(name: "id", type: .uuid, primaryKey: true),
            SchemaColumn(name: "age", type: .integer)
        ]
    )])
    var backfillRequired = false
    do {
        _ = try PostgresSchemaCompiler().plan(from: original, to: requiredAddition)
    } catch SchemaCompilerError.requiredColumnNeedsDefault(table: "users", column: "age") {
        backfillRequired = true
    }
    #expect(backfillRequired)
}

@Test func postgresSchemaCompilerRequiresApprovalForDropsAndHonorsExplicitRenames() throws {
    let oldSchema = try SchemaIR(entities: [SchemaEntity(
        table: "users",
        columns: [
            SchemaColumn(name: "id", type: .uuid, primaryKey: true),
            SchemaColumn(name: "display_name", type: .text, nullable: true)
        ]
    )])
    let renamedSchema = try SchemaIR(entities: [SchemaEntity(
        table: "users",
        columns: [
            SchemaColumn(name: "id", type: .uuid, primaryKey: true),
            SchemaColumn(name: "name", type: .text, nullable: true, renamedFrom: "display_name")
        ]
    )])
    let compiler = PostgresSchemaCompiler()

    var approvalRequired = false
    do {
        _ = try compiler.plan(from: oldSchema, to: renamedSchema)
    } catch SchemaCompilerError.destructiveApprovalRequired(let changes) {
        approvalRequired = changes == ["rename column users.display_name to name"]
    }
    #expect(approvalRequired)

    let approved = try compiler.plan(from: oldSchema, to: renamedSchema, allowDestructiveChanges: true)
    #expect(approved.upStatements == ["ALTER TABLE \"users\" RENAME COLUMN \"display_name\" TO \"name\""])
    #expect(approved.requiresDestructiveApproval)
}

@Test func entityMacrosGenerateAndDiscoverTargetSchema() throws {
    let schema = try SchemaIR(entities: PearfyGeneratedSchemaRegistry.entities)
    let entity = try #require(schema.entities.first { $0.table == "roadmap_accounts" })
    let id = try #require(entity.columns.first { $0.name == "id" })
    let email = try #require(entity.columns.first { $0.name == "email" })
    let balance = try #require(entity.columns.first { $0.name == "balance" })

    #expect(id.primaryKey)
    #expect(id.identifierStrategy == .uuidV7)
    #expect(email.nullable)
    #expect(email.unique)
    #expect(balance.type == .decimal(precision: 19, scale: 4))

    let expressionEntity = try #require(schema.entities.first { $0.table == "roadmap_model_expression" })
    #expect(expressionEntity.primaryKey == ["id"])
    #expect(expressionEntity.checks == [SchemaCheckConstraint(name: "roadmap_model_expression_positive", expression: "id > 0")])
    #expect(expressionEntity.foreignKeys == [SchemaForeignKey(
        name: "roadmap_model_expression_owner_fk",
        columns: ["owner_id"],
        referencedTable: "roadmap_accounts",
        referencedColumns: ["id"],
        onDelete: .cascade
    )])
}

@Entity("roadmap_accounts")
struct RoadmapAccountSchemaFixture: Sendable {
    @ID var id: UUID
    @Column(nullable: true, unique: true) var email: String?
    @Column(precision: 19, scale: 4) var balance: Decimal
}

@Entity(SchemaEntity(
    table: "roadmap_model_expression",
    columns: [
        SchemaColumn(name: "id", type: .postgres("bigint")),
        SchemaColumn(name: "owner_id", type: .uuid)
    ],
    primaryKey: ["id"],
    checks: [SchemaCheckConstraint(name: "roadmap_model_expression_positive", expression: "id > 0")],
    foreignKeys: [SchemaForeignKey(
        name: "roadmap_model_expression_owner_fk",
        columns: ["owner_id"],
        referencedTable: "roadmap_accounts",
        referencedColumns: ["id"],
        onDelete: .cascade
    )]
))
struct RoadmapSchemaEntityExpressionFixture: Sendable {}
