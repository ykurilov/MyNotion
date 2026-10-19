import AppKit
import NotesCore
import VisualStyle

/// Что красим: сами буквы или подложку под ними.
public enum ColorTarget: String, Sendable, Hashable, Codable {
    case text
    case background
}

/// Выбор в окне цветов: что красим и в какой цвет (`nil` — «По умолчанию», то есть снять цвет).
public struct ColorChoice: Sendable, Hashable, Codable {
    public var target: ColorTarget
    public var color: NotionColor?

    public init(target: ColorTarget, color: NotionColor?) {
        self.target = target
        self.color = color
    }
}

extension NotionColor {
    /// Тот же цвет в палитре (`VisualStyle` не знает про модель страницы).
    var tone: NotionTone? { NotionTone(rawValue: rawValue) }
}

extension BlockColor {
    /// Цвет блока вида `target`.
    func color(for target: ColorTarget) -> NotionColor? {
        target == .text ? text : background
    }

    /// Блок с цветом вида `target`, замененным на `color`.
    func setting(_ target: ColorTarget, to color: NotionColor?) -> BlockColor {
        var result = self
        if target == .text { result.text = color } else { result.background = color }
        return result
    }
}

/// Цвет текста и фона в строке (FR-112; contracts/blocks-and-keys.md, «Цвета»).
enum InlineColors {
    static func style(_ target: ColorTarget, _ color: NotionColor) -> InlineStyle {
        target == .text ? .textColor(color) : .backgroundColor(color)
    }

    /// Это оформление — цвет вида `target`.
    static func isColor(_ style: InlineStyle, of target: ColorTarget) -> Bool {
        switch (style, target) {
        case (.textColor, .text), (.backgroundColor, .background): true
        default: false
        }
    }

    /// Весь ли отрезок `range` уже окрашен этим цветом.
    static func covers(_ text: InlineText, _ choice: ColorChoice, in range: Range<Int>) -> Bool {
        guard let color = choice.color, !range.isEmpty else { return false }
        let wanted = style(choice.target, color)
        var covered = IndexSet()
        for run in text.runs where run.style == wanted {
            covered.insert(integersIn: run.start..<run.start + run.length)
        }
        return covered.contains(integersIn: range)
    }

    /// Текст, где на отрезке `range` прежний цвет вида `choice.target` заменён выбранным (`enabled`) или снят.
    /// Цвет другого вида и остальное оформление остаются.
    static func text(_ text: InlineText, applying choice: ColorChoice, enabled: Bool, in range: Range<Int>) -> InlineText {
        var runs = text.runs.flatMap { run in
            isColor(run.style, of: choice.target) ? InlineFormatting.subtract(range, from: run) : [run]
        }
        if enabled, let color = choice.color {
            runs.append(StyledRun(start: range.lowerBound, length: range.count, style: style(choice.target, color)))
        }
        return InlineText(text.string, runs: runs).normalized()
    }
}

/// Последние применённые цвета: свежий первым, без повторов, не больше `limit`. Хранятся в настройках приложения.
@MainActor
public final class RecentColors {
    public static let limit = 5
    private static let storageKey = "MyNotion.recentColors"

    private let defaults: UserDefaults?
    public private(set) var choices: [ColorChoice]

    /// `defaults == nil` — только в памяти (проверки).
    public init(defaults: UserDefaults? = .standard) {
        self.defaults = defaults
        choices = defaults?.data(forKey: Self.storageKey)
            .flatMap { try? JSONDecoder().decode([ColorChoice].self, from: $0) } ?? []
    }

    public var last: ColorChoice? { choices.first }

    /// Запомнить применённый цвет; «По умолчанию» не запоминается.
    public func record(_ choice: ColorChoice) {
        guard choice.color != nil else { return }
        choices.removeAll { $0 == choice }
        choices.insert(choice, at: 0)
        if choices.count > Self.limit { choices.removeLast(choices.count - Self.limit) }
        defaults?.set(try? JSONEncoder().encode(choices), forKey: Self.storageKey)
    }
}

extension PageTextView {
    // MARK: Цвет в строке

    /// Цвет на выделении; тот же цвет у всего выделения снимает его. Без выделения — для набираемого текста.
    /// `force` (⌘⇧H) только накладывает цвет и никогда не снимает.
    func applyColor(_ choice: ColorChoice, force: Bool = false) {
        commitEdits()
        let selection = selectedRange()
        guard selection.length > 0 else {
            applyTypingColor(choice, force: force)
            return
        }
        guard let blocks = selectedBlockRange() else { return }
        let pieces = blocks.map { index in (index, localRange(of: selection, inBlockAt: index)) }
        let enabled = force || !pieces.allSatisfy { index, range in
            range.isEmpty || InlineColors.covers(document.blocks[index].text, choice, in: range)
        }
        let drafts = pieces.map { index, range in
            var draft = BlockDraft(document.blocks[index])
            if !range.isEmpty { draft.text = InlineColors.text(draft.text, applying: choice, enabled: enabled, in: range) }
            return draft
        }
        changeBlocks(blocks, to: drafts, actionName: "Цвет")
        if enabled { recentColors.record(choice) }
    }

    private func applyTypingColor(_ choice: ColorChoice, force: Bool) {
        guard let position = mapper.blockPosition(at: selectedRange().location) else { return }
        let key: NSAttributedString.Key = choice.target == .text ? .inlineTextColor : .inlineBackgroundColor
        var inline = typingAttributes
        if let color = choice.color, force || inline[key] as? String != color.rawValue {
            inline[key] = color.rawValue
            recentColors.record(choice)
        } else {
            inline[key] = nil
        }
        typingAttributes = PageTextStorageMapper.typingAttributes(for: document.blocks[position.index],
                                                                 after: mapper.previousKind(ofBlockAt: position.index), inline: inline)
    }

    /// Меню «Формат → Повторить последний цвет».
    @objc public func repeatLastColorStyle(_ sender: Any?) { perform(.repeatLastColor) }

    /// ⌘⇧H: последний применённый цвет — на новое выделение.
    func repeatLastColor() {
        guard let choice = recentColors.last else { return }
        applyColor(choice, force: true)
    }

    // MARK: Цвет блока

    /// Цвет блоков под курсором или выделением; тот же цвет у всех снимает его.
    func applyBlockColor(_ choice: ColorChoice) {
        commitEdits()
        guard let blocks = selectedBlockRange() else { return }
        let enabled = choice.color != nil && !blocks.allSatisfy { document.blocks[$0].color.color(for: choice.target) == choice.color }
        let drafts = blocks.map { index in
            var draft = BlockDraft(document.blocks[index])
            draft.color = document.blocks[index].color.setting(choice.target, to: enabled ? choice.color : nil)
            return draft
        }
        changeBlocks(blocks, to: drafts, actionName: "Цвет блока")
        if enabled { recentColors.record(choice) }
    }
}
