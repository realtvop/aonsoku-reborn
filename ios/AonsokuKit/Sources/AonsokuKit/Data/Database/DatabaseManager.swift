import Foundation
import GRDB

final class DatabaseManager {
    static let shared = DatabaseManager()

    let dbPool: DatabasePool

    private convenience init() {
        try! self.init(layout: .current)
    }

    /// Opens (creating it if needed) the library database of `layout`.
    init(layout: StorageLayout) throws {
        try FileManager.default.createDirectory(
            at: layout.databaseDirectory, withIntermediateDirectories: true
        )
        dbPool = try Self.makePool(path: layout.databaseFileURL.path)
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
