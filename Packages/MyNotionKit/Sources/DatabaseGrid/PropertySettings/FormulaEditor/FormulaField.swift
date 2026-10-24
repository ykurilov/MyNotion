import AppKit
import Formulas
import NotesCore
import VisualStyle

/// Плашка свойства в поле формулы: один знак текста вместо `prop("Название")`, как у Notion (значок типа и название).
final class FormulaChipAttachment: NSTextAttachment {
    let property: FormulaProperty
    let kind: PropertyKind

    init(property: FormulaProperty, kind: PropertyKind, font: NSFont) {
        self.property = property
        self.kind = kind
        super.init(data: nil, ofType: nil)
        let text = property.name as NSString
        let textFont = NSFont.systemFont(ofSize: font.pointSize - 1, weight: .regular)
        let textWidth = ceil(text.size(withAttributes: [.font: textFont]).width)
        let size = NSSize(width: textWidth + 28, height: font.pointSize + 6)
        let symbol = CellKind.for(kind).symbol
        image = NSImage(size: size, flipped: false) { rect in
            let path = NSBezierPath(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), xRadius: 4, yRadius: 4)
            Palette.inlineCodeBackground.setFill()
            path.fill()
            if let icon = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: font.pointSize - 3, weight: .regular)) {
                let tinted = icon.tinted(Palette.textSecondary)
                tinted.draw(in: NSRect(x: 5, y: (rect.height - tinted.size.height) / 2, width: tinted.size.width, height: tinted.size.height))
            }
            text.draw(at: NSPoint(x: 21, y: (rect.height - textFont.ascender + textFont.descender) / 2 - 1),
                      withAttributes: [.font: textFont, .foregroundColor: Palette.textPrimary])
            return true
        }
        bounds = NSRect(x: 0, y: font.descender - 2, width: size.width, height: size.height)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) не используется") }

    /// Текст формулы вместо плашки.
    var formulaText: String { "prop(" + FormulaSource.quoted(property.name) + ")" }
}

extension NSImage {
    /// Значок того же рисунка в цвете `color`.
    func tinted(_ color: NSColor) -> NSImage {
        NSImage(size: size, flipped: false) { rect in
            self.draw(in: rect)
            color.set()
            rect.fill(using: .sourceAtop)
            return true
        }
    }
}

/// Текст поля ↔ текст формулы: плашки разворачиваются в `prop("…")`; места формулы (символы) ↔ места поля (UTF-16).
struct FormulaFieldText {
    let text: String
    /// Место в поле для каждого символа формулы и для конца (`count + 1`).
    let fieldOffsets: [Int]

    init(_ storage: NSAttributedString) {
        var text = "", offsets: [Int] = []
        let string = storage.string as NSString
        storage.enumerateAttribute(.attachment, in: NSRange(location: 0, length: storage.length)) { value, range, _ in
            if let chip = value as? FormulaChipAttachment {
                for index in 0..<range.length {
                    for _ in chip.formulaText { offsets.append(range.location + index) }
                    text += chip.formulaText
                }
                return
            }
            let piece = string.substring(with: range)
            var location = range.location
            for character in piece {
                offsets.append(location)
                location += character.utf16.count
            }
            text += piece
        }
        offsets.append(storage.length)
        self.text = text
        fieldOffsets = offsets
    }

    func fieldRange(_ range: Range<Int>) -> NSRange {
        let lower = fieldLocation(range.lowerBound)
        // Конец — место символа после куска: у плашки это знак за ней, у двойного знака UTF-16 — после обеих половин.
        var upper = fieldLocation(range.upperBound)
        if upper == lower, range.upperBound > range.lowerBound { upper = lower + 1 }
        return NSRange(location: lower, length: max(0, upper - lower))
    }

    func fieldLocation(_ offset: Int) -> Int { fieldOffsets[min(max(0, offset), fieldOffsets.count - 1)] }

    /// Место формулы для места поля (каретка после плашки — после всего `prop("…")`).
    func formulaOffset(_ location: Int) -> Int {
        guard let index = fieldOffsets.lastIndex(where: { $0 < location }) else { return 0 }
        return index + 1
    }
}

/// Поле формулы: моноширинный текст, подсказка «Ваша формула» в пустом поле, рамка цвета фокуса.
final class FormulaTextView: NSTextView {
    var placeholder = "Ваша формула"
    var onFocusChange: ((Bool) -> Void)?

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard string.isEmpty else { return }
        (placeholder as NSString).draw(at: NSPoint(x: textContainerInset.width + 5, y: textContainerInset.height),
                                       withAttributes: [.font: font ?? .systemFont(ofSize: 13), .foregroundColor: Palette.textSecondary])
    }

    override func becomeFirstResponder() -> Bool {
        let became = super.becomeFirstResponder()
        if became { onFocusChange?(true) }
        return became
    }

    override func resignFirstResponder() -> Bool {
        let resigned = super.resignFirstResponder()
        if resigned { onFocusChange?(false) }
        return resigned
    }
}
