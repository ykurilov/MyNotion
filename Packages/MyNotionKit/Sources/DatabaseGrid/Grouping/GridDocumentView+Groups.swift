import AppKit
import CoreText
import Databases
import VisualStyle

/// Полосы групп и итогов в документе сетки (US3, contracts/database-ui.md, «Группы в таблице»): заголовок группы
/// («▾», плашка или текст, число строк серым), «+ Новая строка» группы, строка итогов, «+ Новая группа»; перенесённый
/// текст ячейки.
extension GridDocumentView {
    func drawDecorations(in dirtyRect: NSRect, context: CGContext) {
        let width = max(tableWidth, 120)
        for decoration in layout.decorations where decoration.top < dirtyRect.maxY && decoration.top + decoration.height > dirtyRect.minY {
            let rect = NSRect(x: 0, y: decoration.top, width: width, height: decoration.height)
            switch decoration.item {
            case .groupHeader(let index):
                guard let section = grid?.groupSections?[safe: index] else { continue }
                drawGroupHeader(section, in: rect, context: context)
            case .groupNewRow:
                drawButtonRow(GridStrings.newRow, in: rect, hovered: hoverDecoration == decoration.item, context: context)
            case .newGroup:
                drawButtonRow(GridStrings.newGroup, in: rect, hovered: hoverDecoration == decoration.item, context: context)
            case .groupTotals(let index):
                let key = grid?.groupSections?[safe: index]?.key
                drawTotals(key.flatMap { grid?.totals.groups[$0] } ?? [:], in: rect, hovered: hoverDecoration == decoration.item, context: context)
            case .totals:
                drawTotals(grid?.totals.overall ?? [:], in: rect, hovered: hoverDecoration == decoration.item, context: context)
            case .newRow:
                continue
            }
        }
    }

    private func drawGroupHeader(_ section: GridGroupSection, in rect: NSRect, context: CGContext) {
        let chevron = GridSymbols.image(section.isCollapsed ? "chevron.right" : "chevron.down", size: 11, color: Palette.textSecondary, weight: .semibold)
        let chevronRect = NSRect(x: rect.minX + 4, y: rect.midY - 8, width: 16, height: 16)
        chevron.draw(in: NSRect(x: chevronRect.midX - chevron.size.width / 2, y: chevronRect.midY - chevron.size.height / 2,
                                width: chevron.size.width, height: chevron.size.height))
        var x = chevronRect.maxX + 6
        let font = NSFont.systemFont(ofSize: Metrics.DatabaseGrid.fontSize, weight: .medium)
        switch section.label {
        case .option(let name, let color):
            let title = NSAttributedString(string: name, attributes: [.font: NSFont.systemFont(ofSize: Metrics.DatabaseGrid.chipFontSize),
                                                                      .foregroundColor: Palette.optionChipText])
            let size = title.size()
            let chip = NSRect(x: x, y: rect.midY - Metrics.DatabaseGrid.chipHeight / 2,
                              width: ceil(size.width) + 2 * Metrics.DatabaseGrid.chipHorizontalPadding, height: Metrics.DatabaseGrid.chipHeight)
            Palette.optionChipBackground(color.rawValue).setFill()
            NSBezierPath(roundedRect: chip, xRadius: Metrics.DatabaseGrid.chipCornerRadius, yRadius: Metrics.DatabaseGrid.chipCornerRadius).fill()
            title.draw(at: NSPoint(x: chip.minX + Metrics.DatabaseGrid.chipHorizontalPadding, y: chip.midY - size.height / 2))
            x = chip.maxX + 10
        case .text(let name), .empty(let name):
            let color = if case .empty = section.label { Palette.textSecondary } else { Palette.textPrimary }
            let title = NSAttributedString(string: name, attributes: [.font: font, .foregroundColor: color])
            let size = title.size()
            title.draw(at: NSPoint(x: x, y: rect.midY - size.height / 2))
            x += ceil(size.width) + 10
        }
        let count = NSAttributedString(string: "\(section.count)", attributes: [.font: NSFont.systemFont(ofSize: 14), .foregroundColor: Palette.textSecondary])
        count.draw(at: NSPoint(x: x, y: rect.midY - count.size().height / 2))
    }

    private func drawButtonRow(_ title: String, in rect: NSRect, hovered: Bool, context: CGContext) {
        if hovered {
            context.setFillColor(Palette.hoverBackground.cgColor)
            context.fill(rect)
        }
        let symbol = GridSymbols.image("plus", size: 13, color: Palette.textSecondary)
        let iconRect = CGRect(x: rect.minX + Metrics.DatabaseGrid.cellHorizontalPadding, y: rect.midY - 8, width: 16, height: 16)
        symbol.draw(in: iconRect)
        text.draw(title, in: CGRect(x: iconRect.maxX + 6, y: rect.minY, width: rect.width - iconRect.maxX - 6, height: rect.height),
                  color: Palette.textSecondary, alignment: .left, context: context)
    }

    /// Строка итогов: у колонки с итогом — «ПОДПИСЬ значение» у правого края; без итога под мышью — серое «Посчитать».
    private func drawTotals(_ totals: [UUID: ColumnTotal], in rect: NSRect, hovered: Bool, context: CGContext) {
        var x: CGFloat = 0
        let labelFont = NSFont.systemFont(ofSize: 11, weight: .medium)
        for column in content.columns {
            let cell = NSRect(x: x, y: rect.minY, width: column.width, height: rect.height).insetBy(dx: Metrics.DatabaseGrid.cellHorizontalPadding, dy: 0)
            x += column.width
            let string = NSMutableAttributedString()
            if let total = totals[column.property.id] {
                string.append(NSAttributedString(string: total.label + " ", attributes: [.font: labelFont, .foregroundColor: Palette.textSecondary,
                                                                                      .kern: 0.5]))
                string.append(NSAttributedString(string: total.value, attributes: [.font: NSFont.systemFont(ofSize: 14), .foregroundColor: Palette.textPrimary]))
            } else if hovered {
                string.append(NSAttributedString(string: GridStrings.calculate, attributes: [.font: NSFont.systemFont(ofSize: 13),
                                                                                           .foregroundColor: Palette.textSecondary]))
            } else {
                continue
            }
            let size = string.size()
            let width = min(size.width, cell.width)
            string.draw(with: NSRect(x: cell.maxX - width, y: rect.midY - size.height / 2, width: width, height: size.height),
                        options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
        }
    }

    /// Перенесённый текст: у названия — значок слева, текст от верха ячейки.
    func drawWrapped(_ string: String, in rect: CGRect, column: GridColumn, icon: String??, context: CGContext) {
        var inner = rect.insetBy(dx: Metrics.DatabaseGrid.cellHorizontalPadding, dy: 0)
        if let icon {
            let iconRect = CGRect(x: inner.minX, y: rect.minY + (Metrics.DatabaseGrid.rowHeight - 18) / 2, width: 18, height: 18)
            if let emoji = icon {
                text.draw(emoji, in: iconRect.insetBy(dx: -1, dy: 0), color: Palette.textPrimary, alignment: .left, context: context)
            } else {
                GridSymbols.documentGlyph.draw(in: iconRect.insetBy(dx: 1, dy: 1))
            }
            inner.origin.x += 24
            inner.size.width -= 24
        }
        WrappedText.draw(string, in: inner, color: Palette.textPrimary, weight: column.property.kind == .title ? .medium : .regular,
                         alignment: column.alignsRight ? .right : .left, context: context)
    }
}

extension GridStrings {
    static let newGroup = "Новая группа"
    static let calculate = "Посчитать"
}

/// Подсветка найденного поиском в базе (contracts/database-ui.md, «Поиск в базе»): серая плашка под вхождением.
enum SearchHighlight {
    @MainActor
    static func fill(_ needle: String, in text: String, line: CTLine, origin: CGFloat, rect: CGRect, context: CGContext) {
        let string = text as NSString
        var range = NSRange(location: 0, length: string.length)
        let options: NSString.CompareOptions = [.caseInsensitive, .diacriticInsensitive]
        context.saveGState()
        context.setFillColor(Palette.searchMatchBackground.cgColor)
        while range.length > 0 {
            let found = string.range(of: needle, options: options, range: range)
            guard found.location != NSNotFound else { break }
            let start = CTLineGetOffsetForStringIndex(line, found.location, nil)
            let end = CTLineGetOffsetForStringIndex(line, found.location + found.length, nil)
            if end > start {
                let plate = CGRect(x: origin + start - 1, y: rect.midY - 10, width: end - start + 2, height: 20)
                context.addPath(CGPath(roundedRect: plate, cornerWidth: 3, cornerHeight: 3, transform: nil))
                context.fillPath()
            }
            range = NSRange(location: found.location + found.length, length: string.length - found.location - found.length)
        }
        context.restoreGState()
    }
}
