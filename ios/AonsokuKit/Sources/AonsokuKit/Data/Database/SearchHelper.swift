import Foundation
import GRDB

enum SearchHelper {
    static func tokenize(_ query: String) -> [String] {
        query.folding(
            options: [.diacriticInsensitive, .caseInsensitive, .widthInsensitive],
            locale: nil
        )
        .split(whereSeparator: \.isWhitespace)
        .map(String.init)
        .filter { !$0.isEmpty }
    }

    static func buildCondition(
        query: String, columns: [String]
    ) -> SQLExpression? {
        let tokens = tokenize(query)
        guard !tokens.isEmpty else { return nil }

        let normalize = DatabaseManager.normalizeFunction
        var allTokenConditions: SQLExpression?

        for token in tokens {
            let pattern = "%\(token)%"
            var columnConditions: SQLExpression?

            for colName in columns {
                let col = Column(colName)
                let condition = normalize(col).like(pattern)
                if let existing = columnConditions {
                    columnConditions = existing || condition
                } else {
                    columnConditions = condition
                }
            }

            if let tokenCondition = columnConditions {
                if let existing = allTokenConditions {
                    allTokenConditions = existing && tokenCondition
                } else {
                    allTokenConditions = tokenCondition
                }
            }
        }

        return allTokenConditions
    }
}
