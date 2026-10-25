import Foundation
import GRDB

final class DatabaseManager {
    static let shared = DatabaseManager()

    let dbPool: DatabasePool

    private init() {
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first!
        let dbDirectory = appSupport
            .appendingPathComponent("Aonsoku", isDirectory: true)
            .appendingPathComponent("Database", isDirectory: true)

        try! FileManager.default.createDirectory(
            at: dbDirectory, withIntermediateDirectories: true
        )

        let dbPath = dbDirectory.appendingPathComponent("library.sqlite").path

        dbPool = try! Self.makePool(path: dbPath)
    }

    init(path: String) throws {
        dbPool = try Self.makePool(path: path)
    }

    private static func makePool(path: String) throws -> DatabasePool {
        var config = Configuration()
        config.prepareDatabase { db in
            #if DEBUG
            db.trace { NativeLogger.shared.debug("\($0)", source: "SQL") }
            #endif
            db.add(function: DatabaseManager.normalizeFunction)
        }

        let dbPool = try DatabasePool(path: path, configuration: config)

        var migrator = DatabaseMigrator()
        Migrations.registerAll(&migrator)
        try migrator.migrate(dbPool)
        return dbPool
    }

    var reader: DatabaseReader { dbPool }
    var writer: DatabaseWriter { dbPool }

    static let normalizeFunction = DatabaseFunction(
        "normalize", argumentCount: 1, pure: true
    ) { args in
        guard let text = String.fromDatabaseValue(args[0]) else { return nil }
        return text.folding(
            options: [.diacriticInsensitive, .caseInsensitive, .widthInsensitive],
            locale: nil
        )
    }
}
