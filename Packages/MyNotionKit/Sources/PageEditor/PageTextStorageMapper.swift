import AppKit
import NotesCore
import VisualStyle

extension NSAttributedString.Key {
    /// id блока (`UUID`) на каждом символе абзаца, включая его перевод строки (research R2).
    public static let blockID = NSAttributedString.Key("MyNotion.blockID")
    static let blockKind = NSAttributedString.Key("MyNotion.blockKind")
    static let blockIndent = NSAttributedString.Key("MyNotion.blockIndent")
    static let blockChecked = NSAttributedString.Key("MyNotion.blockChecked")
    static let blockLinkedPage = NSAttributedString.Key("MyNotion.blockLinkedPage")
    /// На последнем переводе строки: блок пустого последнего абзаца, у которого своих символов нет.
    static let trailingEmptyBlock = NSAttributedString.Key("MyNotion.trailingEmptyBlock")

    static let inlineBold = NSAttributedString.Key("MyNotion.inlineBold")
    static let inlineItalic = NSAttributedString.Key("MyNotion.inlineItalic")
    static let inlineStrikethrough = NSAttributedString.Key("MyNotion.inlineStrikethrough")
    static let inlineCode = NSAttributedString.Key("MyNotion.inlineCode")
    static let inlineLink = NSAttributedString.Key("MyNotion.inlineLink")
}

/// Связь текста страницы с её блоками (research R2): один `NSTextStorage` на страницу, абзац = блок,
/// id блока лежит атрибутом на символах абзаца. Правки текста превращаются в правки блоков `PageDocument`:
/// меняются только абзацы рядом с правкой, остальные блоки не трогаются.
@MainActor
public final class PageTextStorageMapper: NSObject {
    public let document: PageDocument
    public let textStorage: NSTextStorage
    /// Отрезок текста с правками, ещё не переданными документу.
    private var pendingRange: NSRange?
    /// Мэппер сам меняет текст или атрибуты — это не правки пользователя.
    private var isApplying = false

    public init(document: PageDocument, textStorage: NSTextStorage) {
        self.document = document
        self.textStorage = textStorage
        super.init()
        NotificationCenter.default.addObserver(
            self, selector: #selector(storageDidChangeText(_:)),
            name: NSTextStorage.didProcessEditingNotification, object: textStorage
        )
    }

    /// Показать блоки документа заново целиком.
    public func load() {
        pendingRange = nil
        applying { textStorage.setAttributedString(Self.attributedText(for: document.blocks)) }
    }

    /// Есть ли правки текста, которые документ ещё не получил.
    public var hasPendingEdits: Bool { pendingRange != nil }

    /// Передать накопленные правки текста документу и поправить id абзацев.
    /// Вызывается после каждой законченной правки (`textDidChange`), но не посреди набора с помощью IME.
    public func commitPendingEdits() {
        guard let edited = pendingRange else { return }
        pendingRange = nil
        if !commit(around: edited) {
            // Текст и документ разошлись так, что по соседям не понять, какие блоки менять: сверить всё.
            _ = commit(around: NSRange(location: 0, length: textStorage.length), wholeText: true)
        }
    }

    @objc private func storageDidChangeText(_ notification: Notification) {
        guard !isApplying, textStorage.editedMask.contains(.editedCharacters) else { return }
        let edited = textStorage.editedRange
        let delta = textStorage.changeInLength
        guard var pending = pendingRange else {
            pendingRange = edited
            return
        }
        // Сдвинуть прежний отрезок на изменение длины и объединить с новым.
        let oldEditEnd = NSMaxRange(edited) - delta
        var start = pending.location, end = NSMaxRange(pending)
        if start >= oldEditEnd { start += delta } else if start > edited.location { start = edited.location }
        if end >= oldEditEnd { end += delta } else if end > edited.location { end = NSMaxRange(edited) }
        pending = NSRange(location: min(start, edited.location), length: 0)
        pending.length = max(end, NSMaxRange(edited)) - pending.location
        pendingRange = pending
    }

    // MARK: Правка → блоки

    private func commit(around edited: NSRange, wholeText: Bool = false) -> Bool {
        let string = textStorage.string as NSString
        let length = string.length
        let clamped = NSRange(location: min(edited.location, length), length: 0)
        let editEnd = min(NSMaxRange(edited), length)

        // Абзацы правки и по одному соседнему с каждой стороны: Enter и ⌫ на границе меняют и соседа.
        var lower = string.paragraphRange(for: clamped).location
        var upper = NSMaxRange(string.paragraphRange(for: NSRange(location: clamped.location, length: editEnd - clamped.location)))
        if !wholeText {
            if lower > 0 { lower = string.paragraphRange(for: NSRange(location: lower - 1, length: 0)).location }
            if upper < length { upper = NSMaxRange(string.paragraphRange(for: NSRange(location: upper, length: 0))) }
        } else {
            lower = 0
            upper = length
        }
        let paragraphs = Self.paragraphRanges(in: string, from: lower, to: upper)

        let previousId = lower > 0 ? textStorage.attribute(.blockID, at: lower - 1, effectiveRange: nil) as? UUID : nil
        let nextId = upper < length ? textStorage.attribute(.blockID, at: upper, effectiveRange: nil) as? UUID : nil
        if lower > 0, previousId.flatMap(document.index(ofBlock:)) == nil { return false }
        if upper < length, nextId.flatMap(document.index(ofBlock:)) == nil { return false }

        let start = previousId.flatMap(document.index(ofBlock:)).map { $0 + 1 } ?? 0
        let end = nextId.flatMap(document.index(ofBlock:)) ?? document.blocks.count
        guard start <= end else { return false }
        let replaced = Array(document.blocks[start..<end])

        let drafts = blockDrafts(for: paragraphs, replacing: replaced)
        let ids = document.replaceBlocks(after: previousId, before: nextId, with: drafts)
        renderParagraphs(paragraphs, as: ids)
        return true
    }

    /// Какой блок стал каждым абзацем. Абзац остаётся своим блоком, если на его символах есть id
    /// заменяемого блока, ещё не занятый абзацем выше. Абзац без такого id берёт по порядку блок,
    /// оставшийся без абзаца (набор в пустом последнем абзаце), иначе это новый блок —
    /// того же вида, что блок, от которого он отделился (Enter).
    private func blockDrafts(for paragraphs: [NSRange], replacing replaced: [Block]) -> [BlockDraft] {
        let replacedIds = Set(replaced.map(\.id))
        var used: Set<UUID> = []
        var assigned: [UUID?] = paragraphs.map { paragraph in
            let candidate = blockIds(in: paragraph).first { replacedIds.contains($0) && !used.contains($0) }
            if let candidate { used.insert(candidate) }
            return candidate
        }
        var spare = replaced.filter { !used.contains($0.id) }[...]
        for index in assigned.indices where assigned[index] == nil {
            assigned[index] = spare.popFirst()?.id
        }

        return zip(paragraphs, assigned).map { paragraph, id in
            let text = Self.inlineText(in: textStorage, range: Self.contentRange(of: paragraph, in: textStorage.string as NSString))
            if let id, let block = document.block(id) {
                return BlockDraft(id: id, kind: block.kind, text: text, indent: block.indent,
                                  isChecked: block.isChecked, linkedPageId: block.linkedPageId)
            }
            let source = blockIds(in: paragraph).lazy.compactMap(document.block).first
            return BlockDraft(id: nil, kind: Self.kindAfterSplit(of: source?.kind ?? .paragraph), text: text, indent: source?.indent ?? 0)
        }
    }

    private func blockIds(in paragraph: NSRange) -> [UUID] {
        var ids: [UUID] = []
        textStorage.enumerateAttribute(.blockID, in: paragraph) { value, _, _ in
            if let id = value as? UUID, !ids.contains(id) { ids.append(id) }
        }
        return ids
    }

    /// Новый блок после Enter: пункт и чекбокс продолжаются, заголовок и ссылка на страницу — нет.
    private static func kindAfterSplit(of kind: BlockKind) -> BlockKind {
        kind.isHeading || kind == .pageLink ? .paragraph : kind
    }

    /// Переписать атрибуты абзацев по их блокам: один id на абзац, вид по типу блока.
    private func renderParagraphs(_ paragraphs: [NSRange], as ids: [UUID]) {
        let string = textStorage.string as NSString
        applying {
            textStorage.beginEditing()
            for (paragraph, id) in zip(paragraphs, ids) {
                guard let block = document.block(id) else { continue }
                let hasNewline = NSMaxRange(paragraph) > Self.contentRange(of: paragraph, in: string).upperBound
                let rendered = Self.paragraph(block, withNewline: hasNewline)
                guard rendered.length == paragraph.length else { continue }
                rendered.enumerateAttributes(in: NSRange(location: 0, length: rendered.length)) { attributes, range, _ in
                    textStorage.setAttributes(attributes, range: NSRange(location: paragraph.location + range.location, length: range.length))
                }
            }
            markTrailingEmptyBlock()
            textStorage.endEditing()
        }
    }

    /// Последний перевод строки помнит блок пустого последнего абзаца, а все прочие символы — нет.
    private func markTrailingEmptyBlock() {
        let length = textStorage.length
        guard length > 0 else { return }
        textStorage.removeAttribute(.trailingEmptyBlock, range: NSRange(location: 0, length: length))
        if (textStorage.string as NSString).character(at: length - 1) == Self.newline, let last = document.blocks.last {
            textStorage.addAttribute(.trailingEmptyBlock, value: Self.paragraphAttributes(of: last) as NSDictionary,
                                     range: NSRange(location: length - 1, length: 1))
        }
    }

    private func applying(_ change: () -> Void) {
        isApplying = true
        change()
        isApplying = false
    }

    // MARK: Блоки ⇄ текст

    private static let newline = unichar(0x0A)

    /// Текст страницы: абзацы блоков через перевод строки.
    public static func attributedText(for blocks: [Block]) -> NSAttributedString {
        let text = NSMutableAttributedString()
        for (index, block) in blocks.enumerated() {
            text.append(paragraph(block, withNewline: index < blocks.count - 1))
        }
        if blocks.count > 1, let last = blocks.last, last.text.string.isEmpty {
            text.addAttribute(.trailingEmptyBlock, value: paragraphAttributes(of: last) as NSDictionary,
                              range: NSRange(location: text.length - 1, length: 1))
        }
        return text
    }

    /// Блоки, записанные в тексте: по черновику на абзац, включая пустой последний.
    public static func blockDrafts(in text: NSAttributedString) -> [BlockDraft] {
        let string = text.string as NSString
        return paragraphRanges(in: string, from: 0, to: string.length).map { paragraph in
            let attributes: [NSAttributedString.Key: Any]
            if paragraph.length > 0 {
                attributes = text.attributes(at: paragraph.location, effectiveRange: nil)
            } else if paragraph.location > 0 {
                let trailing = text.attribute(.trailingEmptyBlock, at: paragraph.location - 1, effectiveRange: nil) as? NSDictionary
                attributes = trailing as? [NSAttributedString.Key: Any] ?? [:]
            } else {
                attributes = [:]
            }
            return BlockDraft(
                id: attributes[.blockID] as? UUID,
                kind: (attributes[.blockKind] as? String).flatMap(BlockKind.init(rawValue:)) ?? .paragraph,
                text: inlineText(in: text, range: contentRange(of: paragraph, in: string)),
                indent: attributes[.blockIndent] as? Int ?? 0,
                isChecked: attributes[.blockChecked] as? Bool ?? false,
                linkedPageId: attributes[.blockLinkedPage] as? UUID
            )
        }
    }

    /// Абзацы между `lower` и `upper` (границы абзацев). Пустой последний абзац текста — тоже абзац.
    private static func paragraphRanges(in string: NSString, from lower: Int, to upper: Int) -> [NSRange] {
        var ranges: [NSRange] = []
        var location = lower
        while location < upper {
            let paragraph = string.paragraphRange(for: NSRange(location: location, length: 0))
            ranges.append(paragraph)
            location = NSMaxRange(paragraph)
        }
        let length = string.length
        if upper == length, length == 0 || string.character(at: length - 1) == newline {
            ranges.append(NSRange(location: length, length: 0))
        }
        return ranges
    }

    /// Абзац без завершающего перевода строки.
    private static func contentRange(of paragraph: NSRange, in string: NSString) -> Range<Int> {
        var end = NSMaxRange(paragraph)
        if end > paragraph.location, string.character(at: end - 1) == newline { end -= 1 }
        return paragraph.location..<end
    }

    private static func inlineText(in text: NSAttributedString, range: Range<Int>) -> InlineText {
        let nsRange = NSRange(location: range.lowerBound, length: range.count)
        let string = (text.string as NSString).substring(with: nsRange)
        var runs: [StyledRun] = []
        text.enumerateAttributes(in: nsRange) { attributes, run, _ in
            let start = run.location - range.lowerBound
            func add(_ style: InlineStyle) { runs.append(StyledRun(start: start, length: run.length, style: style)) }
            if attributes[.inlineBold] as? Bool == true { add(.bold) }
            if attributes[.inlineItalic] as? Bool == true { add(.italic) }
            if attributes[.inlineStrikethrough] as? Bool == true { add(.strikethrough) }
            if attributes[.inlineCode] as? Bool == true { add(.code) }
            if let url = attributes[.inlineLink] as? URL { add(.link(url)) }
        }
        return InlineText(string, runs: runs).normalized()
    }

    // MARK: Вид

    private static func paragraphAttributes(of block: Block) -> [NSAttributedString.Key: Any] {
        var attributes: [NSAttributedString.Key: Any] = [
            .blockID: block.id,
            .blockKind: block.kind.rawValue,
            .blockIndent: block.indent,
            .blockChecked: block.isChecked,
        ]
        attributes[.blockLinkedPage] = block.linkedPageId
        return attributes
    }

    /// Атрибуты, с которыми набирается текст абзаца блока (пустой абзац — без символов).
    public static func typingAttributes(for block: Block) -> [NSAttributedString.Key: Any] {
        baseAttributes(for: block)
    }

    private static func textStyle(of kind: BlockKind) -> BlockTextStyle {
        switch kind {
        case .heading1: .heading1
        case .heading2: .heading2
        case .heading3: .heading3
        case .bulletItem, .numberedItem, .checkbox: .listItem
        case .paragraph, .pageLink: .paragraph
        }
    }

    private static func baseAttributes(for block: Block) -> [NSAttributedString.Key: Any] {
        let style = textStyle(of: block.kind)
        let line = Typography.line(for: style)
        let spacing = Metrics.block(style)
        let paragraphStyle = (line.paragraphStyle.mutableCopy() as? NSMutableParagraphStyle) ?? NSMutableParagraphStyle()
        paragraphStyle.paragraphSpacingBefore = spacing.topSpacing
        paragraphStyle.paragraphSpacing = max(0, spacing.height - line.lineHeight - spacing.topSpacing)
        let indent = CGFloat(block.indent) * Metrics.Page.indentPerLevel
        paragraphStyle.firstLineHeadIndent = indent
        paragraphStyle.headIndent = indent

        var attributes = paragraphAttributes(of: block)
        attributes[.font] = line.font
        attributes[.foregroundColor] = Palette.textPrimary
        attributes[.paragraphStyle] = paragraphStyle
        if block.kind == .checkbox, block.isChecked {
            attributes[.foregroundColor] = Palette.textSecondary
            attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
        }
        return attributes
    }

    /// Абзац блока: текст с оформлением и, если нужно, перевод строки с атрибутами того же абзаца.
    static func paragraph(_ block: Block, withNewline: Bool) -> NSAttributedString {
        let base = baseAttributes(for: block)
        let line = Typography.line(for: textStyle(of: block.kind))
        let text = NSMutableAttributedString(string: block.text.string, attributes: base)
        let length = text.length
        for run in block.text.normalized().runs {
            let range = NSRange(location: run.start, length: run.length)
            guard run.start >= 0, NSMaxRange(range) <= length else { continue }
            switch run.style {
            case .bold: text.addAttribute(.inlineBold, value: true, range: range)
            case .italic: text.addAttribute(.inlineItalic, value: true, range: range)
            case .strikethrough: text.addAttribute(.inlineStrikethrough, value: true, range: range)
            case .code: text.addAttribute(.inlineCode, value: true, range: range)
            case .link(let url): text.addAttribute(.inlineLink, value: url, range: range)
            }
        }
        if length > 0 {
            text.enumerateAttributes(in: NSRange(location: 0, length: length)) { attributes, range, _ in
                text.addAttributes(inlineRendering(attributes, line: line), range: range)
            }
        }
        if withNewline { text.append(NSAttributedString(string: "\n", attributes: base)) }
        return text
    }

    /// Как выглядит оформление в строке (contracts/visual-style.md, «Оформление в строке»).
    private static func inlineRendering(_ attributes: [NSAttributedString.Key: Any], line: TextLineStyle) -> [NSAttributedString.Key: Any] {
        var rendering: [NSAttributedString.Key: Any] = [:]
        let isBold = attributes[.inlineBold] as? Bool == true
        let isItalic = attributes[.inlineItalic] as? Bool == true
        if attributes[.inlineCode] as? Bool == true {
            rendering[.font] = Typography.inlineCodeFont(forTextSize: line.fontSize)
            rendering[.foregroundColor] = Palette.inlineCodeText
            rendering[.backgroundColor] = Palette.inlineCodeBackground
        } else if isBold || isItalic {
            var font = NSFont.systemFont(ofSize: line.fontSize, weight: isBold ? Typography.inlineBoldWeight : line.weight)
            if isItalic {
                font = NSFont(descriptor: font.fontDescriptor.withSymbolicTraits(.italic), size: line.fontSize) ?? font
            }
            rendering[.font] = font
        }
        if attributes[.inlineStrikethrough] as? Bool == true {
            rendering[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
        }
        if attributes[.inlineLink] is URL {
            rendering[.underlineStyle] = NSUnderlineStyle.single.rawValue
            rendering[.underlineColor] = Palette.linkUnderline
        }
        return rendering
    }
}
