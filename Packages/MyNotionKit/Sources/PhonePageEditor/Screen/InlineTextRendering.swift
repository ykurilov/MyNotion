#if canImport(UIKit)
import NotesCore
import UIKit
import VisualStyle

extension NSAttributedString.Key {
    /// Оформление знака из `InlineText` как есть (`InlineStylesBox`): по нему текст из поля читается обратно без потерь,
    /// а набранные знаки получают его из `typingAttributes`.
    static let inlineStyles = NSAttributedString.Key("MyNotion.inlineStyles")
}

/// Набор стилей знака в атрибуте текста.
final class InlineStylesBox: NSObject {
    let styles: [InlineStyle]

    init(_ styles: [InlineStyle]) {
        self.styles = styles
    }

    override func isEqual(_ object: Any?) -> Bool {
        (object as? InlineStylesBox)?.styles == styles
    }

    override var hash: Int { styles.hashValue }
}

/// Вид текста блока: шрифт и высота строки по типу (размеры — `Typography` Mac, кроме названия страницы).
struct TextLook: Hashable {
    var fontSize: CGFloat
    var lineHeight: CGFloat
    var weight: UIFont.Weight
    var color: NotionTone?
    var isStruckThrough = false

    static let paragraph = TextLook(fontSize: 16, lineHeight: 24, weight: .regular)
    static let heading1 = TextLook(fontSize: 30, lineHeight: 39, weight: .semibold)
    static let heading2 = TextLook(fontSize: 24, lineHeight: 31.2, weight: .semibold)
    static let heading3 = TextLook(fontSize: 20, lineHeight: 26, weight: .semibold)
    /// Название страницы: у Notion для iPhone мельче, чем на Mac (40).
    static let pageTitle = TextLook(fontSize: 32, lineHeight: 40, weight: .bold)

    static func of(_ kind: TextBlockKind) -> TextLook {
        switch kind {
        case .heading1: .heading1
        case .heading2: .heading2
        case .heading3: .heading3
        default: .paragraph
        }
    }

    var font: UIFont { .systemFont(ofSize: fontSize, weight: weight) }
}

/// `InlineText` ↔ текст с атрибутами UIKit. Оформление показывается как на Mac: жирный, курсив, зачёркнутый,
/// подчёркнутый, код, ссылки, цвета текста и фона; упоминание, дата и формула — знак-картинка на своём U+FFFC.
@MainActor
struct InlineTextRendering {
    var look: TextLook
    var traits: UITraitCollection
    /// Название страницы для упоминания.
    var pageTitle: (UUID) -> String?

    func attributedString(_ text: InlineText) -> NSAttributedString {
        let string = text.string as NSString
        let result = NSMutableAttributedString(string: text.string, attributes: attributes(for: []))
        guard string.length > 0, !text.runs.isEmpty else { return result }
        var styles = [[InlineStyle]](repeating: [], count: string.length)
        for run in text.runs {
            let end = min(run.start + run.length, string.length)
            guard run.start < end else { continue }
            for index in max(run.start, 0)..<end { styles[index].append(run.style) }
        }
        var start = 0
        while start < styles.count {
            var end = start + 1
            while end < styles.count, styles[end] == styles[start], !styles[start].contains(where: \.isAtom) { end += 1 }
            if !styles[start].isEmpty {
                result.setAttributes(attributes(for: styles[start]), range: NSRange(location: start, length: end - start))
            }
            start = end
        }
        return result
    }

    /// Текст поля обратно в `InlineText`: по атрибуту `inlineStyles`, остальные атрибуты не в счёт.
    static func inlineText(from attributed: NSAttributedString) -> InlineText {
        var runs: [StyledRun] = []
        attributed.enumerateAttribute(.inlineStyles, in: NSRange(location: 0, length: attributed.length)) { value, range, _ in
            guard let box = value as? InlineStylesBox else { return }
            runs += box.styles.map { StyledRun(start: range.location, length: range.length, style: $0) }
        }
        return InlineText(attributed.string, runs: runs).normalized()
    }

    /// Атрибуты знаков с этими стилями; пустой список — простой текст блока.
    func attributes(for styles: [InlineStyle]) -> [NSAttributedString.Key: Any] {
        let paragraph = NSMutableParagraphStyle()
        paragraph.minimumLineHeight = look.lineHeight
        paragraph.maximumLineHeight = look.lineHeight
        var attributes: [NSAttributedString.Key: Any] = [
            .font: look.font,
            .foregroundColor: PhonePalette.notionText(look.color),
            .paragraphStyle: paragraph,
        ]
        if look.isStruckThrough {
            attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
            attributes[.foregroundColor] = PhonePalette.textSecondary
        }
        // Текст на строке стоит по середине высоты строки, как у `NSParagraphStyle` с одинаковыми границами.
        attributes[.baselineOffset] = (look.lineHeight - look.font.lineHeight) / 4
        guard !styles.isEmpty else { return attributes }
        attributes[.inlineStyles] = InlineStylesBox(styles)

        var traits: UIFontDescriptor.SymbolicTraits = []
        var weight = look.weight
        var isCode = false
        for style in styles {
            switch style {
            case .bold: weight = max(weight, .semibold)
            case .italic: traits.insert(.traitItalic)
            case .strikethrough: attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
            case .underline: attributes[.underlineStyle] = NSUnderlineStyle.single.rawValue
            case .code: isCode = true
            case .link:
                attributes[.underlineStyle] = NSUnderlineStyle.single.rawValue
                attributes[.underlineColor] = PhonePalette.linkUnderline
            case .textColor(let color): attributes[.foregroundColor] = PhonePalette.notionText(NotionTone(rawValue: color.rawValue))
            case .backgroundColor(let color): attributes[.backgroundColor] = PhonePalette.notionBackground(NotionTone(rawValue: color.rawValue))
            case .mention, .date, .equation: attributes[.attachment] = atomAttachment(style)
            }
        }
        var font = isCode ? UIFont.monospacedSystemFont(ofSize: look.fontSize * 0.85, weight: weight) : UIFont.systemFont(ofSize: look.fontSize, weight: weight)
        if !traits.isEmpty, let descriptor = font.fontDescriptor.withSymbolicTraits(font.fontDescriptor.symbolicTraits.union(traits)) {
            font = UIFont(descriptor: descriptor, size: font.pointSize)
        }
        attributes[.font] = font
        if isCode {
            if !styles.contains(where: { if case .textColor = $0 { true } else { false } }) {
                attributes[.foregroundColor] = PhonePalette.inlineCodeText
            }
            if attributes[.backgroundColor] == nil { attributes[.backgroundColor] = PhonePalette.inlineCodeBackground }
        }
        return attributes
    }

    /// Атрибуты для набора в месте `offset`: оформление продолжается, ссылка и атомы — нет.
    func typingAttributes(in text: InlineText, at offset: Int) -> [NSAttributedString.Key: Any] {
        attributes(for: text.typingStyles(at: offset))
    }

    // MARK: Атомы

    /// Подпись атома: упоминание — «↗ Название», дата — «@Завтра 9:00», формула — запись LaTeX.
    func atomLabel(_ style: InlineStyle) -> String {
        switch style {
        case .mention(let pageId): "↗ " + (pageTitle(pageId) ?? InlineText.deletedPageTitle)
        case .date(let date): date.shownText(now: Date(), calendar: .current)
        case .equation(let latex): latex
        default: ""
        }
    }

    private func atomAttachment(_ style: InlineStyle) -> NSTextAttachment {
        let label = atomLabel(style)
        let isEquation = if case .equation = style { true } else { false }
        let isMention = if case .mention = style { true } else { false }
        let font = isEquation ? UIFont.monospacedSystemFont(ofSize: look.fontSize * 0.85, weight: .regular) : look.font
        let color = (isMention ? PhonePalette.textPrimary : PhonePalette.textSecondary).resolvedColor(with: traits)
        var textAttributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
        if isMention {
            textAttributes[.underlineStyle] = NSUnderlineStyle.single.rawValue
            textAttributes[.underlineColor] = PhonePalette.linkUnderline.resolvedColor(with: traits)
        }
        let string = NSAttributedString(string: label, attributes: textAttributes)
        let size = string.size()
        let padding: CGFloat = 2
        let imageSize = CGSize(width: ceil(size.width) + 2 * padding, height: ceil(font.lineHeight))
        let format = UIGraphicsImageRendererFormat(for: traits)
        let image = UIGraphicsImageRenderer(size: imageSize, format: format).image { _ in
            if isEquation {
                PhonePalette.inlineCodeBackground.resolvedColor(with: traits).setFill()
                UIBezierPath(roundedRect: CGRect(origin: .zero, size: imageSize), cornerRadius: 3).fill()
            }
            string.draw(at: CGPoint(x: padding, y: 0))
        }
        let attachment = NSTextAttachment(image: image)
        attachment.bounds = CGRect(x: 0, y: font.descender, width: imageSize.width, height: imageSize.height)
        return attachment
    }
}
#endif
