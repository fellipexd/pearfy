import Foundation
import PearfyCLIKit
import PearfyData
import Testing

@Test func modelBasedMigrationGenerationCreatesAnOrderedPearfyCatalogWithoutDatabaseAccess() async throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("pearfy-model-migration-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let models = root.appendingPathComponent(".pearfy", isDirectory: true)
    try FileManager.default.createDirectory(at: models, withIntermediateDirectories: true)
    let model = try SchemaIR(entities: [SchemaEntity(
        table: "accounts",
        columns: [
            SchemaColumn(name: "id", type: .uuid, primaryKey: true, identifierStrategy: .uuidV7),
            SchemaColumn(name: "email", type: .text, unique: true)
        ],
        indexes: [SchemaIndex(name: "accounts_email_idx", columns: ["email"])]
    )])
    try model.canonicalJSON().write(to: models.appendingPathComponent("schema.json"))

    #expect(try await PearfyMigrationsCommand.run(
        arguments: ["generate", "--id", "000051_embersquare_baseline"],
        projectRoot: root
    ) == 0)

    let catalog = try SQLMigrationCatalog(directory: root.appendingPathComponent("Migrations"))
    #expect(catalog.migrations.map(\.id) == ["000051_embersquare_baseline"])
    #expect(catalog.migrations[0].up.statement.contains("CREATE TABLE \"accounts\""))
    #expect(catalog.migrations[0].up.statement.contains("CREATE INDEX \"accounts_email_idx\""))
}

@Test func modelBasedMigrationGenerationReplacesAnExistingCatalogOnlyWhenRequested() async throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("pearfy-model-migration-replace-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let modelDirectory = root.appendingPathComponent(".pearfy", isDirectory: true)
    let output = root.appendingPathComponent("Migrations", isDirectory: true)
    try FileManager.default.createDirectory(at: modelDirectory, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
    let model = try SchemaIR(entities: [SchemaEntity(
        table: "accounts",
        columns: [SchemaColumn(name: "id", type: .uuid, primaryKey: true)]
    )])
    try model.canonicalJSON().write(to: modelDirectory.appendingPathComponent("schema.json"))
    let oldArtifact = SQLMigrationArtifact(
        id: "000001_old_import",
        up: SQLMigrationCommand(sql: "CREATE TABLE old_import (id UUID PRIMARY KEY);")
    )
    try oldArtifact.canonicalJSON().write(to: output.appendingPathComponent("000001_old_import.json"))

    await #expect(throws: Error.self) {
        try await PearfyMigrationsCommand.run(
            arguments: ["generate", "--id", "000051_embersquare_baseline"],
            projectRoot: root
        )
    }
    #expect(FileManager.default.fileExists(atPath: output.appendingPathComponent("000001_old_import.json").path))

    #expect(try await PearfyMigrationsCommand.run(
        arguments: ["generate", "--id", "000051_embersquare_baseline", "--replace-catalog"],
        projectRoot: root
    ) == 0)
    let catalog = try SQLMigrationCatalog(directory: output)
    #expect(catalog.migrations.map(\.id) == ["000051_embersquare_baseline"])
    #expect(!FileManager.default.fileExists(atPath: output.appendingPathComponent("000001_old_import.json").path))
}

@Test func javaMigrationImportCreatesAnOrderedPearfyCatalogWithoutChangingSource() async throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("pearfy-migration-import-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let source = root.appendingPathComponent("legacy", isDirectory: true)
    let output = root.appendingPathComponent("Migrations", isDirectory: true)
    try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)

    let firstUp = "CREATE FUNCTION sample() RETURNS void AS $$ BEGIN PERFORM 1; END; $$ LANGUAGE plpgsql;\nCREATE TABLE sample (id UUID PRIMARY KEY);\n"
    let firstDown = "DROP TABLE IF EXISTS sample;\nDROP FUNCTION IF EXISTS sample();\n"
    try Data(firstUp.utf8).write(to: source.appendingPathComponent("000001_foundation.up.sql"))
    try Data(firstDown.utf8).write(to: source.appendingPathComponent("000001_foundation.down.sql"))
    try Data("CREATE INDEX sample_id_idx ON sample (id);\n".utf8)
        .write(to: source.appendingPathComponent("000002_sample_index.up.sql"))

    #expect(try await PearfyMigrationsCommand.run(
        arguments: ["import-java", "--source", source.path, "--output", output.path],
        projectRoot: root
    ) == 0)

    let catalog = try SQLMigrationCatalog(directory: output)
    #expect(catalog.migrations.map(\.id) == ["000001_foundation", "000002_sample_index"])
    #expect(catalog.migrations[0].up.statement == firstUp)
    #expect(catalog.migrations[0].down?.statement == firstDown)
    #expect(FileManager.default.fileExists(atPath: source.appendingPathComponent("000001_foundation.up.sql").path))
}

@Test func javaMigrationImportRemovesOnlySourcesAfterCatalogValidationWhenRequested() async throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("pearfy-migration-retire-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let source = root.appendingPathComponent("legacy", isDirectory: true)
    let output = root.appendingPathComponent("Migrations", isDirectory: true)
    try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
    let up = source.appendingPathComponent("000001_foundation.up.sql")
    let down = source.appendingPathComponent("000001_foundation.down.sql")
    try Data("CREATE TABLE sample (id UUID PRIMARY KEY);".utf8).write(to: up)
    try Data("DROP TABLE sample;".utf8).write(to: down)

    #expect(try await PearfyMigrationsCommand.run(
        arguments: ["import-java", "--source", source.path, "--output", output.path, "--remove-source"],
        projectRoot: root
    ) == 0)

    #expect(FileManager.default.fileExists(atPath: output.appendingPathComponent("000001_foundation.json").path))
    #expect(!FileManager.default.fileExists(atPath: up.path))
    #expect(!FileManager.default.fileExists(atPath: down.path))
}

@Test func javaMigrationImportRejectsVersionGapsBeforeCreatingOutput() async throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("pearfy-migration-gap-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let source = root.appendingPathComponent("legacy", isDirectory: true)
    let output = root.appendingPathComponent("Migrations", isDirectory: true)
    try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
    try Data("SELECT 1;".utf8).write(to: source.appendingPathComponent("000001_first.up.sql"))
    try Data("SELECT 3;".utf8).write(to: source.appendingPathComponent("000003_third.up.sql"))

    await #expect(throws: Error.self) {
        try await PearfyMigrationsCommand.run(
            arguments: ["import-java", "--source", source.path, "--output", output.path],
            projectRoot: root
        )
    }
    #expect(!FileManager.default.fileExists(atPath: output.path))
}
