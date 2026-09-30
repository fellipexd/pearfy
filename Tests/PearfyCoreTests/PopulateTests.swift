import Foundation
import PearfyData
import PearfyPopulateCore
import PearfyPopulatePostgres
import Testing

@Test func populatePlanIsStableAndGeneratorProducesDeterministicUUIDv7AndCheckValues() throws {
    let limits = try PopulateExecutionLimits(maxRows: 100, maxBatchRows: 10, minimumFreeDiskBytes: 0)
    let table = PopulateTable(
        schema: "public",
        name: "synthetic_items",
        columns: [
            PopulateColumn(name: "id", sqlType: "uuid", nullable: false),
            PopulateColumn(name: "slug", sqlType: "character varying(64)", nullable: false, maximumLength: 64),
            PopulateColumn(name: "score", sqlType: "integer", nullable: false)
        ],
        primaryKey: ["id"],
        uniqueConstraints: [PopulateUniqueConstraint(name: "synthetic_items_slug_key", columns: ["slug"])],
        checks: [PopulateCheckConstraint(name: "synthetic_items_score_check", expression: "CHECK ((score >= 10) AND (score <= 20))")]
    )
    let snapshot = PopulateSchemaSnapshot(databaseName: "local_dev", tables: [table])
    let request = try PopulatePlanRequest(
        table: table.qualifiedName,
        environment: .local,
        seed: 42,
        requestedRows: 10,
        limits: limits
    )
    let firstPlan = try PopulatePlanner.makePlan(request: request, snapshot: snapshot, currentRowCount: 0, currentSizeBytes: 0)
    let secondPlan = try PopulatePlanner.makePlan(request: request, snapshot: snapshot, currentRowCount: 0, currentSizeBytes: 0)

    #expect(firstPlan.planHash == secondPlan.planHash)
    #expect(firstPlan.id == secondPlan.id)
    #expect(firstPlan.rowCount == 10)

    let identifier = try #require(table.column(named: "id"))
    let firstID = try PopulateValueGenerator.value(for: identifier, in: table, rowOrdinal: 4, plan: firstPlan)
    let replayedID = try PopulateValueGenerator.value(for: identifier, in: table, rowOrdinal: 4, plan: secondPlan)
    #expect(firstID == replayedID)
    if case .uuid(let uuid) = firstID {
        #expect(((uuid.uuid.6 & 0xf0) >> 4) == 7)
    } else {
        Issue.record("UUID column did not produce a UUID value")
    }

    let slug = try #require(table.column(named: "slug"))
    let firstSlug = try PopulateValueGenerator.value(for: slug, in: table, rowOrdinal: 1, plan: firstPlan, forceUnique: true)
    let secondSlug = try PopulateValueGenerator.value(for: slug, in: table, rowOrdinal: 2, plan: firstPlan, forceUnique: true)
    #expect(firstSlug != secondSlug)

    let score = try #require(table.column(named: "score"))
    let generatedScore = try PopulateValueGenerator.value(for: score, in: table, rowOrdinal: 3, plan: firstPlan)
    if case .integer(let value) = generatedScore {
        #expect((10...20).contains(value))
    } else {
        Issue.record("integer check did not produce an integer")
    }
}

@Test func populateDependencyPlannerOrdersParentsAndRejectsCycles() throws {
    let parent = PopulateTable(
        schema: "public",
        name: "parents",
        columns: [PopulateColumn(name: "id", sqlType: "uuid", nullable: false)],
        primaryKey: ["id"]
    )
    let child = PopulateTable(
        schema: "public",
        name: "children",
        columns: [
            PopulateColumn(name: "id", sqlType: "uuid", nullable: false),
            PopulateColumn(name: "parent_id", sqlType: "uuid", nullable: false)
        ],
        primaryKey: ["id"],
        foreignKeys: [PopulateForeignKey(
            name: "children_parent_id_fkey",
            columns: ["parent_id"],
            referencedSchema: "public",
            referencedTable: "parents",
            referencedColumns: ["id"]
        )]
    )
    #expect(try PopulateDependencyPlanner.order(for: [child], knownTables: [parent, child]) == ["public.parents", "public.children"])

    let cyclicParent = PopulateTable(
        schema: "public",
        name: "parents",
        columns: [
            PopulateColumn(name: "id", sqlType: "uuid", nullable: false),
            PopulateColumn(name: "child_id", sqlType: "uuid", nullable: true)
        ],
        primaryKey: ["id"],
        foreignKeys: [PopulateForeignKey(
            name: "parents_child_id_fkey",
            columns: ["child_id"],
            referencedSchema: "public",
            referencedTable: "children",
            referencedColumns: ["id"]
        )]
    )
    #expect(throws: PopulatePlanError.self) {
        try PopulateDependencyPlanner.order(for: [cyclicParent], knownTables: [cyclicParent, child])
    }
}

@Test func populateReconcilerReportsModelAndAppliedMigrationDrift() throws {
    let desired = try SchemaIR(entities: [SchemaEntity(table: "notes", columns: [
        SchemaColumn(name: "id", type: .uuid, primaryKey: true),
        SchemaColumn(name: "body", type: .text)
    ])])
    let actual = PopulateSchemaSnapshot(databaseName: "local_dev", tables: [PopulateTable(
        schema: "public",
        name: "notes",
        columns: [
            PopulateColumn(name: "id", sqlType: "uuid", nullable: false),
            PopulateColumn(name: "body", sqlType: "text", nullable: false),
            PopulateColumn(name: "obsolete", sqlType: "text", nullable: true)
        ],
        primaryKey: ["id"]
    )])

    let report = try PopulateSchemaReconciler.reconcile(desired: desired, migrations: [], actual: actual)
    #expect(!report.isCompatible)
    #expect(report.differences.contains(where: { $0.path == "notes.obsolete" }))
}

@Test func populateAllowsOnlyBoundedDeterministicTextPrimaryKeys() throws {
    let limits = try PopulateExecutionLimits(maxRows: 2_000, maxBatchRows: 500, minimumFreeDiskBytes: 0)
    let table = PopulateTable(
        schema: "public",
        name: "badge_catalog",
        columns: [
            PopulateColumn(name: "id", sqlType: "character varying(80)", nullable: false, maximumLength: 80),
            PopulateColumn(name: "name", sqlType: "character varying(160)", nullable: false, maximumLength: 160)
        ],
        primaryKey: ["id"],
        uniqueConstraints: [PopulateUniqueConstraint(name: "badge_catalog_pkey", columns: ["id"])]
    )
    try PearfyPostgresPopulateAdapter.validateWritable(table, plannedRows: 2_000)

    let plan = try PopulatePlanRequest(
        table: table.qualifiedName,
        environment: .local,
        seed: 42,
        requestedRows: 2,
        limits: limits
    )
    let populatePlan = try PopulatePlanner.makePlan(
        request: plan,
        snapshot: PopulateSchemaSnapshot(databaseName: "local_dev", tables: [table]),
        currentRowCount: 0,
        currentSizeBytes: 0
    )
    let id = try #require(table.column(named: "id"))
    let first = try PopulateValueGenerator.value(for: id, in: table, rowOrdinal: 0, plan: populatePlan, forceUnique: true)
    let second = try PopulateValueGenerator.value(for: id, in: table, rowOrdinal: 1, plan: populatePlan, forceUnique: true)
    #expect(first != second)

    let shortKeyTable = PopulateTable(
        schema: "public",
        name: "short_key_catalog",
        columns: [PopulateColumn(name: "id", sqlType: "character varying(12)", nullable: false, maximumLength: 12)],
        primaryKey: ["id"],
        uniqueConstraints: [PopulateUniqueConstraint(name: "short_key_catalog_pkey", columns: ["id"])]
    )
    #expect(throws: PostgresPopulateError.missingPrimaryKey("public.short_key_catalog")) {
        try PearfyPostgresPopulateAdapter.validateWritable(shortKeyTable, plannedRows: 2_000)
    }
}

@Test func populateRunnerCheckpointsFailedBatchAndResumesWithoutDuplicatingOrdinals() async throws {
    let limits = try PopulateExecutionLimits(
        maxRows: 10,
        maxDurationSeconds: 60,
        maxBatchRows: 2,
        maxRetries: 0,
        minimumFreeDiskBytes: 0
    )
    let table = PopulateTable(
        schema: "public",
        name: "items",
        columns: [PopulateColumn(name: "id", sqlType: "uuid", nullable: false)],
        primaryKey: ["id"]
    )
    let snapshot = PopulateSchemaSnapshot(databaseName: "local_dev", tables: [table])
    let plan = try PopulatePlanner.makePlan(
        request: PopulatePlanRequest(table: table.qualifiedName, environment: .local, seed: 7, requestedRows: 5, limits: limits),
        snapshot: snapshot,
        currentRowCount: 0,
        currentSizeBytes: 0
    )
    let registry = InMemoryPopulateRunRegistry()
    let store = PartialFailurePopulateStore()
    let runner = PopulateRunner()

    let firstAttempt = try await runner.execute(
        plan: plan,
        approvalHash: plan.planHash,
        currentSchemaFingerprint: plan.schemaFingerprint,
        store: store,
        registry: registry
    )
    #expect(firstAttempt.status == .partial)
    #expect(firstAttempt.nextRowOrdinal == 2)
    #expect(firstAttempt.processedRows == 2)
    #expect(firstAttempt.insertedRows == 2)

    let resumed = try await runner.execute(
        plan: plan,
        approvalHash: plan.planHash,
        currentSchemaFingerprint: plan.schemaFingerprint,
        store: store,
        registry: registry
    )
    #expect(resumed.status == .complete)
    #expect(resumed.nextRowOrdinal == 5)
    #expect(resumed.processedRows == 5)
    #expect(resumed.insertedRows == 5)
    #expect(await store.persistedOrdinals == Set(0..<5))
}

@Test func populateRunnerRequiresApprovalAndUnchangedSchema() async throws {
    let limits = try PopulateExecutionLimits(maxRows: 5, minimumFreeDiskBytes: 0)
    let table = PopulateTable(schema: "public", name: "items", columns: [PopulateColumn(name: "id", sqlType: "uuid", nullable: false)], primaryKey: ["id"])
    let snapshot = PopulateSchemaSnapshot(databaseName: "local_dev", tables: [table])
    let plan = try PopulatePlanner.makePlan(
        request: PopulatePlanRequest(table: table.qualifiedName, environment: .local, requestedRows: 1, limits: limits),
        snapshot: snapshot,
        currentRowCount: 0,
        currentSizeBytes: 0
    )
    let runner = PopulateRunner()
    let store = PartialFailurePopulateStore()
    let registry = InMemoryPopulateRunRegistry()

    await #expect(throws: PopulateExecutionError.approvalMismatch) {
        try await runner.execute(plan: plan, approvalHash: "wrong", currentSchemaFingerprint: plan.schemaFingerprint, store: store, registry: registry)
    }
    await #expect(throws: PopulateExecutionError.self) {
        try await runner.execute(plan: plan, approvalHash: plan.planHash, currentSchemaFingerprint: "stale", store: store, registry: registry)
    }
}

@Test func populateRunnerStopsWithoutWritingWhenAbsoluteSizeTargetIsAlreadyMet() async throws {
    let limits = try PopulateExecutionLimits(maxRows: 10, maxBatchRows: 2, minimumFreeDiskBytes: 0)
    let table = PopulateTable(schema: "public", name: "items", columns: [PopulateColumn(name: "id", sqlType: "uuid", nullable: false)], primaryKey: ["id"])
    let snapshot = PopulateSchemaSnapshot(databaseName: "local_dev", tables: [table])
    let plan = try PopulatePlanner.makePlan(
        request: PopulatePlanRequest(
            table: table.qualifiedName,
            environment: .local,
            targetSizeBytes: 100,
            sizeMode: .total,
            limits: limits
        ),
        snapshot: snapshot,
        currentRowCount: 0,
        currentSizeBytes: 0
    )
    let store = PartialFailurePopulateStore()
    let registry = InMemoryPopulateRunRegistry()
    let state = try await PopulateRunner().execute(
        plan: plan,
        approvalHash: plan.planHash,
        currentSchemaFingerprint: plan.schemaFingerprint,
        store: store,
        registry: registry,
        currentSizeBytes: 100
    )

    #expect(state.status == .complete)
    #expect(state.processedRows == 0)
    #expect(state.latestSizeBytes == 100)
    #expect(await store.persistedOrdinals.isEmpty)
}

@Test func populateSafetyGuardRefusesProductionAndRemoteLocalTargets() throws {
    #expect(throws: PopulateSafetyError.productionLikeTarget("prod-db")) {
        try PopulateSafetyGuard.validate(environment: .local, host: "127.0.0.1", database: "prod-db")
    }
    #expect(throws: PopulateSafetyError.localTargetIsRemote("db.internal")) {
        try PopulateSafetyGuard.validate(environment: .local, host: "db.internal", database: "dev")
    }
    try PopulateSafetyGuard.validate(environment: .local, host: "127.0.0.1", database: "dev")
}

private actor InMemoryPopulateRunRegistry: PopulateRunRegistry {
    private var values: [String: PopulateRunState] = [:]

    func load(runID: String) -> PopulateRunState? { values[runID] }
    func save(_ state: PopulateRunState) { values[state.runID] = state }
}

private actor PartialFailurePopulateStore: PopulateExecutionStore {
    private var hasFailedSecondBatch = false
    private var rows: Set<Int> = []

    var persistedOrdinals: Set<Int> { rows }

    func insertRows(plan: PopulatePlan, ordinals: Range<Int>) throws -> PopulateBatchResult {
        if ordinals.lowerBound == 2 && !hasFailedSecondBatch {
            hasFailedSecondBatch = true
            throw FakePopulateFailure.batch
        }
        let before = rows.count
        rows.formUnion(ordinals)
        return PopulateBatchResult(insertedRows: rows.count - before)
    }
}

private enum FakePopulateFailure: Error {
    case batch
}
