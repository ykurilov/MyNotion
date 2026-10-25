import AppKit
import Testing
@testable import PageEditor
import VisualStyle

/// «Подчёркивать ошибки» в Настройках: выключение снимает подчёркивания и автоисправление сразу, без перезапуска,
/// во всех полях ввода; включение возвращает как было. Тесты без ожиданий: общая настройка не видна соседним тестам.
@MainActor
@Suite("«Подчёркивать ошибки»")
struct MistakeUnderliningTests {
    @Test("Текст открытой страницы: выключили — без подчёркиваний и автоисправления, включили — как было")
    func pageFollowsSetting() throws {
        let fixture = try EditorFixture([.paragraph("превет")])
        defer { MistakeUnderlining.isEnabled = true }
        #expect(fixture.textView.spellCheckingWanted)

        MistakeUnderlining.isEnabled = false
        #expect(!fixture.textView.spellCheckingWanted)
        #expect(!fixture.textView.isContinuousSpellCheckingEnabled)
        #expect(!fixture.textView.isAutomaticSpellingCorrectionEnabled)
        #expect(!fixture.textView.isGrammarCheckingEnabled)
        // Страница, открытая после выключения, тоже без подчёркиваний.
        let later = try EditorFixture([.paragraph("дила")])
        #expect(!later.textView.spellCheckingWanted)
        #expect(!later.textView.isContinuousSpellCheckingEnabled)

        MistakeUnderlining.isEnabled = true
        #expect(fixture.textView.spellCheckingWanted)
        #expect(later.textView.spellCheckingWanted)
        #expect(fixture.textView.isAutomaticSpellingCorrectionEnabled == NSSpellChecker.isAutomaticSpellingCorrectionEnabled)
    }

    @Test("Другие поля (название, ячейка): выключили — проверки сняты, включили — вернулись прежние; код не трогается")
    func otherFieldsFollowSetting() {
        defer { MistakeUnderlining.isEnabled = true }
        let field = NSTextView()
        field.isContinuousSpellCheckingEnabled = true
        field.isGrammarCheckingEnabled = true
        field.isAutomaticSpellingCorrectionEnabled = true
        let code = NSTextView()
        code.isContinuousSpellCheckingEnabled = false
        code.isGrammarCheckingEnabled = false
        code.isAutomaticSpellingCorrectionEnabled = false

        MistakeUnderlining.isEnabled = false
        MistakeUnderlining.apply(to: field)
        MistakeUnderlining.apply(to: code)
        #expect(!field.isContinuousSpellCheckingEnabled && !field.isGrammarCheckingEnabled && !field.isAutomaticSpellingCorrectionEnabled)

        MistakeUnderlining.isEnabled = true
        MistakeUnderlining.apply(to: field)
        MistakeUnderlining.apply(to: code)
        #expect(field.isContinuousSpellCheckingEnabled && field.isGrammarCheckingEnabled && field.isAutomaticSpellingCorrectionEnabled)
        #expect(!code.isContinuousSpellCheckingEnabled && !code.isGrammarCheckingEnabled && !code.isAutomaticSpellingCorrectionEnabled)
    }

    @Test("Поле в открытом окне снимается сразу при выключении, без курсора в нём")
    func openWindowFieldsSwitchImmediately() {
        defer { MistakeUnderlining.isEnabled = true }
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 100), styleMask: [.titled], backing: .buffered, defer: true)
        let field = NSTextView(frame: NSRect(x: 0, y: 0, width: 200, height: 100))
        field.isContinuousSpellCheckingEnabled = true
        window.contentView?.addSubview(field)
        MistakeUnderlining.isEnabled = false
        #expect(!field.isContinuousSpellCheckingEnabled)
        MistakeUnderlining.isEnabled = true
        #expect(field.isContinuousSpellCheckingEnabled)
    }

    @Test("Настройка сохраняется между запусками")
    func persists() {
        defer { MistakeUnderlining.isEnabled = true }
        MistakeUnderlining.isEnabled = false
        #expect(UserDefaults.standard.object(forKey: MistakeUnderlining.defaultsKey) as? Bool == false)
        MistakeUnderlining.isEnabled = true
        #expect(UserDefaults.standard.bool(forKey: MistakeUnderlining.defaultsKey))
    }
}
