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

    static let inlineBold = NSAttributedString.Key("MyNotion.inlineBold")
    static let inlineItalic = NSAttributedString.Key("MyNotion.inlineItalic")
    static let inlineStrikethrough = NSAttributedString.Key("MyNotion.inlineStrikethrough")
    static let inlineCode = NSAttributedString.Key("MyNotion.inlineCode")
    static let inlineUnderline = NSAttributedString.Key("MyNotion.inlineUnderline")
    static let inlineLink = NSAttributedString.Key("MyNotion.inlineLink")
}

/// Связь текста страницы с её блоками (research R2): один `NSTextStorage` на страницу, абзац = блок,
/// id блока лежит атрибутом на символах абзаца. Правки текста превращаются в правки блоков `PageDocument`:
/// меняются только абзацы рядом с правкой, остальные блоки не трогаются.
///
/// Перевод строки есть у каждого абзаца, и у последнего тоже: так у пустого блока есть свой символ с видом блока.
/// Без него пустой последний блок стал бы добавочной строкой TextKit, а её TextKit ставит без отступов абзаца
/// и с атрибутами по умолчанию — курсор уезжает с места блока. Строку после последнего перевода курсор не занимает.
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
        restoreFinalNewline()
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
        if let next = nextId.flatMap(document.index(ofBlock:)) { refreshSpacing(ofBlockAt: next) }
        return true
    }

    /// Набор после последнего перевода строки (правка текста в обход `PageTextView`) или удалённый весь текст:
    /// последний абзац снова получает перевод строки.
    private func restoreFinalNewline() {
        let length = textStorage.length
        guard length == 0 || (textStorage.string as NSString).character(at: length - 1) != Self.newline else { return }
        let attributes = length > 0
            ? textStorage.attributes(at: length - 1, effectiveRange: nil)
            : document.blocks.last.map { Self.baseAttributes(for: $0, after: previousKind(ofBlockAt: document.blocks.count - 1)) } ?? [:]
        applying { textStorage.append(NSAttributedString(string: "\n", attributes: attributes)) }
    }

    /// Какой блок стал каждым абзацем. Абзац остаётся своим блоком, если на его символах есть id
    /// заменяемого блока, ещё не занятый абзацем выше. Абзац без такого id берёт по порядку блок,
    /// оставшийся без абзаца, иначе это новый блок —
    /// того же вида, что блок, от которого он отделился (Enter). Enter в начале блока оставляет блок
    /// с его текстом, а новым становится пустой абзац над ним.
    private func blockDrafts(for paragraphs: [NSRange], replacing replaced: [Block]) -> [BlockDraft] {
        let string = textStorage.string as NSString
        let replacedIds = Set(replaced.map(\.id))
        let paragraphIds = paragraphs.map(blockIds(in:))
        let isEmpty = paragraphs.map { Self.contentRange(of: $0, in: string).isEmpty }
        var used: Set<UUID> = []
        var assigned: [UUID?] = paragraphs.indices.map { index in
            let candidate = paragraphIds[index].first { replacedIds.contains($0) && !used.contains($0) }
            guard let candidate else { return nil }
            let next = index + 1
            // Enter в начале непустого блока: пустой абзац сверху — новый блок, а прежний id остаётся у текста.
            if isEmpty[index], next < paragraphs.count, !isEmpty[next], paragraphIds[next].first == candidate,
               let block = document.block(candidate), !block.text.string.isEmpty, block.kind != .pageLink { return nil }
            used.insert(candidate)
            return candidate
        }
        var spare = replaced.filter { !used.contains($0.id) }[...]
        for index in assigned.indices where assigned[index] == nil {
            assigned[index] = spare.popFirst()?.id
        }

        return zip(paragraphs, assigned).enumerated().map { position, pair in
            let (paragraph, id) = pair
            let text = Self.inlineText(in: textStorage, range: Self.contentRange(of: paragraph, in: string))
            if let id, let block = document.block(id) {
                return BlockDraft(id: id, kind: block.kind, text: text, indent: block.indent,
                                  isChecked: block.isChecked, linkedPageId: block.linkedPageId)
            }
            // Возврат удалённого абзаца (⌘Z): у его символов id блока, которого в документе уже нет.
            if let firstId = paragraphIds[position].first, document.block(firstId) == nil, paragraph.length > 0 {
                var draft = Self.blockDrafts(in: textStorage.attributedSubstring(from: paragraph)).first ?? BlockDraft(id: nil)
                draft.id = nil
                draft.text = text
                return draft
            }
            let source = paragraphIds[position].lazy.compactMap(document.block).first
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
                guard let block = document.block(id), let index = document.index(ofBlock: id) else { continue }
                let hasNewline = NSMaxRange(paragraph) > Self.contentRange(of: paragraph, in: string).upperBound
                let rendered = Self.paragraph(block, withNewline: hasNewline, after: previousKind(ofBlockAt: index))
                guard rendered.length == paragraph.length else { continue }
                rendered.enumerateAttributes(in: NSRange(location: 0, length: rendered.length)) { attributes, range, _ in
                    textStorage.setAttributes(attributes, range: NSRange(location: paragraph.location + range.location, length: range.length))
                }
            }
            textStorage.endEditing()
        }
    }

    /// Тип блока над блоком `index`: от него зависит отступ над блоком.
    func previousKind(ofBlockAt index: Int) -> BlockKind? {
        index > 0 && index <= document.blocks.count ? document.blocks[index - 1].kind : nil
    }

    /// Поправить отступ над блоком `index` после смены соседа сверху: не трогая текст и его оформление.
    private func refreshSpacing(ofBlockAt index: Int) {
        guard document.blocks.indices.contains(index) else { return }
        let range = characterRange(ofBlocksAt: index..<index + 1)
        guard range.length > 0 else { return }
        let spacing = Self.spacingBefore(document.blocks[index].kind, after: previousKind(ofBlockAt: index))
        let current = textStorage.attribute(.paragraphStyle, at: range.location, effectiveRange: nil) as? NSParagraphStyle
        guard current?.paragraphSpacingBefore != spacing else { return }
        applying {
            textStorage.beginEditing()
            textStorage.enumerateAttribute(.paragraphStyle, in: range) { value, run, _ in
                guard let style = (value as? NSParagraphStyle)?.mutableCopy() as? NSMutableParagraphStyle else { return }
                style.paragraphSpacingBefore = spacing
                textStorage.addAttribute(.paragraphStyle, value: style, range: run)
            }
            textStorage.endEditing()
        }
    }

    private func applying(_ change: () -> Void) {
        isApplying = true
        change()
        isApplying = false
    }

    // MARK: Блоки по месту в тексте

    /// Последний найденный абзац: следующий поиск идёт от него, а не от начала страницы.
    private var paragraphHint: (index: Int, location: Int) = (0, 0)

    /// Блок под местом текста и смещение от начала его абзаца.
    func blockPosition(at location: Int) -> (index: Int, offset: Int)? {
        let string = textStorage.string as NSString
        let length = string.length
        guard !document.blocks.isEmpty, length > 0 else { return nil }
        // Строка после последнего перевода строки — конец последнего блока.
        let clamped = min(location, length - 1)
        let paragraph = string.paragraphRange(for: NSRange(location: clamped, length: 0))
        guard let id = textStorage.attribute(.blockID, at: paragraph.location, effectiveRange: nil) as? UUID,
              let index = document.index(ofBlock: id) else { return nil }
        paragraphHint = (index, paragraph.location)
        return (index, clamped - paragraph.location)
    }

    /// Начало абзаца блока `index`.
    func paragraphStart(ofBlockAt index: Int) -> Int {
        let string = textStorage.string as NSString
        let length = string.length
        let count = document.blocks.count
        if index >= count { return length }
        guard index > 0 else { return 0 }

        var (current, location) = paragraphHint
        let hintIsValid = current < count && location < length
            && (location == 0 || string.character(at: location - 1) == Self.newline)
            && textStorage.attribute(.blockID, at: location, effectiveRange: nil) as? UUID == document.blocks[current].id
        if !hintIsValid || index < current / 2 { (current, location) = (0, 0) }
        while current < index, location < length {
            location = NSMaxRange(string.paragraphRange(for: NSRange(location: location, length: 0)))
            current += 1
        }
        while current > index, location > 0 {
            location = string.paragraphRange(for: NSRange(location: location - 1, length: 0)).location
            current -= 1
        }
        paragraphHint = (current, location)
        return location
    }

    /// Символы абзацев блоков `range`: от начала первого до начала следующего за последним.
    func characterRange(ofBlocksAt range: Range<Int>) -> NSRange {
        let start = paragraphStart(ofBlockAt: range.lowerBound)
        let end = range.upperBound < document.blocks.count ? paragraphStart(ofBlockAt: range.upperBound) : textStorage.length
        return NSRange(location: start, length: max(0, end - start))
    }

    /// Переписать символы `characters` абзацами блоков `range` документа — после правки блоков
    /// не через текст (тип, вложенность, перестановка).
    func renderBlocks(_ range: Range<Int>, replacing characters: NSRange) {
        let blocks = document.blocks
        let text = NSMutableAttributedString()
        for index in range {
            text.append(Self.paragraph(blocks[index], withNewline: true, after: previousKind(ofBlockAt: index)))
        }
        applying { textStorage.replaceCharacters(in: characters, with: text) }
        paragraphHint = (0, 0)
        refreshSpacing(ofBlockAt: range.upperBound)
    }

    /// Документ принял правки из базы (`PageDocument.applyExternalChanges`): переписать только абзацы
    /// от первого затронутого блока до последнего; абзацы до и после не трогаются.
    func renderExternalChanges(_ change: PageDocument.ExternalChange) {
        let string = textStorage.string as NSString
        var oldIds: [UUID?] = []
        var starts: [Int] = []
        var location = 0
        while location < string.length {
            starts.append(location)
            oldIds.append(textStorage.attribute(.blockID, at: location, effectiveRange: nil) as? UUID)
            location = NSMaxRange(string.paragraphRange(for: NSRange(location: location, length: 0)))
        }
        let newIds = document.blocks.map(\.id)
        let dirty = change.changedBlockIds.union(change.insertedBlockIds).union(change.removedBlockIds)
        func same(_ old: Int, _ new: Int) -> Bool { oldIds[old] == newIds[new] && !dirty.contains(newIds[new]) }
        var prefix = 0
        while prefix < oldIds.count, prefix < newIds.count, same(prefix, prefix) { prefix += 1 }
        var suffix = 0
        while suffix < oldIds.count - prefix, suffix < newIds.count - prefix,
              same(oldIds.count - 1 - suffix, newIds.count - 1 - suffix) { suffix += 1 }
        guard prefix < oldIds.count - suffix || prefix < newIds.count - suffix else { return }
        let start = prefix < starts.count ? starts[prefix] : string.length
        let end = oldIds.count - suffix < starts.count ? starts[oldIds.count - suffix] : string.length
        pendingRange = nil
        renderBlocks(prefix..<(newIds.count - suffix), replacing: NSRange(location: start, length: end - start))
    }

    // MARK: Блоки ⇄ текст

    static let newline = unichar(0x0A)
    /// Перенос строки внутри блока на странице (FR-032): разрыв строки, а не абзаца — TextKit оставляет обе строки
    /// в одном абзаце. В тексте блока тот же перенос — `\n` (data-model.md, «Перенос строки»); длина одна и та же,
    /// и отрезки оформления не сдвигаются.
    static let lineSeparator = unichar(0x2028)
    static let lineSeparatorString = "\u{2028}"

    /// Текст блока для страницы: переносы строк — разрывы строки.
    static func pageString(ofBlockText string: String) -> String {
        string.replacingOccurrences(of: "\n", with: lineSeparatorString)
    }

    /// Текст блока со страницы: разрывы строки — переносы `\n`.
    static func blockString(ofPageText string: String) -> String {
        string.replacingOccurrences(of: lineSeparatorString, with: "\n")
    }

    /// Текст страницы: абзацы блоков, каждый с переводом строки.
    public static func attributedText(for blocks: [Block]) -> NSAttributedString {
        let text = NSMutableAttributedString()
        for (index, block) in blocks.enumerated() {
            text.append(paragraph(block, withNewline: true, after: index > 0 ? blocks[index - 1].kind : nil))
        }
        return text
    }

    /// Блоки, записанные в тексте: по черновику на абзац.
    public static func blockDrafts(in text: NSAttributedString) -> [BlockDraft] {
        let string = text.string as NSString
        return paragraphRanges(in: string, from: 0, to: string.length).map { paragraph in
            let attributes = text.attributes(at: paragraph.location, effectiveRange: nil)
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

    /// Абзацы между `lower` и `upper` (границы абзацев).
    private static func paragraphRanges(in string: NSString, from lower: Int, to upper: Int) -> [NSRange] {
        var ranges: [NSRange] = []
        var location = lower
        while location < upper {
            let paragraph = string.paragraphRange(for: NSRange(location: location, length: 0))
            ranges.append(paragraph)
            location = NSMaxRange(paragraph)
        }
        return ranges
    }

    /// Абзац без завершающего перевода строки.
    static func contentRange(of paragraph: NSRange, in string: NSString) -> Range<Int> {
        var end = NSMaxRange(paragraph)
        if end > paragraph.location, string.character(at: end - 1) == newline { end -= 1 }
        return paragraph.location..<end
    }

    static func inlineText(in text: NSAttributedString, range: Range<Int>) -> InlineText {
        let nsRange = NSRange(location: range.lowerBound, length: range.count)
        let string = blockString(ofPageText: (text.string as NSString).substring(with: nsRange))
        var runs: [StyledRun] = []
        text.enumerateAttributes(in: nsRange) { attributes, run, _ in
            let start = run.location - range.lowerBound
            func add(_ style: InlineStyle) { runs.append(StyledRun(start: start, length: run.length, style: style)) }
            if attributes[.inlineBold] as? Bool == true { add(.bold) }
            if attributes[.inlineItalic] as? Bool == true { add(.italic) }
            if attributes[.inlineStrikethrough] as? Bool == true { add(.strikethrough) }
            if attributes[.inlineCode] as? Bool == true { add(.code) }
            if attributes[.inlineUnderline] as? Bool == true { add(.underline) }
            if let url = attributes[.inlineLink] as? URL { add(.link(url)) }
        }
        return InlineText(string, runs: runs).normalized()
    }

    // MARK: Вид

    static func paragraphAttributes(of block: Block) -> [NSAttributedString.Key: Any] {
        var attributes: [NSAttributedString.Key: Any] = [
            .blockID: block.id,
            .blockKind: block.kind.rawValue,
            .blockIndent: block.indent,
            .blockChecked: block.isChecked,
        ]
        attributes[.blockLinkedPage] = block.linkedPageId
        return attributes
    }

    /// Атрибуты, с которыми набирается текст абзаца блока.
    public static func typingAttributes(for block: Block, after previous: BlockKind? = nil) -> [NSAttributedString.Key: Any] {
        baseAttributes(for: block, after: previous)
    }

    /// Атрибуты набора блока с оформлением в строке из `inline` (жирный, курсив и т. д.).
    static func typingAttributes(for block: Block, after previous: BlockKind? = nil,
                                 inline: [NSAttributedString.Key: Any]) -> [NSAttributedString.Key: Any] {
        var attributes = baseAttributes(for: block, after: previous)
        for key in inlineKeys { attributes[key] = inline[key] }
        return attributes.merging(inlineRendering(attributes, line: Typography.line(for: textStyle(of: block.kind)))) { $1 }
    }

    static let inlineKeys: [NSAttributedString.Key] = [.inlineBold, .inlineItalic, .inlineStrikethrough, .inlineCode, .inlineUnderline, .inlineLink]

    static func textStyle(of kind: BlockKind) -> BlockTextStyle {
        switch kind {
        case .heading1: .heading1
        case .heading2: .heading2
        case .heading3: .heading3
        case .bulletItem, .numberedItem, .checkbox: .listItem
        case .paragraph, .pageLink: .paragraph
        }
    }

    /// Отступ над блоком: свой у типа блока, между абзацем и пунктом, чекбоксом или подстраницей — больше,
    /// как у Notion (contracts/visual-style.md, «Блоки»).
    static func spacingBefore(_ kind: BlockKind, after previous: BlockKind?) -> CGFloat {
        let own = Metrics.block(textStyle(of: kind)).topSpacing
        guard let previous else { return own }
        let listLike: Set<BlockKind> = [.bulletItem, .numberedItem, .checkbox, .pageLink]
        let crossesGroup = kind == .paragraph && listLike.contains(previous) || previous == .paragraph && listLike.contains(kind)
        return crossesGroup ? own + Metrics.Page.paragraphListSpacing : own
    }

    static func baseAttributes(for block: Block, after previous: BlockKind? = nil) -> [NSAttributedString.Key: Any] {
        let style = textStyle(of: block.kind)
        let line = Typography.line(for: style)
        let spacing = Metrics.block(style)
        let paragraphStyle = (line.paragraphStyle.mutableCopy() as? NSMutableParagraphStyle) ?? NSMutableParagraphStyle()
        paragraphStyle.paragraphSpacingBefore = spacingBefore(block.kind, after: previous)
        paragraphStyle.paragraphSpacing = max(0, spacing.height - line.lineHeight - spacing.topSpacing)
        let marker: CGFloat = block.kind.hasMarkerColumn ? Metrics.BlockMarker.textInset : 0
        let indent = CGFloat(block.indent) * Metrics.Page.indentPerLevel + marker
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
    static func paragraph(_ block: Block, withNewline: Bool, after previous: BlockKind? = nil) -> NSAttributedString {
        let base = baseAttributes(for: block, after: previous)
        let line = Typography.line(for: textStyle(of: block.kind))
        let text = NSMutableAttributedString(string: pageString(ofBlockText: block.text.string), attributes: base)
        let length = text.length
        for run in block.text.normalized().runs {
            let range = NSRange(location: run.start, length: run.length)
            guard run.start >= 0, NSMaxRange(range) <= length else { continue }
            switch run.style {
            case .bold: text.addAttribute(.inlineBold, value: true, range: range)
            case .italic: text.addAttribute(.inlineItalic, value: true, range: range)
            case .strikethrough: text.addAttribute(.inlineStrikethrough, value: true, range: range)
            case .code: text.addAttribute(.inlineCode, value: true, range: range)
            case .underline: text.addAttribute(.inlineUnderline, value: true, range: range)
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
        // Подчёркнутый — линия цвета текста; у подчёркнутой ссылки тоже, вместо серой линии ссылки.
        if attributes[.inlineUnderline] as? Bool == true {
            rendering[.underlineStyle] = NSUnderlineStyle.single.rawValue
        } else if attributes[.inlineLink] is URL {
            rendering[.underlineStyle] = NSUnderlineStyle.single.rawValue
            rendering[.underlineColor] = Palette.linkUnderline
        }
        return rendering
    }
}

extension BlockKind {
    /// Слева от текста — колонка маркера, номера, квадрата чекбокса или значка подстраницы.
    var hasMarkerColumn: Bool {
        switch self {
        case .bulletItem, .numberedItem, .checkbox, .pageLink: true
        case .paragraph, .heading1, .heading2, .heading3: false
        }
    }
}
