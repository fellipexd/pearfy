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
}

@Entity("roadmap_accounts")
struct RoadmapAccountSchemaFixture: Sendable {
    @ID var id: UUID
    @Column(nullable: true, unique: true) var email: String?
    @Column(precision: 19, scale: 4) var balance: Decimal
}
