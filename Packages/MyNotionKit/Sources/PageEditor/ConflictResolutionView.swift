import AppKit
import NotesCore
import SwiftUI
import VisualStyle

/// Как Юрий решил «Две версии» (FR-021).
public enum ConflictChoice: Sendable, Hashable {
    /// Оставить то, что сейчас в блоке.
    case current
    /// Оставить вторую версию.
    case other
    /// Оставить обе: вторая — новым блоком под этим.
    case both
}

extension Conflict {
    /// Версия, которой сейчас нет в блоке: та, что показать «второй».
    func otherVersion(comparedTo current: InlineText) -> InlineText {
        remoteVersion.normalized() != current.normalized() ? remoteVersion : localVersion
    }
}

/// Оранжевая метка «Две версии» справа от блока в конфликте (contracts/editor-interactions.md); щелчок — сравнение.
final class ConflictLabelView: NSView {
    static let title = "Две версии"
    private static let font = NSFont.systemFont(ofSize: 12, weight: .medium)
    private static let horizontalPadding: CGFloat = 6
    static let height: CGFloat = 20

    let conflictId: UUID
    var onClick: (() -> Void)?

    init(conflictId: UUID) {
        self.conflictId = conflictId
        super.init(frame: .zero)
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel(Self.title)
        setAccessibilityIdentifier("conflict-label")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) не используется") }

    override var intrinsicContentSize: NSSize {
        let width = (Self.title as NSString).size(withAttributes: [.font: Self.font]).width
        return NSSize(width: ceil(width) + Self.horizontalPadding * 2, height: Self.height)
    }

    override func draw(_ dirtyRect: NSRect) {
        Palette.conflictLabelBackground.setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 4, yRadius: 4).fill()
        let attributes: [NSAttributedString.Key: Any] = [.font: Self.font, .foregroundColor: Palette.conflictLabelText]
        let size = (Self.title as NSString).size(withAttributes: attributes)
        (Self.title as NSString).draw(at: NSPoint(x: Self.horizontalPadding, y: (bounds.height - size.height) / 2),
                                      withAttributes: attributes)
    }

    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) { onClick?() }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }

    override func accessibilityPerformPress() -> Bool {
        onClick?()
        return true
    }
}

/// Метки «Двух версий» над текстом страницы: по одной на блок с ожидающим конфликтом.
@MainActor
final class ConflictMarksOverlay {
    private unowned let textView: PageTextView
    private var labels: [UUID: ConflictLabelView] = [:]
    /// Окно сравнения версий.
    let comparison = PopupCard()

    init(textView: PageTextView) {
        self.textView = textView
    }

    /// Ожидающие конфликты по блокам: первый на блок (следующий покажется, когда этот решат).
    var conflictsByBlock: [UUID: Conflict] {
        var result: [UUID: Conflict] = [:]
        for conflict in textView.document.pendingConflicts where result[conflict.blockId] == nil {
            result[conflict.blockId] = conflict
        }
        return result
    }

    func update() {
        let conflicts = conflictsByBlock
        for (blockId, label) in labels where conflicts[blockId]?.id != label.conflictId {
            label.removeFromSuperview()
            labels[blockId] = nil
        }
        for (blockId, conflict) in conflicts {
            guard let index = textView.document.index(ofBlock: blockId) else { continue }
            ensureLayout(ofBlockAt: index)
            guard let rect = textView.blockSelectionRects(index..<index + 1).first else {
                labels[blockId]?.isHidden = true
                continue
            }
            let label = labels[blockId] ?? {
                let label = ConflictLabelView(conflictId: conflict.id)
                label.onClick = { [weak textView] in textView?.showConflictComparison(forBlock: blockId) }
                textView.addSubview(label)
                labels[blockId] = label
                return label
            }()
            let size = label.intrinsicContentSize
            label.isHidden = false
            label.frame = NSRect(x: rect.maxX + 6, y: rect.minY + 2, width: size.width, height: size.height)
        }
    }

    func label(forBlock blockId: UUID) -> ConflictLabelView? { labels[blockId] }

    /// Место метки — по строке блока; пока TextKit её не разложил, разложить только этот абзац.
    private func ensureLayout(ofBlockAt index: Int) {
        guard let layoutManager = textView.textLayoutManager, let storage = textView.textContentStorage,
              let start = storage.location(storage.documentRange.location, offsetBy: textView.mapper.paragraphStart(ofBlockAt: index)),
              let end = storage.location(start, offsetBy: 1),
              let range = NSTextRange(location: start, end: end) else { return }
        layoutManager.ensureLayout(for: range)
    }
}

extension PageTextView {
    /// Окно сравнения «Двух версий» у метки блока.
    func showConflictComparison(forBlock blockId: UUID) {
        guard let conflict = conflictMarks.conflictsByBlock[blockId], let index = document.index(ofBlock: blockId),
              let label = conflictMarks.label(forBlock: blockId) else { return }
        let current = document.blocks[index].text
        let view = ConflictResolutionView(
            current: current.string, other: conflict.otherVersion(comparedTo: current).string,
            otherDeviceName: conflict.remoteDeviceName
        ) { [weak self] choice in
            self?.conflictMarks.comparison.close()
            self?.resolveConflict(conflict, choice: choice)
        }
        let hosting = NSHostingView(rootView: view)
        conflictMarks.comparison.show(hosting, size: hosting.fittingSize, besides: label, preferringRight: false)
    }

    /// Выбор версии — обычная правка текста блока, её можно отменить ⌘Z; затем конфликт снимается.
    /// Основа правки — текст из базы, поэтому запись ляжет поверх него, а не станет новым конфликтом.
    public func resolveConflict(_ conflict: Conflict, choice: ConflictChoice) {
        guard let index = document.index(ofBlock: conflict.blockId) else { return }
        commitEdits()
        document.adoptStoredTextVersion(ofBlock: conflict.blockId)
        let block = document.blocks[index]
        let other = conflict.otherVersion(comparedTo: block.text)
        var otherDraft = BlockDraft(block)
        otherDraft.text = other
        switch choice {
        case .current:
            break
        case .other:
            changeBlocks(index..<index + 1, to: [otherDraft], actionName: "Выбор версии")
        case .both:
            otherDraft.id = nil
            changeBlocks(index..<index + 1, to: [BlockDraft(block), otherDraft], actionName: "Обе версии")
        }
        onResolveConflict?(conflict)
        conflictMarks.update()
    }
}

/// Сравнение «Двух версий»: обе рядом, выбор одной или обеих двумя блоками (FR-021).
struct ConflictResolutionView: View {
    let current: String
    let other: String
    let otherDeviceName: String
    let choose: (ConflictChoice) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Две версии")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Color(nsColor: Palette.textPrimary))
            Text("Этот блок правили на двух Mac. Обе версии сохранены — выберите, что оставить.")
                .font(.system(size: 13))
                .foregroundStyle(Color(nsColor: Palette.textSecondary))
                .fixedSize(horizontal: false, vertical: true)
            HStack(alignment: .top, spacing: 12) {
                version(title: "Сейчас в блоке", text: current, identifier: "conflict-keep-current") { choose(.current) }
                version(title: otherTitle, text: other, identifier: "conflict-keep-other") { choose(.other) }
            }
            Button("Оставить обе — двумя блоками") { choose(.both) }
                .accessibilityIdentifier("conflict-keep-both")
        }
        .padding(16)
        .frame(width: 520, alignment: .leading)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("conflict-comparison")
    }

    private var otherTitle: String {
        let name = otherDeviceName.trimmingCharacters(in: .whitespaces)
        return name.isEmpty || UUID(uuidString: name) != nil ? "Вторая версия" : "Вторая версия · с \(name)"
    }

    private func version(title: String, text: String, identifier: String, action: @escaping () -> Void) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Color(nsColor: Palette.textSecondary))
            ScrollView {
                Text(text.isEmpty ? "Пусто" : text)
                    .font(.system(size: 14))
                    .foregroundStyle(Color(nsColor: text.isEmpty ? Palette.textSecondary : Palette.textPrimary))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
            .frame(minHeight: 60, maxHeight: 180)
            .padding(8)
            .background(RoundedRectangle(cornerRadius: 6).stroke(Color(nsColor: Palette.border)))
            Button("Оставить эту", action: action)
                .accessibilityIdentifier(identifier)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
