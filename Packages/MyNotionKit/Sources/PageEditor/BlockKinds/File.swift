import AppKit
import NotesCore
import UniformTypeIdentifiers
import VisualStyle

extension BlockKindDescriptor {
    /// Файл (US5): строка — значок типа, имя, размер; двойной щелчок открывает программой по умолчанию;
    /// «⋯» — «Показать в Finder», «Скачать копию…», «Переименовать».
    static let file = BlockKindDescriptor(
        kind: .file,
        menuItem: PopupMenuItem(title: "Файл", icon: .symbol("paperclip"), keywords: ["file", "вложение", "файл", "pdf"],
                                action: .setKind(.file)),
        gallerySamples: [
            BlockGallerySample(id: "media-file", summary: "Файлы: PDF, таблица; файл, который ещё качается",
                               blocks: [
                                   .init(.file, props: MediaSamples.file(name: "Договор аренды.pdf", byteCount: 2_400_000,
                                                                         contentType: "com.adobe.pdf")),
                                   .init(.file, props: MediaSamples.file(name: "Бюджет 2026.xlsx", byteCount: 48_300,
                                                                         contentType: "org.openxmlformats.spreadsheetml.sheet")),
                                   .init(.file, props: MediaSamples.file(name: MediaSamples.downloadingName, byteCount: 15_000_000,
                                                                         contentType: "public.png")),
                               ]),
        ],
        // Богатая страница (quickstart.md): 5 файлов.
        richPageBlocks: (1...5).map { number in
            RichBlockSpec(.file, props: MediaSamples.file(name: "Документ \(number).pdf", byteCount: number * 700_000,
                                                          contentType: "com.adobe.pdf"))
        }
    )
}

/// Строка файла: значок 20, имя 14, размер 12 серым; пока файла нет — вместо размера «Загружается…».
@MainActor
final class FileBlockView: MediaBlockView {
    private let availability: MediaAvailability
    private let iconView = NSImageView()
    private let nameLabel = NSTextField(labelWithString: "")
    private let sizeLabel = NSTextField(labelWithString: "")
    private var menuButton: MediaOverlayButton?

    var nameText: String { nameLabel.stringValue }
    var sizeText: String { sizeLabel.stringValue }
    var iconImage: NSImage? { iconView.image }

    override init(block: Block, width: CGFloat) {
        availability = MediaBlocks.availability(of: block.props.attachment)
        super.init(block: block, width: width)
        setAccessibilityIdentifier("file-block")
        let ref = block.props.attachment
        iconView.image = ref.flatMap { UTType($0.contentType) }.map { NSWorkspace.shared.icon(for: $0) }
            ?? NSWorkspace.shared.icon(for: .data)
        iconView.imageScaling = .scaleProportionallyUpOrDown
        nameLabel.stringValue = ref?.name ?? "Файл"
        nameLabel.font = .systemFont(ofSize: Metrics.Media.fileNameFontSize)
        nameLabel.textColor = Palette.textPrimary
        nameLabel.lineBreakMode = .byTruncatingMiddle
        let size = Self.sizeText(ref?.byteCount ?? 0)
        sizeLabel.stringValue = availability.fileURL == nil ? "\(size) — \(availability.statusText)" : size
        sizeLabel.font = .systemFont(ofSize: Metrics.Media.fileSizeFontSize)
        sizeLabel.textColor = Palette.textSecondary
        [iconView, nameLabel, sizeLabel].forEach(addSubview)
        frame.size.height = Metrics.Media.fileRowHeight + 2 * Metrics.Media.verticalPadding
    }

    /// «2,4 МБ», «48 КБ» — как Finder по-русски (тысячами, как `ByteCountFormatter.file`), на любом языке системы.
    static func sizeText(_ bytes: Int) -> String {
        let units = ["байт", "КБ", "МБ", "ГБ"]
        var value = Double(bytes)
        var unit = 0
        while value >= 1_000, unit < units.count - 1 {
            value /= 1_000
            unit += 1
        }
        let number = unit == 0 || value >= 10 ? String(Int(value.rounded())) : String(format: "%.1f", value).replacingOccurrences(of: ".", with: ",")
        return "\(number) \(units[unit])"
    }

    override func layout() {
        super.layout()
        let rowTop = Metrics.Media.verticalPadding
        let rowHeight = Metrics.Media.fileRowHeight
        let iconSize = Metrics.Media.fileIconSize
        var x = Metrics.Media.fileHorizontalPadding
        iconView.frame = NSRect(x: x, y: rowTop + (rowHeight - iconSize) / 2, width: iconSize, height: iconSize)
        x += iconSize + Metrics.Media.fileIconTextSpacing
        let nameWidth = min(ceil(nameLabel.attributedStringValue.size().width) + 6, max(0, bounds.width * 0.6))
        nameLabel.frame = NSRect(x: x, y: rowTop + (rowHeight - 20) / 2, width: nameWidth, height: 20)
        x += nameWidth + Metrics.Media.fileNameSizeSpacing
        sizeLabel.frame = NSRect(x: x, y: rowTop + (rowHeight - 16) / 2 + 1, width: max(0, bounds.width - x - 40), height: 16)
        menuButton?.frame.origin = NSPoint(x: bounds.width - Metrics.Media.menuButtonSize - 4, y: rowTop + (rowHeight - Metrics.Media.menuButtonSize) / 2)
    }

    override func draw(_ dirtyRect: NSRect) {
        guard isHovered else { return }
        Palette.hoverBackground.setFill()
        NSBezierPath(roundedRect: NSRect(x: 0, y: Metrics.Media.verticalPadding, width: bounds.width, height: Metrics.Media.fileRowHeight),
                     xRadius: Metrics.Media.cornerRadius, yRadius: Metrics.Media.cornerRadius).fill()
    }

    override func hoverDidChange() {
        needsDisplay = true
        if isHovered, menuButton == nil {
            let button = MediaOverlayButton(symbol: "ellipsis", size: Metrics.Media.menuButtonSize) { [weak self] in
                guard let self, let button = self.menuButton else { return }
                self.showMenu(from: button)
            }
            button.contentTintColor = Palette.textSecondary
            button.layer?.backgroundColor = nil
            addSubview(button)
            menuButton = button
            needsLayout = true
        } else if !isHovered {
            menuButton?.removeFromSuperview()
            menuButton = nil
        }
    }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2, let url = availability.fileURL {
            NSWorkspace.shared.open(url)
            return
        }
        super.mouseDown(with: event)
    }

    /// Файл пришёл или сменил состояние: вид заново на том же месте, высота строки та же.
    override func availabilityDidChange() {
        rebuild()
    }

    override func menuItems() -> [NSMenuItem] {
        var items: [NSMenuItem] = []
        if let url = availability.fileURL {
            items.append(menuItem("Открыть") { NSWorkspace.shared.open(url) })
            items.append(menuItem("Показать в Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) })
            items.append(menuItem("Скачать копию…") { [block] in
                MediaFileActions.saveCopy(of: url, suggestedName: block.props.attachment?.name)
            })
        }
        items.append(menuItem("Переименовать") { [weak self] in self?.rename() })
        return items
    }

    private func rename() {
        guard let window, let name = block.props.attachment?.name else { return }
        let alert = NSAlert()
        alert.messageText = "Переименовать файл"
        alert.addButton(withTitle: "Переименовать")
        alert.addButton(withTitle: "Отменить")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        field.stringValue = name
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn, let self else { return }
            let newName = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !newName.isEmpty, newName != name else { return }
            self.textView?.renameAttachment(newName, ofBlock: self.block.id)
        }
    }
}
