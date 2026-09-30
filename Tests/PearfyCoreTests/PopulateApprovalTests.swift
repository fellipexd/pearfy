import Foundation
import PearfyPopulateCLI
import PearfyPopulateCore
import Testing

@Test func populateApprovalTokenIsBoundToPlanEnvironmentAndDatabase() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("pearfy-populate-approval-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let table = PopulateTable(
        schema: "public",
        name: "records",
        columns: [PopulateColumn(name: "id", sqlType: "uuid", nullable: false)],
        primaryKey: ["id"]
    )
    let snapshot = PopulateSchemaSnapshot(databaseName: "dev_local", tables: [table])
    let plan = try PopulatePlanner.makePlan(
        request: PopulatePlanRequest(table: table.qualifiedName, environment: .local, requestedRows: 5),
        snapshot: snapshot,
        currentRowCount: 0,
        currentSizeBytes: 0
    )
    let store = PopulateApprovalStore(projectRoot: root)
    let token = try store.issue(plan: plan, confirmation: "approve \(plan.planHash)")

    try store.validate(token: token, plan: plan, environment: .local, databaseName: "dev_local")
    #expect(throws: PopulateApprovalError.self) {
        try store.validate(token: "wrong-token", plan: plan, environment: .local, databaseName: "dev_local")
    }
    #expect(throws: PopulateApprovalError.self) {
        try store.validate(token: token, plan: plan, environment: .staging, databaseName: "dev_local")
    }
    #expect(throws: PopulateApprovalError.self) {
        try store.validate(token: token, plan: plan, environment: .local, databaseName: "other_db")
    }
}
