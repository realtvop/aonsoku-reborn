import XCTest
@testable import AonsokuKit

@MainActor
final class LocalizerTests: XCTestCase {
    func testLookupOrderFallbackInterpolationAndMissingKeys() throws {
        let fixture = try LocalizerBundleFixture()
        let localizer = Localizer(bundle: fixture.bundle, preferredLanguages: ["fr-FR"])

        XCTAssertEqual(localizer.language.code, "fr")
        XCTAssertEqual(localizer.t("greeting"), "Français natif")
        XCTAssertEqual(localizer.t("webOnly"), "Web français")
        XCTAssertEqual(localizer.t("nativeOnly"), "Native English")
        XCTAssertEqual(localizer.t("englishOnly"), "English fallback")
        XCTAssertEqual(
            localizer.t("welcome", ["name": "Aonsoku"]),
            "Hello Aonsoku {{ unknown }}"
        )
        XCTAssertEqual(localizer.t("object"), "object")
        XCTAssertEqual(localizer.t("missing.key"), "missing.key")
        XCTAssertTrue(localizer.has("nativeOnly"))
        XCTAssertFalse(localizer.has("missing.key"))
    }

    func testSystemLanguageMatchingAndExplicitSelection() throws {
        let fixture = try LocalizerBundleFixture()
        let cases: [([String], String)] = [
            (["zh-Hans-CN"], "zh-Hans"),
            (["pt-PT"], "pt"),
            (["pt-BR"], "pt-BR"),
            (["es-MX"], "es-ES"),
            (["fr-CA"], "fr-CA"),
            (["en-GB"], "en-US"),
            (["xx"], "en-US"),
        ]
        for (preferred, expected) in cases {
            let localizer = Localizer(bundle: fixture.bundle, preferredLanguages: preferred)
            XCTAssertEqual(localizer.language.code, expected)
            XCTAssertNil(localizer.selectedCode)
        }

        let explicit = Localizer(bundle: fixture.bundle, preferredLanguages: ["fr"])
        explicit.setLanguage(code: "ja")
        XCTAssertEqual(explicit.language.code, "ja")
        XCTAssertEqual(explicit.selectedCode, "ja")
        explicit.setLanguage(code: "unknown")
        XCTAssertEqual(explicit.language.code, "fr")
        XCTAssertNil(explicit.selectedCode)
    }

    func testEveryPluralRuleFamilyAndZeroOverride() throws {
        let fixture = try LocalizerBundleFixture()
        let localizer = Localizer(bundle: fixture.bundle, preferredLanguages: ["en-US"])

        assertPlural(localizer, language: "en-US", values: [0: "zero", 1: "one", 2: "other"])
        assertPlural(localizer, language: "de", values: [1: "one", 2: "other"])
        assertPlural(localizer, language: "fr", values: [0: "zero", 1: "one", 2: "other"])
        assertPlural(localizer, language: "pt-BR", values: [1: "one", 2: "other"])
        assertPlural(localizer, language: "cs", values: [1: "one", 3: "few", 5: "other"])
        assertPlural(
            localizer,
            language: "pl",
            values: [1: "one", 2: "few", 5: "many", 12: "many", 22: "few"]
        )
        assertPlural(
            localizer,
            language: "ru",
            values: [1: "one", 2: "few", 5: "many", 11: "many", 21: "one"]
        )
        assertPlural(localizer, language: "uk", values: [3: "few", 8: "many"])
        assertPlural(localizer, language: "ja", values: [1: "other", 2: "other"])
        assertPlural(localizer, language: "ko", values: [1: "other"])
        assertPlural(localizer, language: "zh-Hans", values: [1: "other"])
    }

    private func assertPlural(
        _ localizer: Localizer,
        language: String,
        values: [Int: String],
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        localizer.setLanguage(code: language)
        for (count, category) in values {
            XCTAssertEqual(
                localizer.t("items", count: count),
                "\(category) \(count)",
                file: file,
                line: line
            )
        }
    }
}

private final class LocalizerBundleFixture {
    let directory: URL
    let bundle: Bundle

    init() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("aonsoku-localizer-\(UUID().uuidString).bundle")
        try FileManager.default.createDirectory(
            at: directory.appendingPathComponent("locales"),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: directory.appendingPathComponent("native-locales"),
            withIntermediateDirectories: true
        )
        let plist: [String: Any] = [
            "CFBundleIdentifier": "com.aonsoku.tests.localizer.\(UUID().uuidString)",
            "CFBundleName": "LocalizerTests",
            "CFBundlePackageType": "BNDL",
            "CFBundleVersion": "1",
        ]
        let plistData = try PropertyListSerialization.data(
            fromPropertyList: plist,
            format: .xml,
            options: 0
        )
        try plistData.write(to: directory.appendingPathComponent("Info.plist"))
        try Self.writeJSON([
            "greeting": "English",
            "englishOnly": "English fallback",
            "welcome": "Hello {{ name }} {{ unknown }}",
            "object": ["child": "not a string"],
            "items_zero": "zero {{count}}",
            "items_one": "one {{count}}",
            "items_few": "few {{count}}",
            "items_many": "many {{count}}",
            "items_other": "other {{count}}",
        ], root: directory, subdirectory: "locales", name: "en")
        try Self.writeJSON(
            ["greeting": "Web français", "webOnly": "Web français"],
            root: directory,
            subdirectory: "locales",
            name: "fr"
        )
        try Self.writeJSON(
            ["greeting": "Français natif"],
            root: directory,
            subdirectory: "native-locales",
            name: "fr"
        )
        try Self.writeJSON(
            ["nativeOnly": "Native English"],
            root: directory,
            subdirectory: "native-locales",
            name: "en"
        )
        bundle = try XCTUnwrap(Bundle(url: directory))
    }

    deinit {
        try? FileManager.default.removeItem(at: directory)
    }

    private static func writeJSON(
        _ object: [String: Any],
        root: URL,
        subdirectory: String,
        name: String
    ) throws {
        let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        try data.write(
            to: root
                .appendingPathComponent(subdirectory)
                .appendingPathComponent("\(name).json")
        )
    }
}
