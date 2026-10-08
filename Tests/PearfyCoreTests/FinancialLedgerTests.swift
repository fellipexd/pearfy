import Foundation
import PearfyData
import PearfyCLIKit
import PearfyLedger
import PearfyLedgerPostgres
import PearfyPostgres
import PearfySecurity
import PearfyTransactions
import PostgresNIO
import Testing

@Test func ledgerMoneyParsesExactValuesAndRejectsImplicitRounding() throws {
    let value = try LedgerMoney(decimal: "123456789.23", currency: "USD", scale: 2)
    #expect(value.minorUnits == 12_345_678_923)
    #expect(value.description == "123456789.23 USD")
    #expect(try LedgerMoney(decimal: "-0.01", currency: "USD", scale: 2).minorUnits == -1)
    #expect(try LedgerMoney(decimal: "1", currency: "JPY", scale: 0).description == "1 JPY")
    #expect(throws: LedgerError.decimalPrecisionExceedsScale) {
        try LedgerMoney(decimal: "1.001", currency: "USD", scale: 2)
    }
    #expect(throws: LedgerError.invalidCurrency) {
        try LedgerMoney(decimal: "1.00", currency: "usd", scale: 2)
    }
    #expect(throws: LedgerError.arithmeticOverflow) {
        try LedgerMoney(decimal: "92233720368547758.08", currency: "USD", scale: 2)
    }
}

@Test func ledgerMoneyArithmeticRequiresMatchingCurrencyAndScale() throws {
    let one = try LedgerMoney(minorUnits: 1, currency: "USD", scale: 2)
    let max = try LedgerMoney(minorUnits: .max, currency: "USD", scale: 2)
    #expect(throws: LedgerError.arithmeticOverflow) { try max.adding(one) }
    #expect(throws: LedgerError.invalidMoneyAmount) {
        try one.adding(LedgerMoney(minorUnits: 1, currency: "EUR", scale: 2))
    }
}

@Test func ledgerRejectsUnbalancedOrInvalidPostingSets() throws {
    let debit = try LedgerPosting(
        accountID: "cash",
        side: .debit,
        amount: LedgerMoney(minorUnits: 125, currency: "USD", scale: 2)
    )
    let credit = try LedgerPosting(
        accountID: "clearing",
        side: .credit,
        amount: LedgerMoney(minorUnits: 125, currency: "USD", scale: 2)
    )
    _ = try FinancialOperation(result: Data("ok".utf8), postings: [debit, credit])
    let wrongAmount = try LedgerPosting(
        accountID: "clearing",
        side: .credit,
        amount: LedgerMoney(minorUnits: 126, currency: "USD", scale: 2)
    )
    #expect(throws: LedgerError.unbalanced(currency: "USD", scale: 2)) {
        try FinancialOperation(result: Data(), postings: [debit, wrongAmount])
    }
    let otherCurrency = try LedgerPosting(
        accountID: "other",
        side: .credit,
        amount: LedgerMoney(minorUnits: 125, currency: "EUR", scale: 2)
    )
    #expect(throws: LedgerError.unbalanced(currency: "EUR", scale: 2)) {
        try FinancialOperation(result: Data(), postings: [debit, otherCurrency])
    }
}

@Test func sqlExactDecimalIsBoundedCodableAndDoesNotChangeLegacyDecimalEncoding() throws {
    let decimal = try SQLExactDecimal("123456789012345678901234567890.0001")
    let exact = SQLValue.exactDecimal(decimal)
    let data = try JSONEncoder().encode(exact)
    #expect(try JSONDecoder().decode(SQLValue.self, from: data) == exact)
    #expect(throws: SQLQueryError.invalidDecimal) { try SQLExactDecimal("1e9") }
    #expect(throws: SQLQueryError.invalidDecimal) { try SQLExactDecimal("1; DROP TABLE x") }
    #expect(throws: SQLQueryError.invalidDecimal) { try SQLExactDecimal(String(repeating: "9", count: 257)) }
    #expect(throws: DecodingError.self) {
        try JSONDecoder().decode(SQLExactDecimal.self, from: Data(#"{"rawValue":"1e9"}"#.utf8))
    }

    let legacy = SQLValue.decimal(0.1)
    #expect(try JSONDecoder().decode(SQLValue.self, from: JSONEncoder().encode(legacy)) == legacy)
}

@Test func monetaryCodableRevalidatesValuesWhenDecoding() throws {
    let invalidMoney = Data(#"{"minorUnits":1,"currency":"usd","scale":2}"#.utf8)
    #expect(throws: LedgerError.invalidCurrency) {
        try JSONDecoder().decode(LedgerMoney.self, from: invalidMoney)
    }
    let invalidPosting = Data(#"{"accountID":"","side":"debit","amount":{"minorUnits":1,"currency":"USD","scale":2}}"#.utf8)
    #expect(throws: LedgerError.invalidAccountIdentifier) {
        try JSONDecoder().decode(LedgerPosting.self, from: invalidPosting)
    }
}

@Test func postgresRetryClassificationSeparatesRollbackFromUnknownCommit() {
    #expect(PostgresFinancialOperationStore.retryDisposition(
        for: TransactionCommitOutcomeUnknown(transactionID: UUID(), reason: "connection lost")
    ) == .reconcileIdempotencyFirst)
    #expect(PostgresFinancialOperationStore.retryDisposition(for: CancellationError()) == .doNotRetry)
}

@Test func ledgerIsInstallableAsItsOwnModuleWithoutMarkingPaymentsAvailable() throws {
    let manager = try PearfyModuleManager()
    let plan = try manager.planAdding("ledger", to: ["http", "postgres"])
    #expect(plan.productsToAdd == ["PearfyLedger", "PearfyLedgerPostgres"])
    let payments = try manager.module(named: "payments")
    #expect(!payments.available)
    #expect(payments.implementationStatus == .planned)
}

@Test func postgresFinancialStorePersistsBalancedOperationAndReplaysSameKey() async throws {
    guard let database = try await makeFinancialTestDatabase() else { return }
    let store = try PostgresFinancialOperationStore(database: database)
    do {
        let exactNumeric = try SQLExactDecimal("123456789012345678901234567890.0001")
        let roundTrip = try await database.queryStrings(SQLQuery(
            unsafeSQL: "SELECT $1::NUMERIC::TEXT AS value",
            parameters: [.exactDecimal(exactNumeric)]
        ), column: "value")
        #expect(roundTrip == ["123456789012345678901234567890.0001"])

        try await store.installSchema()
        let scope = "integration:\(UUID().uuidString)"
        let key = "operation-1"
        let parameters = Data("transfer:v1:cash:clearing:125".utf8)
        let entries = try transferPostings(amount: 125, debitAccount: "cash", creditAccount: "clearing")
        let first = try await store.perform(
            scope: scope,
            idempotencyKey: key,
            canonicalParameters: parameters,
            resourceKeys: ["cash", "clearing"]
        ) { _ in
            try FinancialOperation(result: Data("result-1".utf8), postings: entries)
        }
        let replay = try await store.perform(
            scope: scope,
            idempotencyKey: key,
            canonicalParameters: parameters,
            resourceKeys: ["cash", "clearing"]
        ) { _ in
            Issue.record("A replay must not execute the operation callback")
            return try FinancialOperation(result: Data("wrong".utf8), postings: [])
        }
        #expect(first.replayed == false)
        #expect(replay.replayed)
        #expect(first.operationID == replay.operationID)
        #expect(replay.result == Data("result-1".utf8))
        #expect(try await store.balance(accountID: "cash", currency: "USD", scale: 2).minorUnits == -125)
        #expect(try await store.balance(accountID: "clearing", currency: "USD", scale: 2).minorUnits == 125)

        do {
            _ = try await store.perform(
                scope: scope,
                idempotencyKey: key,
                canonicalParameters: Data("different-transfer".utf8),
                resourceKeys: ["cash", "clearing"]
            ) { _ in
                Issue.record("A conflicting key must not execute the callback")
                return try FinancialOperation(result: Data(), postings: [])
            }
            Issue.record("Expected an idempotency conflict")
        } catch LedgerError.idempotencyConflict {
        }

        let reconciled = try await store.reconcile(
            scope: scope,
            idempotencyKey: key,
            canonicalParameters: parameters
        )
        #expect(reconciled?.operationID == first.operationID)

        let isolatedScope = try await store.perform(
            scope: "\(scope):other-tenant",
            idempotencyKey: key,
            canonicalParameters: parameters,
            resourceKeys: []
        ) { _ in try FinancialOperation(result: Data("other-scope".utf8)) }
        #expect(!isolatedScope.replayed)
        #expect(isolatedScope.operationID != first.operationID)

        var mutationRejected = false
        do {
            try await database.execute(SQLQuery(
                unsafeSQL: "UPDATE \"pearfy_ledger_entries\" SET amount_minor = 1 WHERE operation_id = $1",
                parameters: [.uuid(first.operationID)]
            ))
        } catch {
            mutationRejected = true
        }
        #expect(mutationRejected)

        var lateAppendRejected = false
        do {
            try await database.execute(SQLQuery(
                unsafeSQL: """
                INSERT INTO "pearfy_ledger_entries"
                    (operation_id, entry_number, account_id, currency, scale, side, amount_minor)
                VALUES ($1, 999, 'late-entry', 'USD', 2, 'debit', 1)
                """,
                parameters: [.uuid(first.operationID)]
            ))
        } catch {
            lateAppendRejected = true
        }
        #expect(lateAppendRejected)
    } catch {
        try? await database.stop()
        throw error
    }
    try await database.stop()
}

@Test func postgresFinancialStoreReplaysConcurrentSameKeyAcrossIndependentClients() async throws {
    guard let firstDatabase = try await makeFinancialTestDatabase(maximumConnections: 4) else { return }
    guard let secondDatabase = try await makeSecondFinancialTestDatabase(maximumConnections: 4) else {
        try await firstDatabase.stop()
        return
    }
    let firstStore = try PostgresFinancialOperationStore(database: firstDatabase)
    let secondStore = try PostgresFinancialOperationStore(database: secondDatabase)
    let callbackCount = FinancialLedgerCallbackCounter()
    do {
        try await firstStore.installSchema()
        let scope = "concurrent-idempotency:\(UUID().uuidString)"
        let parameters = Data("same-canonical-operation".utf8)
        let run: @Sendable (PostgresFinancialOperationStore) async throws -> FinancialOperationOutcome = { store in
            try await store.perform(
                scope: scope,
                idempotencyKey: "same-key",
                canonicalParameters: parameters,
                resourceKeys: []
            ) { _ in
                await callbackCount.increment()
                try await Task.sleep(for: .milliseconds(20))
                return try FinancialOperation(result: Data("one-result".utf8))
            }
        }
        async let first = run(firstStore)
        async let second = run(secondStore)
        let outcomes = try await [first, second]
        #expect(outcomes[0].operationID == outcomes[1].operationID)
        #expect(outcomes.filter(\.replayed).count == 1)
        #expect(await callbackCount.value == 1)
    } catch {
        try? await firstDatabase.stop()
        try? await secondDatabase.stop()
        throw error
    }
    try await firstDatabase.stop()
    try await secondDatabase.stop()
}

@Test func postgresFinancialStoreRollsBackCallbackAndLedgerTogether() async throws {
    guard let database = try await makeFinancialTestDatabase() else { return }
    let store = try PostgresFinancialOperationStore(database: database)
    try await store.installSchema()
    let scope = "rollback:\(UUID().uuidString)"
    let parameters = Data("rollback-case".utf8)
    let table = try SQLIdentifier("pearfy_financial_rollback_\(UUID().uuidString.replacingOccurrences(of: "-", with: ""))")
    try await database.execute(SQLQuery(unsafeSQL: "CREATE TABLE \(table) (id TEXT PRIMARY KEY)"))
    do {
        _ = try await store.perform(
            scope: scope,
            idempotencyKey: "rollback-key",
            canonicalParameters: parameters,
            resourceKeys: []
        ) { transaction in
            try await transaction.execute(SQLQuery(
                unsafeSQL: "INSERT INTO \(table) (id) VALUES ('domain-change')"
            ))
            throw FinancialLedgerTestFailure.beforeCommit
        }
        Issue.record("Expected the callback failure")
    } catch FinancialLedgerTestFailure.beforeCommit {
    }
    #expect(try await database.queryStrings(
        SQLQuery(unsafeSQL: "SELECT id FROM \(table)"),
        column: "id"
    ).isEmpty)
    #expect(try await store.reconcile(
        scope: scope,
        idempotencyKey: "rollback-key",
        canonicalParameters: parameters
    ) == nil)

    let completed = try await store.perform(
        scope: scope,
        idempotencyKey: "rollback-key",
        canonicalParameters: parameters,
        resourceKeys: []
    ) { _ in try FinancialOperation(result: Data("retry-after-known-rollback".utf8)) }
    #expect(!completed.replayed)
    try await database.execute(SQLQuery(unsafeSQL: "DROP TABLE \(table)"))
    try await database.stop()
}

@Test func postgresFinancialStoreSerializesTwoIndependentClientsBeforeBalanceCheck() async throws {
    guard let firstDatabase = try await makeFinancialTestDatabase(maximumConnections: 4) else { return }
    guard let secondDatabase = try await makeSecondFinancialTestDatabase(maximumConnections: 4) else {
        try await firstDatabase.stop()
        return
    }
    let firstStore = try PostgresFinancialOperationStore(database: firstDatabase)
    let secondStore = try PostgresFinancialOperationStore(database: secondDatabase)
    do {
        try await firstStore.installSchema()
        let scope = "race:\(UUID().uuidString)"
        let seed = try await firstStore.perform(
            scope: scope,
            idempotencyKey: "seed",
            canonicalParameters: Data("seed".utf8),
            resourceKeys: ["cash", "opening-equity"]
        ) { _ in
            try FinancialOperation(result: Data("seeded".utf8), postings: transferPostings(
                amount: 10_000, debitAccount: "opening-equity", creditAccount: "cash"
            ))
        }
        #expect(!seed.replayed)

        let attempt: @Sendable (PostgresFinancialOperationStore, String) async throws -> Bool = { store, key in
            do {
                _ = try await store.perform(
                    scope: scope,
                    idempotencyKey: key,
                    canonicalParameters: Data(key.utf8),
                    resourceKeys: ["cash", "merchant-\(key)"]
                ) { transaction in
                    let available = try await store.balance(
                        accountID: "cash", currency: "USD", scale: 2, in: transaction
                    )
                    guard available.minorUnits >= 7_500 else {
                        throw FinancialLedgerTestFailure.insufficientFunds
                    }
                    return try FinancialOperation(
                        result: Data(key.utf8),
                        postings: transferPostings(
                            amount: 7_500, debitAccount: "cash", creditAccount: "merchant-\(key)"
                        )
                    )
                }
                return true
            } catch FinancialLedgerTestFailure.insufficientFunds {
                return false
            }
        }
        async let first = attempt(firstStore, "one")
        async let second = attempt(secondStore, "two")
        let results = try await [first, second]
        #expect(results.filter { $0 }.count == 1)
        #expect(try await firstStore.balance(accountID: "cash", currency: "USD", scale: 2).minorUnits == 2_500)
    } catch {
        try? await firstDatabase.stop()
        try? await secondDatabase.stop()
        throw error
    }
    try await firstDatabase.stop()
    try await secondDatabase.stop()
}

private enum FinancialLedgerTestFailure: Error, Sendable {
    case beforeCommit
    case insufficientFunds
}

private actor FinancialLedgerCallbackCounter {
    private(set) var value = 0

    func increment() { value += 1 }
}

private func transferPostings(
    amount: Int64,
    debitAccount: String,
    creditAccount: String
) throws -> [LedgerPosting] {
    [
        try LedgerPosting(
            accountID: debitAccount,
            side: .debit,
            amount: LedgerMoney(minorUnits: amount, currency: "USD", scale: 2)
        ),
        try LedgerPosting(
            accountID: creditAccount,
            side: .credit,
            amount: LedgerMoney(minorUnits: amount, currency: "USD", scale: 2)
        )
    ]
}

private func makeFinancialTestDatabase(maximumConnections: Int = 2) async throws -> PearfyPostgresDatabase? {
    guard let host = ProcessInfo.processInfo.environment["PEARFY_TEST_POSTGRES_HOST"] else { return nil }
    let port = Int(ProcessInfo.processInfo.environment["PEARFY_TEST_POSTGRES_PORT"] ?? "5432") ?? 5432
    let username = ProcessInfo.processInfo.environment["PEARFY_TEST_POSTGRES_USER"] ?? "postgres"
    let databaseName = ProcessInfo.processInfo.environment["PEARFY_TEST_POSTGRES_DATABASE"] ?? username
    let password = ProcessInfo.processInfo.environment["PEARFY_TEST_POSTGRES_PASSWORD"]
    let database = PearfyPostgresDatabase(settings: try PearfyPostgresConnectionSettings(
        host: host,
        port: port,
        username: username,
        password: password,
        database: databaseName,
        tls: .disabled,
        maximumConnections: maximumConnections
    ))
    try await database.start()
    return database
}

private func makeSecondFinancialTestDatabase(maximumConnections: Int) async throws -> PearfyPostgresDatabase? {
    try await makeFinancialTestDatabase(maximumConnections: maximumConnections)
}
