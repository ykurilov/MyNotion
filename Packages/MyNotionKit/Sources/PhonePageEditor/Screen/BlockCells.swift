#if canImport(UIKit)
import NotesCore
import UIKit
import VisualStyle

/// Размеры страницы на iPhone. Шрифты и маркеры — те же, что на Mac (`Metrics`); поля и шаг вложенности
/// уже — под узкий экран, как у Notion для iPhone.
enum PhoneLayout {
    static let sideMargin: CGFloat = 20
    static let indentPerLevel: CGFloat = 24
    static let markerInset = Metrics.BlockMarker.textInset
    static let quoteInset = Metrics.Quote.textInset
    static let bottomSpace: CGFloat = 160

    /// Отступ над блоком: у абзаца — как на Mac, у заголовков — меньше, чем на широкой странице Mac.
    static func topSpacing(_ kind: TextBlockKind) -> CGFloat {
        switch kind {
        case .heading1: 22
        case .heading2: 18
        case .heading3: 14
        default: Metrics.block(.paragraph).topSpacing
        }
    }

    static func leading(indent: Int) -> CGFloat {
        sideMargin + CGFloat(indent) * indentPerLevel
    }
}

// MARK: Текст

/// Блок с текстом: абзац, заголовок, пункт, чекбокс, цитата, переключатель.
final class TextBlockCell: UICollectionViewCell {
    let textView = BlockTextView()
    let marker = BlockMarkerView()
    var onMarkerTap: (() -> Void)?

    private let quoteBar = UIView()
    private let placeholder = UILabel()
    private let colorBackground = UIView()
    private var markerLeading: NSLayoutConstraint!
    private var markerHeight: NSLayoutConstraint!
    private var textLeading: NSLayoutConstraint!
    private var textTop: NSLayoutConstraint!
    /// Что сейчас показано: текст перерисовывается, только если поменялось одно из этого.
    /// `atomLabels` — подписи упоминаний и дат: подстраницу переименовали — подпись другая при том же тексте.
    private var shown: (blockId: UUID, text: InlineText, look: TextLook, style: UIUserInterfaceStyle, atomLabels: [String])?

    override init(frame: CGRect) {
        super.init(frame: frame)
        colorBackground.layer.cornerRadius = 4
        quoteBar.backgroundColor = PhonePalette.textPrimary
        placeholder.textColor = PhonePalette.handleIcon
        placeholder.isUserInteractionEnabled = false
        marker.addAction(UIAction { [weak self] _ in self?.onMarkerTap?() }, for: .primaryActionTriggered)
        for view in [colorBackground, quoteBar, placeholder, textView, marker] {
            view.translatesAutoresizingMaskIntoConstraints = false
            contentView.addSubview(view)
        }
        markerLeading = marker.leadingAnchor.constraint(equalTo: contentView.leadingAnchor)
        markerHeight = marker.heightAnchor.constraint(equalToConstant: 24)
        textLeading = textView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor)
        textTop = textView.topAnchor.constraint(equalTo: contentView.topAnchor)
        let textBottom = textView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor)
        textBottom.priority = .init(999)
        NSLayoutConstraint.activate([
            markerLeading, markerHeight, textLeading, textTop, textBottom,
            textView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -PhoneLayout.sideMargin),
            marker.topAnchor.constraint(equalTo: textView.topAnchor),
            marker.widthAnchor.constraint(equalToConstant: Metrics.BlockMarker.columnWidth),
            quoteBar.leadingAnchor.constraint(equalTo: marker.leadingAnchor),
            quoteBar.topAnchor.constraint(equalTo: textView.topAnchor),
            quoteBar.bottomAnchor.constraint(equalTo: textView.bottomAnchor),
            quoteBar.widthAnchor.constraint(equalToConstant: Metrics.Quote.barWidth),
            placeholder.leadingAnchor.constraint(equalTo: textView.leadingAnchor),
            placeholder.trailingAnchor.constraint(lessThanOrEqualTo: textView.trailingAnchor),
            placeholder.topAnchor.constraint(equalTo: textView.topAnchor),
            colorBackground.leadingAnchor.constraint(equalTo: marker.leadingAnchor, constant: -4),
            colorBackground.trailingAnchor.constraint(equalTo: textView.trailingAnchor, constant: 4),
            colorBackground.topAnchor.constraint(equalTo: textView.topAnchor, constant: -2),
            colorBackground.bottomAnchor.constraint(equalTo: textView.bottomAnchor, constant: 2),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) не используется") }

    override func prepareForReuse() {
        super.prepareForReuse()
        // Ячейку отдают другому блоку: набор не должен уйти в чужой текст.
        if textView.isFirstResponder { textView.resignFirstResponder() }
        onMarkerTap = nil
    }

    func show(_ row: PageRow, kind: TextBlockKind, rendering: InlineTextRendering) {
        let block = row.block
        let look = rendering.look
        textView.blockId = block.id
        markerLeading.constant = PhoneLayout.leading(indent: row.indent)
        textTop.constant = PhoneLayout.topSpacing(kind)
        markerHeight.constant = look.lineHeight
        marker.lineHeight = look.lineHeight
        switch kind {
        case .bulletItem: marker.mark = .bullet(indent: row.indent)
        case .numberedItem: marker.mark = .number(ListMarkers.number(row.number ?? 1, atIndent: row.indent))
        case .checkbox: marker.mark = .checkbox(checked: block.isChecked)
        case .toggle: marker.mark = .toggle(expanded: !row.isCollapsed)
        default: marker.mark = .none
        }
        quoteBar.isHidden = kind != .quote
        let inset: CGFloat = switch kind {
        case .bulletItem, .numberedItem, .checkbox, .toggle: PhoneLayout.markerInset
        case .quote: PhoneLayout.quoteInset
        default: 0
        }
        textLeading.constant = PhoneLayout.leading(indent: row.indent) + inset
        let background = PhonePalette.notionBackground(block.color.background.flatMap { NotionTone(rawValue: $0.rawValue) })
        colorBackground.backgroundColor = background
        colorBackground.isHidden = background == nil

        let text = block.text
        let style = rendering.traits.userInterfaceStyle
        let atomLabels = text.runs.filter(\.style.isAtom).map { rendering.atomLabel($0.style) }
        let isSame = shown.map {
            $0.blockId == block.id && $0.text == text && $0.look == look && $0.style == style && $0.atomLabels == atomLabels
        } ?? false
        if !isSame, textView.markedTextRange == nil {
            let current = InlineTextRendering.inlineText(from: textView.attributedText)
            let keepsCaret = textView.isFirstResponder && shown?.blockId == block.id
            if !keepsCaret || current != text || shown?.look != look || shown?.style != style || shown?.atomLabels != atomLabels {
                let selection = keepsCaret ? SelectionMapping.map(textView.selectedRange, from: current.string, to: text.string) : nil
                textView.attributedText = rendering.attributedString(text)
                if let selection {
                    textView.selectedRange = selection
                    // Текст поменялся не набором: старые шаги «Отменить» к нему уже не подходят.
                    if current.string != text.string { textView.undoManager?.removeAllActions() }
                }
            }
            shown = (block.id, text, look, style, atomLabels)
        }
        textView.typingAttributes = rendering.typingAttributes(in: text, at: textView.isFirstResponder ? textView.selectedRange.location : 0)
        placeholder.font = look.font
        placeholder.text = Self.emptyHint(kind)
        updatePlaceholder()
    }

    func updatePlaceholder() {
        placeholder.isHidden = textView.attributedText.length > 0 || placeholder.text == nil
    }

    /// Подсказка пустого блока — как на Mac; у абзаца её нет.
    static func emptyHint(_ kind: TextBlockKind) -> String? {
        switch kind {
        case .paragraph: nil
        case .heading1: "Заголовок 1"
        case .heading2: "Заголовок 2"
        case .heading3: "Заголовок 3"
        case .bulletItem, .numberedItem: "Список"
        case .checkbox: "Задача"
        case .quote: "Пустая цитата"
        case .toggle: "Раскрывающийся список"
        }
    }
}

// MARK: Разделитель

final class DividerCell: UICollectionViewCell {
    private let line = UIView()
    private var lineLeading: NSLayoutConstraint!

    override init(frame: CGRect) {
        super.init(frame: frame)
        line.backgroundColor = PhonePalette.dividerLine
        line.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(line)
        lineLeading = line.leadingAnchor.constraint(equalTo: contentView.leadingAnchor)
        let rowHeight = Metrics.Divider.rowHeight + 2 * Metrics.Divider.verticalSpacing
        let top = line.topAnchor.constraint(equalTo: contentView.topAnchor, constant: (rowHeight - Metrics.Divider.lineWidth) / 2)
        let bottom = line.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -(rowHeight - Metrics.Divider.lineWidth) / 2)
        bottom.priority = .init(999)
        NSLayoutConstraint.activate([
            lineLeading, top, bottom,
            line.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -PhoneLayout.sideMargin),
            line.heightAnchor.constraint(equalToConstant: Metrics.Divider.lineWidth),
        ])
        isAccessibilityElement = true
        accessibilityLabel = "Разделитель"
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) не используется") }

    func show(_ row: PageRow) {
        lineLeading.constant = PhoneLayout.leading(indent: row.indent)
    }
}

// MARK: Подстраница

/// Ссылка на подстраницу: значок и подчёркнутое название; касание открывает страницу.
final class PageLinkCell: UICollectionViewCell {
    private let icon = UILabel()
    private let title = UILabel()
    private var iconLeading: NSLayoutConstraint!

    override init(frame: CGRect) {
        super.init(frame: frame)
        icon.textAlignment = .center
        title.numberOfLines = 2
        for view in [icon, title] {
            view.translatesAutoresizingMaskIntoConstraints = false
            contentView.addSubview(view)
        }
        iconLeading = icon.leadingAnchor.constraint(equalTo: contentView.leadingAnchor)
        let bottom = title.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -3)
        bottom.priority = .init(999)
        NSLayoutConstraint.activate([
            iconLeading,
            icon.widthAnchor.constraint(equalToConstant: Metrics.BlockMarker.columnWidth),
            icon.centerYAnchor.constraint(equalTo: title.firstBaselineAnchor, constant: -5),
            title.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: Metrics.BlockMarker.textSpacing),
            title.trailingAnchor.constraint(lessThanOrEqualTo: contentView.trailingAnchor, constant: -PhoneLayout.sideMargin),
            title.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 6),
            bottom,
            title.heightAnchor.constraint(greaterThanOrEqualToConstant: 24),
        ])
        isAccessibilityElement = true
        accessibilityTraits = .link
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) не используется") }

    override var isHighlighted: Bool {
        didSet { contentView.alpha = isHighlighted ? 0.5 : 1 }
    }

    func show(_ row: PageRow, linkedPage: Page?) {
        iconLeading.constant = PhoneLayout.leading(indent: row.indent)
        if let emoji = linkedPage?.icon {
            icon.attributedText = nil
            icon.text = emoji
            icon.font = .systemFont(ofSize: 18)
        } else {
            let symbol = NSTextAttachment(image: UIImage(systemName: "doc.text")!.withTintColor(PhonePalette.textSecondary,
                                                                                                 renderingMode: .alwaysOriginal))
            icon.attributedText = NSAttributedString(attachment: symbol)
        }
        let name = linkedPage?.displayTitle ?? InlineText.deletedPageTitle
        title.attributedText = NSAttributedString(string: name, attributes: [
            .font: UIFont.systemFont(ofSize: 16, weight: .medium),
            .foregroundColor: PhonePalette.textPrimary,
            .underlineStyle: NSUnderlineStyle.single.rawValue,
            .underlineColor: PhonePalette.linkUnderline,
        ])
        accessibilityLabel = "Страница \(name)"
    }
}

// MARK: Блок, которого iPhone пока не показывает

/// Аккуратная карточка: тип блока и его текст. Только показ — данные блока не трогаются.
final class UnsupportedBlockCell: UICollectionViewCell {
    private let card = UIView()
    private let title = UILabel()
    private let detail = UILabel()
    private var cardLeading: NSLayoutConstraint!

    override init(frame: CGRect) {
        super.init(frame: frame)
        card.layer.cornerRadius = 6
        card.layer.borderWidth = 1
        card.backgroundColor = PhonePalette.inlineCodeBackground
        title.font = .systemFont(ofSize: 12, weight: .semibold)
        title.textColor = PhonePalette.textSecondary
        detail.font = .systemFont(ofSize: 15)
        detail.textColor = PhonePalette.textPrimary
        detail.numberOfLines = 4
        let stack = UIStackView(arrangedSubviews: [title, detail])
        stack.axis = .vertical
        stack.spacing = 2
        for view in [card, stack] { view.translatesAutoresizingMaskIntoConstraints = false }
        contentView.addSubview(card)
        card.addSubview(stack)
        cardLeading = card.leadingAnchor.constraint(equalTo: contentView.leadingAnchor)
        let bottom = card.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -4)
        bottom.priority = .init(999)
        NSLayoutConstraint.activate([
            cardLeading, bottom,
            card.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -PhoneLayout.sideMargin),
            card.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 6),
            stack.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 12),
            stack.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -12),
            stack.topAnchor.constraint(equalTo: card.topAnchor, constant: 8),
            stack.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -8),
        ])
        isAccessibilityElement = true
        registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (cell: UnsupportedBlockCell, _: UITraitCollection) in
            cell.card.layer.borderColor = PhonePalette.border.resolvedColor(with: cell.traitCollection).cgColor
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) не используется") }

    func show(_ row: PageRow) {
        cardLeading.constant = PhoneLayout.leading(indent: row.indent)
        card.layer.borderColor = PhonePalette.border.resolvedColor(with: traitCollection).cgColor
        let summary = UnsupportedBlockSummary(row.block)
        title.text = summary.title.uppercased()
        detail.text = summary.detail
        detail.isHidden = summary.detail == nil
        accessibilityLabel = [summary.title, summary.detail].compactMap { $0 }.joined(separator: ": ")
    }
}

// MARK: Шапка и хвост

/// Иконка-эмодзи и название страницы; название правится.
final class PageHeaderCell: UICollectionViewCell {
    let titleView = BlockTextView()
    private let icon = UILabel()
    private let placeholder = UILabel()
    private var titleTop: NSLayoutConstraint!

    override init(frame: CGRect) {
        super.init(frame: frame)
        icon.font = .systemFont(ofSize: 56)
        placeholder.text = Page.untitledTitle
        placeholder.font = TextLook.pageTitle.font
        placeholder.textColor = PhonePalette.handleIcon
        titleView.accessibilityLabel = "Название страницы"
        for view in [icon, placeholder, titleView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            contentView.addSubview(view)
        }
        titleTop = titleView.topAnchor.constraint(equalTo: contentView.topAnchor)
        let bottom = titleView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -12)
        bottom.priority = .init(999)
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: PhoneLayout.sideMargin),
            icon.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 16),
            titleView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: PhoneLayout.sideMargin),
            titleView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -PhoneLayout.sideMargin),
            titleTop, bottom,
            placeholder.leadingAnchor.constraint(equalTo: titleView.leadingAnchor),
            placeholder.topAnchor.constraint(equalTo: titleView.topAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) не используется") }

    func show(_ page: Page, rendering: InlineTextRendering) {
        icon.text = page.icon
        icon.isHidden = page.icon == nil
        titleTop.constant = page.icon == nil ? 24 : 92
        let current = titleView.text ?? ""
        if current != page.title, titleView.markedTextRange == nil {
            let selection = titleView.isFirstResponder ? SelectionMapping.map(titleView.selectedRange, from: current, to: page.title) : nil
            titleView.attributedText = rendering.attributedString(InlineText(page.title))
            if let selection {
                titleView.selectedRange = selection
                titleView.undoManager?.removeAllActions()
            }
        }
        titleView.typingAttributes = rendering.attributes(for: [])
        updatePlaceholder()
    }

    func updatePlaceholder() {
        placeholder.isHidden = !(titleView.text ?? "").isEmpty
    }
}

/// Пустое место под последним блоком: касание ставит курсор в новый абзац в конце.
final class PageTailCell: UICollectionViewCell {
    override init(frame: CGRect) {
        super.init(frame: frame)
        let height = contentView.heightAnchor.constraint(equalToConstant: PhoneLayout.bottomSpace)
        height.priority = .init(999)
        height.isActive = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) не используется") }
}
#endif
