import Crypto
import Foundation
import PearfyData
import PearfyLedger
import PearfyPostgres
import PearfyTransactions
import PostgresNIO

public enum PostgresFinancialRetryDisposition: Sendable, Equatable {
    case retryWholeTransaction
    case reconcileIdempotencyFirst
    case doNotRetry
}

public struct PostgresFinancialOperationStore: FinancialOperationStore, Sendable {
    private static let operations = "\"pearfy_financial_operations\""
    private static let entries = "\"pearfy_ledger_entries\""
    private let database: PearfyPostgresDatabase
    private let maximumAttempts: Int

    /// Retries are bounded to 1...3. A retried callback must perform only work
    /// enlisted in the provided transaction, never remote or external effects.
    public init(database: PearfyPostgresDatabase, maximumAttempts: Int = 1) throws {
        guard (1...3).contains(maximumAttempts) else { throw LedgerError.invalidOperation }
        self.database = database
        self.maximumAttempts = maximumAttempts
    }

    public func installSchema() async throws {
        try await SQLMigrationRunner().apply(Self.schemaMigrations, to: database)
    }

    public func perform(
        scope: String,
        idempotencyKey: String,
        canonicalParameters: Data,
        resourceKeys: [String],
        _ operation: @Sendable (any SQLTransaction) async throws -> FinancialOperation
    ) async throws -> FinancialOperationOutcome {
        try Self.validate(scope: scope, key: idempotencyKey, parameters: canonicalParameters)
        let resources = try Self.validatedResources(resourceKeys)
        let fingerprint = Self.fingerprint(canonicalParameters)
        var attempt = 1
        while true {
            do {
                return try await database.withTransaction { transaction in
                    try await Self.acquireIdempotencyLock(scope: scope, key: idempotencyKey, in: transaction)
                    if let existing = try await Self.readOperation(
                        scope: scope, key: idempotencyKey, fingerprint: fingerprint, in: transaction
                    ) {
                        return FinancialOperationOutcome(
                            operationID: existing.operationID, result: existing.result, replayed: true
                        )
                    }
                    try await Self.locker.acquire(resources, in: transaction)
                    let value = try await operation(transaction)
                    try FinancialOperation.validate(value.postings)
                    let locked = Set(resources)
                    guard value.postings.allSatisfy({ locked.contains($0.accountID) }) else {
                        throw LedgerError.invalidResourceKey
                    }
                    let operationID = UUIDv7.generate()
                    try await Self.persist(
                        operationID: operationID, scope: scope, key: idempotencyKey,
                        fingerprint: fingerprint, value: value, in: transaction
                    )
                    return FinancialOperationOutcome(
                        operationID: operationID, result: value.result, replayed: false
                    )
                }
            } catch {
                guard attempt < maximumAttempts,
                      Self.retryDisposition(for: error) == .retryWholeTransaction else {
                    throw error
                }
                try await Task.sleep(for: .milliseconds(min(100 * attempt, 500)))
                attempt += 1
            }
        }
    }

    public func reconcile(
        scope: String,
        idempotencyKey: String,
        canonicalParameters: Data
    ) async throws -> FinancialOperationOutcome? {
        try Self.validate(scope: scope, key: idempotencyKey, parameters: canonicalParameters)
        let fingerprint = Self.fingerprint(canonicalParameters)
        return try await database.withTransaction { transaction in
            try await Self.acquireIdempotencyLock(scope: scope, key: idempotencyKey, in: transaction)
            guard let existing = try await Self.readOperation(
                scope: scope, key: idempotencyKey, fingerprint: fingerprint, in: transaction
            ) else { return nil }
            return FinancialOperationOutcome(
                operationID: existing.operationID, result: existing.result, replayed: true
            )
        }
    }

    public func balance(accountID: String, currency: String, scale: UInt8) async throws -> LedgerMoney {
        try Self.validateResource(accountID)
        let currency = try Self.validatedCurrency(currency, scale: scale)
        let values = try await database.queryStrings(SQLQuery(
            unsafeSQL: Self.balanceQuery,
            parameters: [.text(accountID), .text(currency), .integer(Int64(scale))]
        ), column: "balance")
        return try Self.decodeBalance(values, currency: currency, scale: scale)
    }

    public func balance(
        accountID: String,
        currency: String,
        scale: UInt8,
        in transaction: any SQLTransaction
    ) async throws -> LedgerMoney {
        try Self.validateResource(accountID)
        let currency = try Self.validatedCurrency(currency, scale: scale)
        let values = try await transaction.queryStrings(SQLQuery(
            unsafeSQL: Self.balanceQuery,
            parameters: [.text(accountID), .text(currency), .integer(Int64(scale))]
        ), column: "balance")
        return try Self.decodeBalance(values, currency: currency, scale: scale)
    }

    public static func retryDisposition(for error: any Error) -> PostgresFinancialRetryDisposition {
        if error is TransactionCommitOutcomeUnknown { return .reconcileIdempotencyFirst }
        guard let postgresError = error as? PostgresError else { return .doNotRetry }
        return switch postgresError.code.raw {
        case "40001", "40P01": .retryWholeTransaction
        default: .doNotRetry
        }
    }

    private struct StoredOperation: Sendable {
        let operationID: UUID
        let result: Data
    }

    private static func readOperation(
        scope: String,
        key: String,
        fingerprint: Data,
        in transaction: any SQLTransaction
    ) async throws -> StoredOperation? {
        let rows = try await transaction.queryStrings(SQLQuery(
            unsafeSQL: """
            SELECT operation_id::TEXT || '|' || encode(parameter_digest, 'hex') || '|' || encode(result, 'hex') AS operation
            FROM \(operations)
            WHERE scope = $1 AND idempotency_key = $2
            """,
            parameters: [.text(scope), .text(key)]
        ), column: "operation")
        guard let row = rows.first else { return nil }
        let fields = row.split(separator: "|", omittingEmptySubsequences: false)
        guard fields.count == 3,
              let operationID = UUID(uuidString: String(fields[0])),
              let storedDigest = Data(hexString: String(fields[1])),
              let result = Data(hexString: String(fields[2])) else {
            throw LedgerError.corruptStoredOperation
        }
        guard storedDigest == fingerprint else { throw LedgerError.idempotencyConflict }
        return StoredOperation(operationID: operationID, result: result)
    }

    private static func persist(
        operationID: UUID,
        scope: String,
        key: String,
        fingerprint: Data,
        value: FinancialOperation,
        in transaction: any SQLTransaction
    ) async throws {
        try await transaction.execute(SQLQuery(
            unsafeSQL: """
            INSERT INTO \(operations) (operation_id, scope, idempotency_key, parameter_digest, result, ledger_posted)
            VALUES ($1, $2, $3, $4, $5, $6)
            """,
            parameters: [
                .uuid(operationID), .text(scope), .text(key), .bytes(fingerprint), .bytes(value.result),
                .boolean(!value.postings.isEmpty)
            ]
        ))
        for (index, posting) in value.postings.enumerated() {
            try await transaction.execute(SQLQuery(
                unsafeSQL: """
                INSERT INTO \(entries) (operation_id, entry_number, account_id, currency, scale, side, amount_minor)
                VALUES ($1, $2, $3, $4, $5, $6, $7)
                """,
                parameters: [
                    .uuid(operationID), .integer(Int64(index)), .text(posting.accountID),
                    .text(posting.amount.currency), .integer(Int64(posting.amount.scale)),
                    .text(posting.side.rawValue), .integer(posting.amount.minorUnits)
                ]
            ))
        }
    }

    private static func acquireIdempotencyLock(
        scope: String,
        key: String,
        in transaction: any SQLTransaction
    ) async throws {
        try await transaction.execute(SQLQuery(
            unsafeSQL: "SELECT pg_advisory_xact_lock(hashtextextended($1, 2))",
            parameters: [.text("pearfy:financial:idempotency:v1:\(scope):\(key)")]
        ))
    }

    private static let locker = PostgresFinancialResourceLocker()

    private static func validate(scope: String, key: String, parameters: Data) throws {
        guard !scope.isEmpty, scope.utf8.count <= 128,
              !key.isEmpty, key.utf8.count <= 256,
              !scope.utf8.contains(0), !key.utf8.contains(0) else {
            throw LedgerError.invalidScopeOrKey
        }
        guard parameters.count <= 262_144 else { throw LedgerError.invalidCanonicalParameters }
    }

    private static func validatedResources(_ resources: [String]) throws -> [String] {
        guard resources.count <= 256 else { throw LedgerError.invalidResourceKey }
        for resource in resources { try validateResource(resource) }
        return Array(Set(resources)).sorted { $0.utf8.lexicographicallyPrecedes($1.utf8) }
    }

    private static func validateResource(_ value: String) throws {
        guard !value.isEmpty, value.utf8.count <= 256, !value.utf8.contains(0) else {
            throw LedgerError.invalidResourceKey
        }
    }

    private static func validatedCurrency(_ currency: String, scale: UInt8) throws -> String {
        _ = try LedgerMoney(minorUnits: 0, currency: currency, scale: scale)
        return currency
    }

    private static func fingerprint(_ parameters: Data) -> Data {
        Data(SHA256.hash(data: parameters))
    }

    private static let balanceQuery = """
        SELECT COALESCE(SUM(CASE WHEN side = 'credit' THEN amount_minor ELSE -amount_minor END), 0)::TEXT AS balance
        FROM \(entries)
        WHERE account_id = $1 AND currency = $2 AND scale = $3
        """

    private static func decodeBalance(
        _ values: [String],
        currency: String,
        scale: UInt8
    ) throws -> LedgerMoney {
        guard let raw = values.first, let minorUnits = Int64(raw) else { throw LedgerError.arithmeticOverflow }
        return try LedgerMoney(minorUnits: minorUnits, currency: currency, scale: scale)
    }

    private static let schemaMigrations: [SQLMigration] = [
        SQLMigration(
            id: "ledger-v1-01-core",
            up: SQLQuery(unsafeSQL: """
            CREATE TABLE "pearfy_financial_operations" (
                operation_id UUID PRIMARY KEY,
                scope TEXT NOT NULL CHECK (length(scope) BETWEEN 1 AND 128),
                idempotency_key TEXT NOT NULL CHECK (length(idempotency_key) BETWEEN 1 AND 256),
                parameter_digest BYTEA NOT NULL CHECK (octet_length(parameter_digest) = 32),
                result BYTEA NOT NULL CHECK (octet_length(result) <= 262144),
                ledger_posted BOOLEAN NOT NULL,
                created_txid BIGINT NOT NULL DEFAULT txid_current(),
                created_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
                UNIQUE (scope, idempotency_key)
            );
            CREATE TABLE "pearfy_ledger_entries" (
                operation_id UUID NOT NULL REFERENCES "pearfy_financial_operations"(operation_id),
                entry_number INTEGER NOT NULL CHECK (entry_number >= 0),
                account_id TEXT NOT NULL CHECK (length(account_id) BETWEEN 1 AND 128),
                currency CHAR(3) NOT NULL CHECK (currency ~ '^[A-Z]{3}$'),
                scale SMALLINT NOT NULL CHECK (scale BETWEEN 0 AND 9),
                side TEXT NOT NULL CHECK (side IN ('debit', 'credit')),
                amount_minor BIGINT NOT NULL CHECK (amount_minor > 0),
                PRIMARY KEY (operation_id, entry_number)
            );
            CREATE INDEX "pearfy_ledger_entries_account_idx"
                ON "pearfy_ledger_entries" (account_id, currency, scale, operation_id);
            CREATE FUNCTION "pearfy_ledger_reject_mutation"() RETURNS trigger AS $$
            BEGIN
                RAISE EXCEPTION 'Pearfy ledger history is append-only' USING ERRCODE = '55000';
            END;
            $$ LANGUAGE plpgsql;
            CREATE TRIGGER "pearfy_financial_operations_append_only"
                BEFORE UPDATE OR DELETE ON "pearfy_financial_operations"
                FOR EACH ROW EXECUTE FUNCTION "pearfy_ledger_reject_mutation"();
            CREATE TRIGGER "pearfy_ledger_entries_append_only"
                BEFORE UPDATE OR DELETE ON "pearfy_ledger_entries"
                FOR EACH ROW EXECUTE FUNCTION "pearfy_ledger_reject_mutation"();
            CREATE FUNCTION "pearfy_ledger_require_operation_transaction"() RETURNS trigger AS $$
            DECLARE operation_txid BIGINT;
            BEGIN
                SELECT created_txid INTO operation_txid
                FROM "pearfy_financial_operations"
                WHERE operation_id = NEW.operation_id;
                IF operation_txid IS NULL OR operation_txid <> txid_current() THEN
                    RAISE EXCEPTION 'Pearfy ledger entries must be appended with their operation'
                        USING ERRCODE = '55000';
                END IF;
                RETURN NEW;
            END;
            $$ LANGUAGE plpgsql;
            CREATE TRIGGER "pearfy_ledger_entries_same_transaction"
                BEFORE INSERT ON "pearfy_ledger_entries"
                FOR EACH ROW EXECUTE FUNCTION "pearfy_ledger_require_operation_transaction"();
            CREATE FUNCTION "pearfy_ledger_validate_operation"() RETURNS trigger AS $$
            DECLARE entry_count BIGINT;
            BEGIN
                SELECT count(*) INTO entry_count FROM "pearfy_ledger_entries" WHERE operation_id = NEW.operation_id;
                IF NEW.ledger_posted THEN
                    IF entry_count < 2 THEN
                        RAISE EXCEPTION 'Pearfy ledger operation requires at least two entries' USING ERRCODE = '23514';
                    END IF;
                    IF EXISTS (
                        SELECT 1 FROM "pearfy_ledger_entries"
                        WHERE operation_id = NEW.operation_id
                        GROUP BY currency, scale
                        HAVING SUM(CASE WHEN side = 'debit' THEN amount_minor ELSE -amount_minor END) <> 0
                    ) THEN
                        RAISE EXCEPTION 'Pearfy ledger operation is unbalanced' USING ERRCODE = '23514';
                    END IF;
                ELSIF entry_count <> 0 THEN
                    RAISE EXCEPTION 'Pearfy operation entry flag does not match entries' USING ERRCODE = '23514';
                END IF;
                RETURN NEW;
            END;
            $$ LANGUAGE plpgsql;
            CREATE CONSTRAINT TRIGGER "pearfy_ledger_validate_operation_deferred"
                AFTER INSERT ON "pearfy_financial_operations"
                DEFERRABLE INITIALLY DEFERRED
                FOR EACH ROW EXECUTE FUNCTION "pearfy_ledger_validate_operation"();
            """),
            down: SQLQuery(unsafeSQL: """
            DROP TABLE IF EXISTS "pearfy_ledger_entries";
            DROP TABLE IF EXISTS "pearfy_financial_operations";
            DROP FUNCTION IF EXISTS "pearfy_ledger_validate_operation"();
            DROP FUNCTION IF EXISTS "pearfy_ledger_require_operation_transaction"();
            DROP FUNCTION IF EXISTS "pearfy_ledger_reject_mutation"();
            """)
        )
    ]
}

public struct PostgresFinancialResourceLocker: FinancialResourceLocking, Sendable {
    public init() {}

    public func acquire(_ resourceKeys: [String], in transaction: any SQLTransaction) async throws {
        let ordered = Array(Set(resourceKeys)).sorted { $0.utf8.lexicographicallyPrecedes($1.utf8) }
        guard ordered.count <= 256 else { throw LedgerError.invalidResourceKey }
        for key in ordered {
            guard !key.isEmpty, key.utf8.count <= 256, !key.utf8.contains(0) else {
                throw LedgerError.invalidResourceKey
            }
            try await transaction.execute(SQLQuery(
                unsafeSQL: "SELECT pg_advisory_xact_lock(hashtextextended($1, 1))",
                parameters: [.text("pearfy:financial:resource:v1:\(key)")]
            ))
        }
    }
}

private extension Data {
    init?(hexString: String) {
        guard hexString.utf8.count.isMultiple(of: 2) else { return nil }
        var data = Data()
        data.reserveCapacity(hexString.utf8.count / 2)
        var iterator = hexString.utf8.makeIterator()
        while let high = iterator.next(), let low = iterator.next() {
            guard let upper = Self.hexValue(high), let lower = Self.hexValue(low) else { return nil }
            data.append((upper << 4) | lower)
        }
        self = data
    }

    static func hexValue(_ byte: UInt8) -> UInt8? {
        switch byte {
        case 48...57: byte - 48
        case 65...70: byte - 55
        case 97...102: byte - 87
        default: nil
        }
    }
}
