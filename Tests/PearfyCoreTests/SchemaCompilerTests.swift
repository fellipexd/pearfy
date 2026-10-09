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
    #expect(!(String(decoding: try first.canonicalJSON(), as: UTF8.self).contains("relationships")))
    #expect(try JSONDecoder().decode(SchemaIR.self, from: first.canonicalJSON()) == first)
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

@Test func relationshipMacrosMaterializeSchemaAndPostgresDDL() throws {
    let schema = try SchemaIR(entities: PearfyGeneratedSchemaRegistry.entities)
    let invoices = try #require(schema.entities.first { $0.table == "relationship_invoices" })
    let customerID = try #require(invoices.columns.first { $0.name == "customer_id" })
    #expect(customerID.type == .uuid)
    #expect(customerID.nullable)
    #expect(invoices.relationships == [SchemaRelationship(
        field: "customer",
        kind: .manyToOne,
        targetTable: "relationship_customers",
        column: "customer_id",
        referencedColumn: "id",
        foreignKeyName: "invoice_customer_fk",
        nullable: true,
        onDelete: .setNull
    )])
    #expect(invoices.foreignKeys.contains(SchemaForeignKey(
        name: "invoice_customer_fk",
        columns: ["customer_id"],
        referencedTable: "relationship_customers",
        referencedColumns: ["id"],
        onDelete: .setNull,
        setNullColumns: ["customer_id"]
    )))
    let customers = try #require(schema.entities.first { $0.table == "relationship_customers" })
    #expect(customers.columns.map(\.name) == ["id"])
    #expect(customers.relationships.first?.mappedBy == "customer")

    let account = try #require(schema.entities.first { $0.table == "relationship_accounts" })
    #expect(account.columns.contains { $0.name == "profile_id" && $0.unique })
    #expect(account.foreignKeys.first?.name == "fk_relationship_accounts_profile_id")

    let plan = try PostgresSchemaCompiler().plan(from: nil, to: schema)
    #expect(plan.upStatements.contains("ALTER TABLE \"relationship_invoices\" ADD CONSTRAINT \"invoice_customer_fk\" FOREIGN KEY (\"customer_id\") REFERENCES \"relationship_customers\" (\"id\") ON DELETE SET NULL (\"customer_id\")"))
    #expect(plan.upStatements.contains("ALTER TABLE \"relationship_accounts\" ADD CONSTRAINT \"fk_relationship_accounts_profile_id\" FOREIGN KEY (\"profile_id\") REFERENCES \"relationship_profiles\" (\"id\") ON UPDATE CASCADE"))
}

@Test func owningRelationshipCanBePartOfCompositePrimaryKeyAndRegistrySchema() throws {
    let schema = try SchemaIR(entities: PearfyGeneratedSchemaRegistry.entities)
    let projection = try #require(schema.entities.first { $0.table == "bank_account_balance_projections" })
    let accountID = try #require(projection.columns.first { $0.name == "account_id" })
    #expect(projection.columns.filter { $0.name == "account_id" }.count == 1)
    #expect(accountID.type == .uuid)
    #expect(!accountID.nullable)
    #expect(accountID.primaryKey)
    #expect(projection.primaryKey == ["account_id", "currency", "scale"])
    #expect(projection.foreignKeys == [SchemaForeignKey(
        name: "fk_bank_account_balance_projections_account_id",
        columns: ["account_id"],
        referencedTable: "bank_accounts",
        referencedColumns: ["id"]
    )])

    let create = try #require(PostgresSchemaCompiler().plan(from: nil, to: schema).upStatements.first {
        $0.contains("CREATE TABLE \"bank_account_balance_projections\"")
    })
    #expect(create.contains("PRIMARY KEY (\"account_id\", \"currency\", \"scale\")"))
    #expect(!create.contains("\"account_id\" UUID NOT NULL, \"account_id\""))
    #expect(try schema.fingerprint() == SchemaIR(entities: PearfyGeneratedSchemaRegistry.entities).fingerprint())
    #expect(try JSONDecoder().decode(SchemaIR.self, from: schema.canonicalJSON()) == schema)
}

@Test func relationshipPrimaryKeyMetadataRejectsInvalidCases() throws {
    let id = SchemaColumn(name: "id", type: .uuid, primaryKey: true)
    let accounts = SchemaEntity(table: "accounts", columns: [id])

    func rejects(_ relation: SchemaRelationship, columns: [SchemaColumn] = [id]) -> Bool {
        do {
            _ = try SchemaIR(entities: [SchemaEntity(table: "source", columns: columns, relationships: [relation]), accounts])
            return false
        } catch SchemaCompilerError.invalidRelationship {
            return true
        } catch {
            return false
        }
    }

    #expect(rejects(SchemaRelationship(field: "account", kind: .manyToOne, targetTable: "accounts", nullable: true, primaryKey: true)))
    #expect(rejects(SchemaRelationship(field: "accounts", kind: .oneToMany, targetTable: "accounts", mappedBy: "source", primaryKey: true)))
    #expect(rejects(SchemaRelationship(field: "missing", kind: .manyToOne, targetTable: "not_found", primaryKey: true)))
    #expect(rejects(SchemaRelationship(field: "account", kind: .manyToOne, targetTable: "accounts", referencedColumn: "missing", primaryKey: true)))

    let nonUniqueTarget = SchemaEntity(table: "non_unique_accounts", columns: [id, SchemaColumn(name: "code", type: .text)])
    do {
        _ = try SchemaIR(entities: [
            SchemaEntity(table: "source", columns: [id], relationships: [
                SchemaRelationship(field: "account", kind: .manyToOne, targetTable: "non_unique_accounts", referencedColumn: "code", primaryKey: true)
            ]),
            nonUniqueTarget
        ])
        Issue.record("expected a non-unique relationship reference to be rejected")
    } catch SchemaCompilerError.invalidRelationship { }

    #expect(rejects(SchemaRelationship(field: "account", kind: .manyToOne, targetTable: "accounts", primaryKey: true), columns: [id, SchemaColumn(name: "account_id", type: .text)]))
    #expect(rejects(SchemaRelationship(field: "accounts", kind: .manyToMany, targetTable: "accounts", primaryKey: true)))
}

@Test func relationshipPrimaryKeyChangesRequireAnExplicitMigration() throws {
    let old = try SchemaIR(entities: [
        SchemaEntity(table: "accounts", columns: [SchemaColumn(name: "id", type: .uuid, primaryKey: true)]),
        SchemaEntity(table: "balances", columns: [SchemaColumn(name: "id", type: .uuid, primaryKey: true)])
    ])
    let desired = try SchemaIR(entities: [
        SchemaEntity(table: "accounts", columns: [SchemaColumn(name: "id", type: .uuid, primaryKey: true)]),
        SchemaEntity(table: "balances", columns: [SchemaColumn(name: "account_id", type: .uuid, primaryKey: true), SchemaColumn(name: "currency", type: .text, primaryKey: true)])
    ])
    #expect(throws: SchemaCompilerError.unsupportedPrimaryKeyChange(table: "balances")) {
        _ = try PostgresSchemaCompiler().plan(from: old, to: desired)
    }
}

@Test func manyToManyMacroCreatesDeterministicJunctionTableAndForeignKeys() throws {
    let schema = try SchemaIR(entities: PearfyGeneratedSchemaRegistry.entities)
    let joinTable = try #require(schema.entities.first { $0.table == "book_tags" })
    #expect(joinTable.relationshipJoinTable)
    #expect(joinTable.columns == [
        SchemaColumn(name: "book_id", type: .uuid),
        SchemaColumn(name: "tag_id", type: .uuid)
    ])
    #expect(joinTable.primaryKey == ["book_id", "tag_id"])
    #expect(joinTable.foreignKeys == [
        SchemaForeignKey(name: "book_tags_book_fk", columns: ["book_id"], referencedTable: "relationship_books", referencedColumns: ["id"], onDelete: .cascade),
        SchemaForeignKey(name: "book_tags_tag_fk", columns: ["tag_id"], referencedTable: "relationship_tags", referencedColumns: ["id"], onDelete: .cascade)
    ])
    let book = try #require(schema.entities.first { $0.table == "relationship_books" })
    let inverse = try #require(schema.entities.first { $0.table == "relationship_tags" })
    #expect(book.relationships.first?.kind == .manyToMany)
    #expect(inverse.relationships.first?.mappedBy == "tags")

    let plan = try PostgresSchemaCompiler().plan(from: nil, to: schema)
    #expect(plan.upStatements.contains("CREATE TABLE \"book_tags\" (\"book_id\" UUID NOT NULL, \"tag_id\" UUID NOT NULL, PRIMARY KEY (\"book_id\", \"tag_id\"))"))
    #expect(plan.upStatements.contains("ALTER TABLE \"book_tags\" ADD CONSTRAINT \"book_tags_book_fk\" FOREIGN KEY (\"book_id\") REFERENCES \"relationship_books\" (\"id\") ON DELETE CASCADE"))
    #expect(plan.upStatements.contains("ALTER TABLE \"book_tags\" ADD CONSTRAINT \"book_tags_tag_fk\" FOREIGN KEY (\"tag_id\") REFERENCES \"relationship_tags\" (\"id\") ON DELETE CASCADE"))
    #expect(try JSONDecoder().decode(SchemaIR.self, from: schema.canonicalJSON()) == schema)
}

@Test func manyToManyRejectsInvalidInverseAndJoinConfiguration() throws {
    let id = SchemaColumn(name: "id", type: .uuid, primaryKey: true)
    let tags = SchemaEntity(table: "tags", columns: [id])
    var rejectedMissingMappedBy = false
    do {
        _ = try SchemaIR(entities: [
            SchemaEntity(table: "books", columns: [id], relationships: [SchemaRelationship(field: "tags", kind: .manyToMany, targetTable: "tags", mappedBy: "missing")]),
            tags
        ])
    } catch SchemaCompilerError.invalidRelationship { rejectedMissingMappedBy = true }
    #expect(rejectedMissingMappedBy)

    var rejectedDuplicateJoinColumns = false
    do {
        _ = try SchemaIR(entities: [
            SchemaEntity(table: "books", columns: [id], relationships: [SchemaRelationship(field: "tags", kind: .manyToMany, targetTable: "tags", joinColumn: "same_id", inverseJoinColumn: "same_id")]),
            tags
        ])
    } catch SchemaCompilerError.invalidRelationship { rejectedDuplicateJoinColumns = true }
    #expect(rejectedDuplicateJoinColumns)

    let defaults = try SchemaIR(entities: [
        SchemaEntity(table: "authors", columns: [id], relationships: [SchemaRelationship(field: "books", kind: .manyToMany, targetTable: "books")]),
        SchemaEntity(table: "books", columns: [id])
    ])
    let defaultJoin = try #require(defaults.entities.first { $0.table == "authors_books" })
    #expect(defaultJoin.columns.map(\.name) == ["authors_id", "books_id"])
    #expect(defaultJoin.primaryKey == ["authors_id", "books_id"])
    let reversedNames = try SchemaIR(entities: [
        SchemaEntity(table: "zz_authors", columns: [id], relationships: [SchemaRelationship(field: "books", kind: .manyToMany, targetTable: "aa_books")]),
        SchemaEntity(table: "aa_books", columns: [id])
    ])
    #expect(try JSONDecoder().decode(SchemaIR.self, from: reversedNames.canonicalJSON()) == reversedNames)
}

@Test func inverseOneToOneResolvesMappedByToTheOwningSide() throws {
    let id = SchemaColumn(name: "id", type: .uuid, primaryKey: true)
    let profiles = SchemaEntity(table: "profiles", columns: [id], relationships: [
        SchemaRelationship(field: "account", kind: .oneToOne, targetTable: "accounts", mappedBy: "profile")
    ])
    let accounts = SchemaEntity(table: "accounts", columns: [id], relationships: [
        SchemaRelationship(field: "profile", kind: .oneToOne, targetTable: "profiles")
    ])
    let schema = try SchemaIR(entities: [profiles, accounts])
    #expect(try #require(schema.entities.first { $0.table == "accounts" }).columns.contains { $0.name == "profile_id" && $0.unique })
    #expect(try #require(schema.entities.first { $0.table == "profiles" }).columns.map(\.name) == ["id"])
}

@Test func relationshipSchemaRejectsMissingTargetsAndInvalidInverseMappings() throws {
    let id = SchemaColumn(name: "id", type: .uuid, primaryKey: true)
    let missingTarget = SchemaEntity(
        table: "orders",
        columns: [id],
        relationships: [SchemaRelationship(field: "customer", kind: .manyToOne, targetTable: "customers")]
    )
    var missingWasRejected = false
    do { _ = try SchemaIR(entities: [missingTarget]) }
    catch SchemaCompilerError.invalidRelationship(table: "orders", field: "customer", reason: _) { missingWasRejected = true }
    #expect(missingWasRejected)

    let invalidInverse = SchemaEntity(
        table: "customers",
        columns: [id],
        relationships: [SchemaRelationship(field: "orders", kind: .oneToMany, targetTable: "orders", mappedBy: "unknown")]
    )
    let owner = SchemaEntity(table: "orders", columns: [id])
    var inverseWasRejected = false
    do { _ = try SchemaIR(entities: [invalidInverse, owner]) }
    catch SchemaCompilerError.invalidRelationship(table: "customers", field: "orders", reason: _) { inverseWasRejected = true }
    #expect(inverseWasRejected)

    let invalidSetNull = SchemaEntity(
        table: "orders",
        columns: [id],
        relationships: [SchemaRelationship(field: "customer", kind: .manyToOne, targetTable: "customers", onDelete: .setNull)]
    )
    let customer = SchemaEntity(table: "customers", columns: [id])
    var setNullWasRejected = false
    do { _ = try SchemaIR(entities: [invalidSetNull, customer]) }
    catch SchemaCompilerError.invalidRelationship(table: "orders", field: "customer", reason: _) { setNullWasRejected = true }
    #expect(setNullWasRejected)

    let incompatibleColumn = SchemaEntity(
        table: "orders",
        columns: [id, SchemaColumn(name: "customer_id", type: .text, nullable: true)],
        relationships: [SchemaRelationship(field: "customer", kind: .manyToOne, targetTable: "customers", nullable: true)]
    )
    var incompatibleWasRejected = false
    do { _ = try SchemaIR(entities: [incompatibleColumn, customer]) }
    catch SchemaCompilerError.invalidRelationship(table: "orders", field: "customer", reason: _) { incompatibleWasRejected = true }
    #expect(incompatibleWasRejected)

    let duplicateInverse = SchemaEntity(
        table: "customers",
        columns: [id],
        relationships: [
            SchemaRelationship(field: "orders", kind: .oneToMany, targetTable: "orders", mappedBy: "customer"),
            SchemaRelationship(field: "openOrders", kind: .oneToMany, targetTable: "orders", mappedBy: "customer")
        ]
    )
    let orderOwner = SchemaEntity(table: "orders", columns: [id], relationships: [
        SchemaRelationship(field: "customer", kind: .manyToOne, targetTable: "customers")
    ])
    var duplicateWasRejected = false
    do { _ = try SchemaIR(entities: [duplicateInverse, orderOwner]) }
    catch SchemaCompilerError.invalidRelationship(table: "customers", field: "openOrders", reason: _) { duplicateWasRejected = true }
    #expect(duplicateWasRejected)
}

@Test func relationshipMigrationsAddNullableForeignKeyToExistingTable() throws {
    let old = try SchemaIR(entities: [SchemaEntity(table: "orders", columns: [
        SchemaColumn(name: "id", type: .uuid, primaryKey: true)
    ]), SchemaEntity(table: "customers", columns: [
        SchemaColumn(name: "id", type: .uuid, primaryKey: true)
    ])])
    let desired = try SchemaIR(entities: [SchemaEntity(table: "orders", columns: [
        SchemaColumn(name: "id", type: .uuid, primaryKey: true)
    ], relationships: [SchemaRelationship(field: "customer", kind: .manyToOne, targetTable: "customers", nullable: true)]), SchemaEntity(table: "customers", columns: [
        SchemaColumn(name: "id", type: .uuid, primaryKey: true)
    ])])

    #expect(try PostgresSchemaCompiler().plan(from: old, to: desired).upStatements == [
        "ALTER TABLE \"orders\" ADD COLUMN \"customer_id\" UUID NULL",
        "ALTER TABLE \"orders\" ADD CONSTRAINT \"fk_orders_customer_id\" FOREIGN KEY (\"customer_id\") REFERENCES \"customers\" (\"id\")"
    ])
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

@Entity("relationship_customers")
struct RelationshipCustomerSchemaFixture: Sendable {
    @ID var id: UUID
    @OneToMany(targetTable: "relationship_invoices", mappedBy: "customer") var invoices: [RelationshipInvoiceSchemaFixture]
}

@Entity("relationship_invoices")
struct RelationshipInvoiceSchemaFixture: Sendable {
    @ID var id: UUID
    @ManyToOne(
        targetTable: "relationship_customers",
        column: "customer_id",
        foreignKeyName: "invoice_customer_fk",
        nullable: true,
        onDelete: .setNull
    ) var customer: RelationshipCustomerSchemaFixture?
}

@Entity("relationship_profiles")
struct RelationshipProfileSchemaFixture: Sendable {
    @ID var id: UUID
}

@Entity("relationship_accounts")
struct RelationshipAccountSchemaFixture: Sendable {
    @ID var id: UUID
    @OneToOne(targetTable: "relationship_profiles", onUpdate: .cascade) var profile: RelationshipProfileSchemaFixture
}

@Entity("bank_account_balance_projections")
struct BankAccountBalanceProjectionSchemaFixture: Sendable {
    @ManyToOne(targetTable: "bank_accounts", column: "account_id", primaryKey: true)
    var account: BankAccountSchemaFixture
    @ID(strategy: .assigned) var currency: String
    @ID(strategy: .assigned) var scale: Int
}

@Entity("bank_accounts")
struct BankAccountSchemaFixture: Sendable {
    @ID var id: UUID
}

@Entity("relationship_books")
struct RelationshipBookSchemaFixture: Sendable {
    @ID var id: UUID
    @ManyToMany(
        targetTable: "relationship_tags",
        joinTable: "book_tags",
        joinColumn: "book_id",
        inverseJoinColumn: "tag_id",
        joinForeignKeyName: "book_tags_book_fk",
        inverseForeignKeyName: "book_tags_tag_fk",
        onDelete: .cascade
    ) var tags: [RelationshipTagSchemaFixture]
}

@Entity("relationship_tags")
struct RelationshipTagSchemaFixture: Sendable {
    @ID var id: UUID
    @ManyToMany(targetTable: "relationship_books", mappedBy: "tags") var books: [RelationshipBookSchemaFixture]
}
