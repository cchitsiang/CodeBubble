import XCTest
@testable import CodeBubble

final class L10nTests: XCTestCase {
    override func setUp() {
        L10n.shared.language = "en"
    }

    override func tearDown() {
        L10n.shared.language = "system"
    }

    func testChineseTranslationsContainAllKeysPresentInEnglish() {
        let enKeys = Set(L10n.strings["en"]?.keys ?? Dictionary<String, String>().keys)
        let zhKeys = Set(L10n.strings["zh"]?.keys ?? Dictionary<String, String>().keys)

        let missingKeys = enKeys.subtracting(zhKeys)
        XCTAssertTrue(missingKeys.isEmpty, "Chinese is missing keys: \(missingKeys)")
    }

    func testChineseTranslationReturnsCorrectValue() {
        L10n.shared.language = "zh"

        XCTAssertEqual(L10n.shared["general"], "通用")
        XCTAssertEqual(L10n.shared["behavior"], "行为")
        XCTAssertEqual(L10n.shared["appearance"], "外观")
    }

    func testFallbackToEnglishWhenKeyIsMissing() {
        L10n.shared.language = "zh"

        let result = L10n.shared["nonexistent_key"]
        XCTAssertEqual(result, "nonexistent_key")
    }

    func testAllLanguageOptionsAvailableInSettings() {
        let availableLanguages = ["system", "en", "zh"]

        for lang in availableLanguages {
            L10n.shared.language = lang
            let value = L10n.shared["general"]
            XCTAssertFalse(value.isEmpty, "Language '\(lang)' should return a value for 'general' key")
        }
    }
}
