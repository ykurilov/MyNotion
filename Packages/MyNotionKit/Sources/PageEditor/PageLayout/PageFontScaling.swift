import AppKit

extension NSAttributedString.Key {
    /// Шкала, в которой записаны размеры знака (мелкий шрифт страницы, research R2); нет атрибута — 1.
    /// По ней пересчёт идёт от записанного размера, а не от прежнего: повтор ничего не портит.
    static let pageFontScale = NSAttributedString.Key("MyNotion.pageFontScale")
}

/// Размеры текста блоков в шкале страницы: шрифт, высота строк и отступы абзаца × шкала; отступы вложенности — нет.
enum PageFontScaling {
    static func scaled(_ attributes: [NSAttributedString.Key: Any], to scale: CGFloat) -> [NSAttributedString.Key: Any] {
        let current = attributes[.pageFontScale] as? CGFloat ?? 1
        guard current != scale else { return attributes }
        let ratio = scale / current
        var result = attributes
        if let font = attributes[.font] as? NSFont { result[.font] = font.withSize(font.pointSize * ratio) }
        if let style = (attributes[.paragraphStyle] as? NSParagraphStyle)?.mutableCopy() as? NSMutableParagraphStyle {
            style.minimumLineHeight *= ratio
            style.maximumLineHeight *= ratio
            style.paragraphSpacing *= ratio
            style.paragraphSpacingBefore *= ratio
            result[.paragraphStyle] = style
        }
        result[.pageFontScale] = scale == 1 ? nil : scale
        return result
    }

    /// Перевести отрезок текста в шкалу `scale`; части, уже в ней, не трогаются.
    static func rescale(_ text: NSMutableAttributedString, in range: NSRange, to scale: CGFloat) {
        var runs: [(NSRange, [NSAttributedString.Key: Any])] = []
        text.enumerateAttributes(in: range) { attributes, run, _ in
            if (attributes[.pageFontScale] as? CGFloat ?? 1) != scale { runs.append((run, attributes)) }
        }
        guard !runs.isEmpty else { return }
        text.beginEditing()
        for (run, attributes) in runs { text.setAttributes(scaled(attributes, to: scale), range: run) }
        text.endEditing()
    }

    /// Готовый текст в шкале `scale` (при 1 — тот же).
    static func scaled(_ text: NSAttributedString, to scale: CGFloat) -> NSAttributedString {
        guard scale != 1 else { return text }
        let copy = NSMutableAttributedString(attributedString: text)
        rescale(copy, in: NSRange(location: 0, length: copy.length), to: scale)
        return copy
    }
}
