import AppKit
import NotesCore

/// Оформление в строке, ссылки и вставка из других программ (FR-010; contracts/editor-interactions.md).
public enum InlineFormatting {
    /// Весь ли отрезок `range` текста оформлен так.
    static func covers(_ text: InlineText, with format: InlineFormat, in range: Range<Int>) -> Bool {
        guard !range.isEmpty else { return false }
        var covered = IndexSet()
        for run in text.runs where run.style == format.style {
            covered.insert(integersIn: run.start..<run.start + run.length)
        }
        return covered.contains(integersIn: range)
    }

    /// Весь ли отрезок `range` текста — ссылка (любая).
    static func coversLink(_ text: InlineText, in range: Range<Int>) -> Bool {
        guard !range.isEmpty else { return false }
        var covered = IndexSet()
        for run in text.runs {
            if case .link = run.style { covered.insert(integersIn: run.start..<run.start + run.length) }
        }
        return covered.contains(integersIn: range)
    }

    /// Текст, где отрезок `range` оформлен (`enabled`) или освобождён от оформления.
    static func text(_ text: InlineText, setting format: InlineFormat, to enabled: Bool, in range: Range<Int>) -> InlineText {
        var runs = text.runs.flatMap { run in run.style == format.style ? subtract(range, from: run) : [run] }
        if enabled { runs.append(StyledRun(start: range.lowerBound, length: range.count, style: format.style)) }
        return InlineText(text.string, runs: runs).normalized()
    }

    /// Текст без оформления, ссылок и цветов на отрезке `range`; упоминания, даты и формулы остаются.
    static func text(_ text: InlineText, clearingFormatsIn range: Range<Int>) -> InlineText {
        let runs = text.runs.flatMap { run in run.style.isAtom ? [run] : subtract(range, from: run) }
        return InlineText(text.string, runs: runs).normalized()
    }

    /// Текст со ссылкой `url` на отрезке `range`; `nil` — ссылку убрать.
    static func text(_ text: InlineText, settingLink url: URL?, in range: Range<Int>) -> InlineText {
        var runs = text.runs.flatMap { run -> [StyledRun] in
            if case .link = run.style { return subtract(range, from: run) }
            return [run]
        }
        if let url { runs.append(StyledRun(start: range.lowerBound, length: range.count, style: .link(url))) }
        return InlineText(text.string, runs: runs).normalized()
    }

    static func subtract(_ range: Range<Int>, from run: StyledRun) -> [StyledRun] {
        let runRange = run.start..<run.start + run.length
        guard runRange.overlaps(range) else { return [run] }
        var parts: [StyledRun] = []
        if runRange.lowerBound < range.lowerBound {
            parts.append(StyledRun(start: runRange.lowerBound, length: range.lowerBound - runRange.lowerBound, style: run.style))
        }
        if runRange.upperBound > range.upperBound {
            parts.append(StyledRun(start: range.upperBound, length: runRange.upperBound - range.upperBound, style: run.style))
        }
        return parts
    }

    // MARK: Адреса

    private static let linkSchemes: Set<String> = ["http", "https", "mailto"]

    /// Адрес из поля «Формат → Ссылка»: http, https или mailto; без схемы — https, если похоже на адрес сайта.
    public static func linkURL(from input: String) -> URL? {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.contains(where: \.isWhitespace) else { return nil }
        if let url = URL(string: trimmed), let scheme = url.scheme?.lowercased() {
            if linkSchemes.contains(scheme), scheme == "mailto" || url.host() != nil { return url }
            if trimmed.contains("://") || !trimmed.contains(".") { return nil }
        }
        guard let host = trimmed.split(separator: "/").first, host.contains("."), !host.hasPrefix("."), !host.hasSuffix(".") else { return nil }
        return URL(string: "https://" + trimmed)
    }

    /// Можно ли открыть адрес: http и https с сайтом или mailto. Ссылки с другого Mac и из импорта не проверялись при
    /// вводе, а smb, ssh, vnc, file и подобные подключают диски, запускают программы или открывают файлы Mac.
    public static func isOpenable(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(), linkSchemes.contains(scheme) else { return false }
        return scheme == "mailto" || url.host()?.isEmpty == false
    }

    /// Вставленный текст, который делает выделение ссылкой: только адрес со схемой, без других слов.
    public static func pastedLinkURL(from string: String) -> URL? {
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.contains(where: \.isWhitespace), let url = URL(string: trimmed),
              let scheme = url.scheme?.lowercased(), linkSchemes.contains(scheme) else { return nil }
        return scheme == "mailto" || url.host() != nil ? url : nil
    }

    // MARK: Вставка из других программ

    /// Текст из другой программы с оформлением, которое есть на странице: жирный, курсив, зачёркнутый, подчёркнутый,
    /// моноширинный шрифт как код, ссылки. Остальное (шрифты, размеры, цвета) отбрасывается.
    static func pastedText(from source: NSAttributedString) -> NSAttributedString {
        let result = NSMutableAttributedString()
        source.enumerateAttributes(in: NSRange(location: 0, length: source.length)) { attributes, range, _ in
            var inline: [NSAttributedString.Key: Any] = [:]
            if let font = attributes[.font] as? NSFont {
                let traits = font.fontDescriptor.symbolicTraits
                if traits.contains(.monoSpace) {
                    inline[.inlineCode] = true
                } else {
                    if traits.contains(.bold) { inline[.inlineBold] = true }
                    if traits.contains(.italic) { inline[.inlineItalic] = true }
                }
            }
            if let strike = attributes[.strikethroughStyle] as? Int, strike != 0 { inline[.inlineStrikethrough] = true }
            if let underline = attributes[.underlineStyle] as? Int, underline != 0, attributes[.link] == nil { inline[.inlineUnderline] = true }
            let link = (attributes[.link] as? URL) ?? (attributes[.link] as? String).flatMap(URL.init(string:))
            if let link, let scheme = link.scheme?.lowercased(), linkSchemes.contains(scheme) { inline[.inlineLink] = link }
            let piece = normalizedNewlines((source.string as NSString).substring(with: range))
            result.append(NSAttributedString(string: piece, attributes: inline))
        }
        return result
    }

    /// Переводы строк других программ (`\r\n`, `\r`, разделители строк и абзацев) — в `\n`.
    static func normalizedNewlines(_ string: String) -> String {
        string.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .replacingOccurrences(of: "\u{2028}", with: "\n")
            .replacingOccurrences(of: "\u{2029}", with: "\n")
    }

    static let richPasteboardTypes: [NSPasteboard.PasteboardType] = [.rtf, .rtfd, .html]
}

extension PageTextView {
    // MARK: Оформление в строке

    func toggleInline(_ format: InlineFormat) {
        commitEdits()
        let selection = selectedRange()
        guard selection.length > 0 else {
            toggleTypingStyle(format)
            return
        }
        guard let blocks = selectedBlockRange() else { return }
        let pieces = blocks.map { index in (index, localRange(of: selection, inBlockAt: index)) }
        let enabled = !pieces.allSatisfy { index, range in
            range.isEmpty || InlineFormatting.covers(document.blocks[index].text, with: format, in: range)
        }
        let drafts = pieces.map { index, range in
            var draft = BlockDraft(document.blocks[index])
            if !range.isEmpty { draft.text = InlineFormatting.text(draft.text, setting: format, to: enabled, in: range) }
            return draft
        }
        changeBlocks(blocks, to: drafts, actionName: "Оформление")
    }

    /// «Tx»: снять с выделения оформление, ссылки и цвета одним шагом ⌘Z.
    func clearInlineFormatting() {
        commitEdits()
        let selection = selectedRange()
        guard selection.length > 0, let blocks = selectedBlockRange() else { return }
        let drafts = blocks.map { index in
            var draft = BlockDraft(document.blocks[index])
            let range = localRange(of: selection, inBlockAt: index)
            if !range.isEmpty { draft.text = InlineFormatting.text(draft.text, clearingFormatsIn: range) }
            return draft
        }
        changeBlocks(blocks, to: drafts, actionName: "Убрать оформление")
    }

    /// Без выделения ⌘B и т. п. включают оформление для набираемого текста.
    private func toggleTypingStyle(_ format: InlineFormat) {
        guard let position = mapper.blockPosition(at: selectedRange().location) else { return }
        let key: NSAttributedString.Key = switch format {
        case .bold: .inlineBold
        case .italic: .inlineItalic
        case .strikethrough: .inlineStrikethrough
        case .code: .inlineCode
        case .underline: .inlineUnderline
        }
        var inline = typingAttributes
        inline[key] = inline[key] as? Bool == true ? nil : true
        typingAttributes = PageTextStorageMapper.typingAttributes(for: document.blocks[position.index],
                                                                 after: mapper.previousKind(ofBlockAt: position.index), inline: inline)
    }

    /// Ссылка на выделенном тексте; `nil` — убрать (меню «Формат → Ссылка»).
    public func setLink(_ url: URL?) {
        commitEdits()
        let selection = selectedRange()
        guard selection.length > 0, let blocks = selectedBlockRange() else { return }
        let drafts = blocks.map { index in
            var draft = BlockDraft(document.blocks[index])
            let range = localRange(of: selection, inBlockAt: index)
            if !range.isEmpty { draft.text = InlineFormatting.text(draft.text, settingLink: url, in: range) }
            return draft
        }
        changeBlocks(blocks, to: drafts, actionName: "Ссылка")
    }

    /// ⌘-щелчок по тексту ссылки открывает её адрес, как в Notion. Простой щелчок ставит курсор.
    func openLink(at point: NSPoint, modifiers: NSEvent.ModifierFlags) -> Bool {
        guard modifiers.contains(.command), let url = link(at: point) else { return false }
        if InlineFormatting.isOpenable(url) { openURL(url) } else { NSSound.beep() }
        return true
    }

    /// Ссылка под точкой (координаты окна текста): знак ссылки, рамка которого содержит точку.
    private func link(at point: NSPoint) -> URL? {
        guard let storage = textStorage, let window else { return nil }
        let index = characterIndexForInsertion(at: point)
        for candidate in [index, index - 1] where candidate >= 0 && candidate < storage.length {
            guard let url = storage.attribute(.inlineLink, at: candidate, effectiveRange: nil) as? URL else { continue }
            let onScreen = firstRect(forCharacterRange: NSRange(location: candidate, length: 1), actualRange: nil)
            if convert(window.convertFromScreen(onScreen), from: nil).contains(point) { return url }
        }
        return nil
    }

    /// Ссылка, которая уже стоит на выделении.
    private var selectedLink: URL? {
        let selection = selectedRange()
        guard selection.length > 0, let storage = textStorage, selection.location < storage.length else { return nil }
        return storage.attribute(.inlineLink, at: selection.location, effectiveRange: nil) as? URL
    }

    /// Часть выделения внутри текста блока, в смещениях от начала его текста.
    func localRange(of selection: NSRange, inBlockAt index: Int) -> Range<Int> {
        // У блока без своего текста на странице оформлять нечего.
        guard !document.blocks[index].kind.rendersAsAttachment else { return 0..<0 }
        let start = mapper.paragraphStart(ofBlockAt: index)
        let length = document.blocks[index].pageTextLength
        let lower = max(selection.location, start), upper = min(NSMaxRange(selection), start + length)
        return lower < upper ? lower - start..<upper - start : 0..<0
    }

    // MARK: Меню «Формат»

    @objc public func toggleBoldStyle(_ sender: Any?) { perform(.toggleInline(.bold)) }
    @objc public func toggleItalicStyle(_ sender: Any?) { perform(.toggleInline(.italic)) }
    @objc public func toggleStrikethroughStyle(_ sender: Any?) { perform(.toggleInline(.strikethrough)) }
    @objc public func toggleCodeStyle(_ sender: Any?) { perform(.toggleInline(.code)) }
    @objc public func toggleUnderlineStyle(_ sender: Any?) { perform(.toggleInline(.underline)) }

    /// «Формат → Ссылка»: окно с полем адреса поверх окна страницы; пустой адрес убирает ссылку.
    /// Окно страницы не на экране (модульные проверки) — окна адреса нет: не всплывать поверх чужих программ.
    @objc public func editLink(_ sender: Any?) {
        guard selectedRange().length > 0, let window, window.isVisible else {
            NSSound.beep()
            return
        }
        let alert = NSAlert()
        alert.messageText = "Ссылка"
        alert.informativeText = "Адрес для выделенного текста. Пустое поле убирает ссылку."
        let field = NSTextField(string: selectedLink?.absoluteString ?? "")
        field.placeholderString = "https://"
        field.frame = NSRect(x: 0, y: 0, width: 300, height: 24)
        alert.accessoryView = field
        alert.addButton(withTitle: "Готово")
        alert.addButton(withTitle: "Отменить")
        alert.window.initialFirstResponder = field
        let apply: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            guard let self, response == .alertFirstButtonReturn else { return }
            let input = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            if input.isEmpty {
                setLink(nil)
            } else if let url = InlineFormatting.linkURL(from: input) {
                setLink(url)
            } else {
                NSSound.beep()
            }
            window.makeFirstResponder(self)
        }
        alert.beginSheetModal(for: window, completionHandler: apply)
    }

    // MARK: Вставка

    /// Вставка: адрес поверх выделения — ссылка; текст другой программы — с поддерживаемым оформлением;
    /// всё прочее — простым текстом.
    public func paste(from pasteboard: NSPasteboard) {
        commitEdits()
        let selection = selectedRange()
        if pasteInlineText(from: pasteboard, replacing: selection) { return }
        // Файлы из Finder и картинка из буфера — блоками (US5).
        if Self.pasteboardHasAttachments(pasteboard) {
            Task { await pasteAttachments(from: pasteboard) }
            return
        }
        let plain = pasteboard.string(forType: .string)
        if selection.length > 0, let plain, let url = InlineFormatting.pastedLinkURL(from: plain) {
            setLink(url)
            return
        }
        if let rich = Self.richText(from: pasteboard) {
            var pasted = InlineFormatting.pastedText(from: rich)
            if let plain, !plain.hasSuffix("\n"), pasted.string.hasSuffix("\n") {
                pasted = pasted.attributedSubstring(from: NSRange(location: 0, length: (pasted.string as NSString).length - 1))
            }
            insertPasted(pasted, replacing: selection)
            return
        }
        guard let plain else { return }
        insertPasted(NSAttributedString(string: InlineFormatting.normalizedNewlines(plain)), replacing: selection)
        // Адрес ролика в пустой строке — меню «Встроить видео / Закладка / Ссылка».
        if selection.length == 0 { offerPastedVideoLink(InlineFormatting.normalizedNewlines(plain), at: selection.location) }
    }

    private static func richText(from pasteboard: NSPasteboard) -> NSAttributedString? {
        guard let type = pasteboard.availableType(from: InlineFormatting.richPasteboardTypes), let data = pasteboard.data(forType: type) else {
            return nil
        }
        let documentType: NSAttributedString.DocumentType = switch type {
        case .rtfd: .rtfd
        case .html: .html
        default: .rtf
        }
        return try? NSAttributedString(data: data, options: [.documentType: documentType], documentAttributes: nil)
    }

    /// Вставить текст с атрибутами блока под курсором и оформлением в строке из `pasted`.
    private func insertPasted(_ pasted: NSAttributedString, replacing selection: NSRange) {
        guard pasted.length > 0, let position = mapper.blockPosition(at: selection.location) else { return }
        let block = document.blocks[position.index]
        let text = NSMutableAttributedString(string: pasted.string, attributes: PageTextStorageMapper.typingAttributes(for: block, inline: [:]))
        pasted.enumerateAttributes(in: NSRange(location: 0, length: pasted.length)) { attributes, range, _ in
            let styled = PageTextStorageMapper.typingAttributes(for: block, inline: attributes)
            text.setAttributes(styled, range: range)
        }
        breakUndoCoalescing()
        replaceText(in: selection, with: text)
        setSelectedRange(NSRange(location: selection.location + text.length, length: 0))
        scrollRangeToVisible(selectedRange())
    }
}
