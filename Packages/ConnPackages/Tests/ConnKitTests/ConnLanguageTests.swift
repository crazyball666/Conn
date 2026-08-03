import Testing
@testable import ConnKit

@Suite("ConnLanguage — 系统语言回退")
struct ConnLanguageTests {
    @Test("不支持的系统语言回退到 English")
    func unsupportedLanguageFallsBackToEnglish() {
        #expect(ConnLanguage.systemPreferred(["fr-FR", "de-DE"]) == "en")
        #expect(ConnLanguage.systemPreferred(["es-ES"]) == "en")
    }

    @Test("系统语言按支持集归一化")
    func supportedLanguagesAreNormalized() {
        #expect(ConnLanguage.systemPreferred(["zh-Hans-CN"]) == "zh-Hans")
        #expect(ConnLanguage.systemPreferred(["zh-Hant-TW"]) == "zh-Hant")
        #expect(ConnLanguage.systemPreferred(["en-US"]) == "en")
        #expect(ConnLanguage.systemPreferred(["ja-JP"]) == "ja")
        #expect(ConnLanguage.systemPreferred(["ko-KR"]) == "ko")
    }

    @Test("首选语言列表中包含不支持语言时继续检查后续语言")
    func unsupportedLanguageDoesNotMaskSupportedLanguage() {
        #expect(ConnLanguage.systemPreferred(["fr-FR", "en-GB"]) == "en")
        #expect(ConnLanguage.systemPreferred(["de-DE", "zh-Hant-HK"]) == "zh-Hant")
    }
}
