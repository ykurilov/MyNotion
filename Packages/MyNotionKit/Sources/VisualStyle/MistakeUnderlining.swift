#if canImport(AppKit)
import AppKit

/// Поле ввода, которое само следит за «Подчёркивать ошибки» (`MistakeUnderlining.didChange`): текст страницы.
@MainActor
public protocol FollowsMistakeUnderlining: NSTextView {}

/// «Подчёркивать ошибки» (Настройки): красные подчёркивания при вводе, автоисправление и проверка грамматики macOS
/// во всех полях ввода приложения. Выключение сразу снимает их во всех открытых окнах, включение возвращает как было.
/// Хранится в настройках приложения; по умолчанию включено.
@MainActor
public enum MistakeUnderlining {
    public static let defaultsKey = "MyNotion.underlinesMistakes"
    public static let didChange = Notification.Name("MyNotion.underlinesMistakesDidChange")

    public static var isEnabled: Bool {
        get { UserDefaults.standard.object(forKey: defaultsKey) as? Bool ?? true }
        set {
            guard newValue != isEnabled else { return }
            UserDefaults.standard.set(newValue, forKey: defaultsKey)
            NotificationCenter.default.post(name: didChange, object: nil)
            applyToOpenWindows()
        }
    }

    /// Автоисправление для поля, которое правит текст страницы: выключено вместе с подчёркиваниями,
    /// иначе — как в системных настройках.
    public static var correctsSpellingAutomatically: Bool {
        isEnabled && NSSpellChecker.isAutomaticSpellingCorrectionEnabled
    }

    /// Прежние проверки полей, у которых их сняли: при включении они возвращаются.
    private static let switchedOff = NSMapTable<NSTextView, Checks>.weakToStrongObjects()
    private static var observer: NSObjectProtocol?

    private final class Checks {
        let spelling: Bool, grammar: Bool, correction: Bool
        init(_ textView: NSTextView) {
            spelling = textView.isContinuousSpellCheckingEnabled
            grammar = textView.isGrammarCheckingEnabled
            correction = textView.isAutomaticSpellingCorrectionEnabled
        }
    }

    /// Слежение за всеми полями ввода (названия, ячейки, поиск, настройки): поле получает настройку,
    /// как только в нём ставят курсор. Один раз при запуске.
    public static func install() {
        guard observer == nil else { return }
        observer = NotificationCenter.default.addObserver(forName: NSTextView.didChangeSelectionNotification, object: nil, queue: nil) { note in
            guard let textView = note.object as? NSTextView else { return }
            MainActor.assumeIsolated { apply(to: textView) }
        }
        applyToOpenWindows()
    }

    /// Поле, кроме текста страницы: выключено — без подчёркиваний, грамматики и автоисправления; включено — как было.
    public static func apply(to textView: NSTextView) {
        guard !(textView is any FollowsMistakeUnderlining) else { return }
        if isEnabled {
            guard let checks = switchedOff.object(forKey: textView) else { return }
            switchedOff.removeObject(forKey: textView)
            textView.isContinuousSpellCheckingEnabled = checks.spelling
            textView.isGrammarCheckingEnabled = checks.grammar
            textView.isAutomaticSpellingCorrectionEnabled = checks.correction
        } else {
            guard textView.isContinuousSpellCheckingEnabled || textView.isGrammarCheckingEnabled
                || textView.isAutomaticSpellingCorrectionEnabled else { return }
            if switchedOff.object(forKey: textView) == nil { switchedOff.setObject(Checks(textView), forKey: textView) }
            textView.isContinuousSpellCheckingEnabled = false
            textView.isGrammarCheckingEnabled = false
            textView.isAutomaticSpellingCorrectionEnabled = false
        }
    }

    /// Поля во всех открытых окнах и их редакторы полей.
    private static func applyToOpenWindows() {
        for window in NSApp?.windows ?? [] {
            if let editor = window.fieldEditor(false, for: nil) as? NSTextView { apply(to: editor) }
            if let contentView = window.contentView { applyInside(contentView) }
        }
    }

    private static func applyInside(_ view: NSView) {
        if let textView = view as? NSTextView { apply(to: textView) }
        view.subviews.forEach(applyInside)
    }
}
#endif
