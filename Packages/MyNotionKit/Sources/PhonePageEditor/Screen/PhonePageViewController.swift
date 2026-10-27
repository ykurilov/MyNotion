#if canImport(UIKit)
import NotesCore
import UIKit
import VisualStyle

/// Экран страницы на iPhone: иконка, название и блоки страницы из общего `PageDocument`; текст блоков этапа 1 правится.
///
/// Как встроить: `try PhonePageViewController(pageId:openDocuments:onOpenPage:)`. Экран сам открывает документ
/// в `openDocuments` и отпускает его, когда уходит из памяти; записывает автосохранение `OpenDocuments`.
/// Правки с другого устройства: оболочка после синхронизации зовёт `openDocuments.applyExternalChanges(toPages:)`,
/// экран сам показывает принятое, не сбивая курсор в блоке, который сейчас правится.
/// Уход приложения в фон — запись сразу; `saveNow()` — записать по просьбе оболочки.
/// Касание подстраницы — `onOpenPage(id)`.
@MainActor
public final class PhonePageViewController: UIViewController {
    public let pageId: UUID
    private let openDocuments: OpenDocuments
    private let onOpenPage: (UUID) -> Void
    private let document: PageDocument
    private let session: PageEditingSession

    private var rows: [PageRow] = []
    private var rowIndexById: [UUID: Int] = [:]
    private var collectionView: UICollectionView!
    private var dataSource: UICollectionViewDiffableDataSource<Int, PageItem>!
    private var textCell: UICollectionView.CellRegistration<TextBlockCell, UUID>!
    private var dividerCell: UICollectionView.CellRegistration<DividerCell, UUID>!
    private var pageLinkCell: UICollectionView.CellRegistration<PageLinkCell, UUID>!
    private var unsupportedCell: UICollectionView.CellRegistration<UnsupportedBlockCell, UUID>!
    private var headerCell: UICollectionView.CellRegistration<PageHeaderCell, PageItem>!
    private var tailCell: UICollectionView.CellRegistration<PageTailCell, PageItem>!
    /// Поле, в котором сейчас курсор.
    private weak var editingTextView: BlockTextView?
    /// Пока список перестраивается, прокрутка к курсору ждёт.
    private var isApplyingRows = false
    private var visibleHeight: CGFloat = 0

    public init(pageId: UUID, openDocuments: OpenDocuments, onOpenPage: @escaping (UUID) -> Void) throws {
        self.pageId = pageId
        self.openDocuments = openDocuments
        self.onOpenPage = onOpenPage
        let document = try openDocuments.open(pageId)
        self.document = document
        session = PageEditingSession(document: document, viewState: BlockViewStateStore(database: openDocuments.store.database))
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) не используется") }

    isolated deinit {
        openDocuments.release(pageId)
    }

    /// Записать несохранённое сейчас. `false` — записать не удалось (автосохранение повторит).
    @discardableResult
    public func saveNow() -> Bool {
        openDocuments.saveAll()
    }

    // MARK: Экран

    override public func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = PhonePalette.pageBackground
        navigationItem.largeTitleDisplayMode = .never

        let size = NSCollectionLayoutSize(widthDimension: .fractionalWidth(1), heightDimension: .estimated(30))
        let group = NSCollectionLayoutGroup.vertical(layoutSize: size, subitems: [NSCollectionLayoutItem(layoutSize: size)])
        collectionView = UICollectionView(frame: .zero, collectionViewLayout: UICollectionViewCompositionalLayout(section: NSCollectionLayoutSection(group: group)))
        collectionView.backgroundColor = .clear
        // Ячейка растёт вместе с полем, пока в нём набирают.
        collectionView.selfSizingInvalidation = .enabledIncludingConstraints
        collectionView.keyboardDismissMode = .interactive
        collectionView.alwaysBounceVertical = true
        collectionView.delegate = self
        collectionView.accessibilityIdentifier = "phone-page"
        collectionView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(collectionView)
        // Низ списка — над клавиатурой: строка с курсором клавиатурой не закрывается.
        view.keyboardLayoutGuide.usesBottomSafeArea = false
        NSLayoutConstraint.activate([
            collectionView.topAnchor.constraint(equalTo: view.topAnchor),
            collectionView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            collectionView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            collectionView.bottomAnchor.constraint(equalTo: view.keyboardLayoutGuide.topAnchor),
        ])
        registerCells()
        refresh()

        let center = NotificationCenter.default
        center.addObserver(self, selector: #selector(documentChanged(_:)), name: PageDocument.didApplyExternalChanges, object: document)
        center.addObserver(self, selector: #selector(documentChanged(_:)), name: PageDocument.didApplyLocalEdits, object: document)
        center.addObserver(self, selector: #selector(appDidEnterBackground), name: UIApplication.didEnterBackgroundNotification, object: nil)
        registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (screen: PhonePageViewController, _: UITraitCollection) in
            screen.redrawAll()
        }
    }

    override public func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        let height = collectionView.bounds.height
        guard height != visibleHeight else { return }
        visibleHeight = height
        // Клавиатура выехала или уехала: строка с курсором остаётся на виду.
        if let editingTextView { DispatchQueue.main.async { [weak self] in self?.revealCaret(in: editingTextView) } }
    }

    private func registerCells() {
        textCell = .init { [weak self] cell, _, id in self?.configure(cell, blockId: id) }
        dividerCell = .init { [weak self] cell, _, id in
            if let row = self?.row(id) { cell.show(row) }
        }
        pageLinkCell = .init { [weak self] cell, _, id in
            guard let self, let row = row(id) else { return }
            cell.show(row, linkedPage: row.block.linkedPageId.flatMap { self.livePage($0) })
        }
        unsupportedCell = .init { [weak self] cell, _, id in
            if let row = self?.row(id) { cell.show(row) }
        }
        headerCell = .init { [weak self] cell, _, _ in self?.configure(cell) }
        tailCell = .init { _, _, _ in }
        dataSource = UICollectionViewDiffableDataSource(collectionView: collectionView) { [weak self] collectionView, indexPath, item in
            guard let self else { return nil }
            switch item {
            case .header:
                return collectionView.dequeueConfiguredReusableCell(using: headerCell, for: indexPath, item: item)
            case .tail:
                return collectionView.dequeueConfiguredReusableCell(using: tailCell, for: indexPath, item: item)
            case .block(let id):
                switch row(id)?.look {
                case .divider: return collectionView.dequeueConfiguredReusableCell(using: dividerCell, for: indexPath, item: id)
                case .pageLink: return collectionView.dequeueConfiguredReusableCell(using: pageLinkCell, for: indexPath, item: id)
                case .unsupported, nil: return collectionView.dequeueConfiguredReusableCell(using: unsupportedCell, for: indexPath, item: id)
                case .text: return collectionView.dequeueConfiguredReusableCell(using: textCell, for: indexPath, item: id)
                }
            }
        }
    }

    // MARK: Строки

    private enum Focus {
        case block(CaretTarget)
        case titleEnd
    }

    /// Строка блока с его текущим содержимым: текст набора уже в документе, а `rows` — с прошлой перестройки.
    private func row(_ id: UUID) -> PageRow? {
        guard let index = rowIndexById[id] else { return nil }
        var row = rows[index]
        if let live = document.block(id) { row.block = live }
        return row
    }

    /// Перестроить строки по документу: новые и ушедшие блоки — вставкой и удалением, поменявшиеся — на месте.
    private func refresh(focus: Focus? = nil, reconfigureHeader: Bool = false) {
        let old = rowIndexById.mapValues { rows[$0] }
        rows = session.rows()
        rowIndexById = Dictionary(uniqueKeysWithValues: rows.enumerated().map { ($1.block.id, $0) })

        var snapshot = NSDiffableDataSourceSnapshot<Int, PageItem>()
        snapshot.appendSections([0])
        snapshot.appendItems([.header] + rows.map { .block($0.block.id) } + [.tail])
        var reconfigured: [PageItem] = reconfigureHeader ? [.header] : []
        var reloaded: [PageItem] = []
        for row in rows {
            guard let before = old[row.block.id], before != row else { continue }
            // Другой вид ячейки (абзац стал картинкой на другом устройстве) — ячейка заменяется.
            if CellKind(before.look) == CellKind(row.look) { reconfigured.append(.block(row.block.id)) } else { reloaded.append(.block(row.block.id)) }
        }
        snapshot.reconfigureItems(reconfigured)
        snapshot.reloadItems(reloaded)

        // Курсор переходит в поле, которое уже на экране, до перестройки: клавиатура не прячется на миг.
        if let focus, let cell = visibleTextView(for: focus), !cell.isFirstResponder { cell.becomeFirstResponder() }
        isApplyingRows = true
        dataSource.apply(snapshot, animatingDifferences: false)
        isApplyingRows = false
        if let focus { move(focus) }
    }

    private func redrawAll() {
        var snapshot = dataSource.snapshot()
        snapshot.reconfigureItems(snapshot.itemIdentifiers)
        isApplyingRows = true
        dataSource.apply(snapshot, animatingDifferences: false)
        isApplyingRows = false
    }

    private func visibleTextView(for focus: Focus) -> BlockTextView? {
        switch focus {
        case .block(let target):
            dataSource.indexPath(for: .block(target.blockId)).flatMap { (collectionView.cellForItem(at: $0) as? TextBlockCell)?.textView }
        case .titleEnd:
            dataSource.indexPath(for: .header).flatMap { (collectionView.cellForItem(at: $0) as? PageHeaderCell)?.titleView }
        }
    }

    private func move(_ focus: Focus) {
        let item: PageItem
        let offset: Int
        switch focus {
        case .block(let target): (item, offset) = (.block(target.blockId), target.offset)
        case .titleEnd: (item, offset) = (.header, .max)
        }
        guard let indexPath = dataSource.indexPath(for: item) else { return }
        collectionView.layoutIfNeeded()
        if collectionView.cellForItem(at: indexPath) == nil {
            collectionView.scrollToItem(at: indexPath, at: .centeredVertically, animated: false)
            collectionView.layoutIfNeeded()
        }
        guard let textView = visibleTextView(for: focus) else { return }
        if !textView.isFirstResponder { textView.becomeFirstResponder() }
        textView.selectedRange = NSRange(location: min(offset, textView.attributedText.length), length: 0)
        revealCaret(in: textView)
    }

    private func revealCaret(in textView: BlockTextView) {
        guard !isApplyingRows, textView.isFirstResponder, let range = textView.selectedTextRange else { return }
        collectionView.layoutIfNeeded()
        let caret = textView.caretRect(for: range.end)
        guard caret.minY.isFinite, caret.height.isFinite else { return }
        collectionView.scrollRectToVisible(collectionView.convert(caret, from: textView).insetBy(dx: 0, dy: -24), animated: false)
    }

    // MARK: Ячейки

    private func configure(_ cell: TextBlockCell, blockId: UUID) {
        guard let row = row(blockId), case .text(let kind) = row.look else { return }
        cell.textView.delegate = self
        cell.textView.onBackspaceAtStart = { [weak self, weak textView = cell.textView] in
            if let self, let textView { backspaceAtStart(in: textView) }
        }
        cell.textView.onReturn = { [weak self, weak textView = cell.textView] in
            if let self, let textView, let blockId = textView.blockId { pressReturn(in: textView, blockId: blockId) }
        }
        cell.onMarkerTap = { [weak self] in self?.markerTapped(blockId) }
        cell.show(row, kind: kind, rendering: rendering(for: row, kind: kind, traits: cell.traitCollection))
    }

    private func configure(_ cell: PageHeaderCell) {
        cell.titleView.delegate = self
        cell.titleView.blockId = nil
        cell.titleView.onBackspaceAtStart = nil
        cell.titleView.onReturn = { [weak self] in self?.returnFromTitle() }
        cell.show(document.page, rendering: InlineTextRendering(look: .pageTitle, traits: cell.traitCollection, pageTitle: livePageTitle))
    }

    private func rendering(for row: PageRow, kind: TextBlockKind, traits: UITraitCollection) -> InlineTextRendering {
        var look = TextLook.of(kind)
        look.color = row.block.color.text.flatMap { NotionTone(rawValue: $0.rawValue) }
        look.isStruckThrough = kind == .checkbox && row.block.isChecked
        return InlineTextRendering(look: look, traits: traits, pageTitle: livePageTitle)
    }

    private func livePage(_ id: UUID) -> Page? {
        guard let page = try? openDocuments.store.page(id), page.trashedAt == nil else { return nil }
        return page
    }

    private var livePageTitle: (UUID) -> String? {
        { [weak self] id in self?.livePage(id)?.displayTitle }
    }

    // MARK: Правка

    private func pressReturn(in textView: BlockTextView, blockId: UUID) {
        session.setText(InlineTextRendering.inlineText(from: textView.attributedText), ofBlock: blockId)
        guard let target = session.pressReturn(inBlock: blockId, selection: textView.selectedRange) else { return }
        textView.undoManager?.removeAllActions()
        refresh(focus: .block(target))
    }

    private func backspaceAtStart(in textView: BlockTextView) {
        guard let blockId = textView.blockId else { return }
        session.setText(InlineTextRendering.inlineText(from: textView.attributedText), ofBlock: blockId)
        let focus: Focus
        switch session.pressBackspaceAtStart(ofBlock: blockId) {
        case .unchanged: return
        case .caret(let target): focus = .block(target)
        case .title: focus = .titleEnd
        }
        textView.undoManager?.removeAllActions()
        refresh(focus: focus)
    }

    private func returnFromTitle() {
        refresh(focus: .block(session.returnFromTitle()))
    }

    private func markerTapped(_ id: UUID) {
        guard let row = row(id) else { return }
        switch row.block.kind {
        case .checkbox: session.toggleChecked(id)
        case .toggle: session.setCollapsed(!row.isCollapsed, toggle: id)
        default: return
        }
        refresh()
    }

    // MARK: Внешние правки и запись

    @objc private func documentChanged(_ note: Notification) {
        // Свои правки этот экран уже показал.
        if note.name == PageDocument.didApplyLocalEdits,
           note.userInfo?[PageDocument.editOriginKey] as? ObjectIdentifier == ObjectIdentifier(session) { return }
        let change = note.userInfo?[PageDocument.externalChangeKey] as? PageDocument.ExternalChange
        refresh(reconfigureHeader: change.map { $0.titleChanged || $0.iconChanged } ?? true)
    }

    @objc private func appDidEnterBackground() {
        saveNow()
    }
}

// MARK: - Поля текста

extension PhonePageViewController: UITextViewDelegate {
    public func textView(_ textView: UITextView, shouldChangeTextIn range: NSRange, replacementText text: String) -> Bool {
        guard let textView = textView as? BlockTextView, textView.markedTextRange == nil else { return true }
        if text == "\n" {
            if let blockId = textView.blockId { pressReturn(in: textView, blockId: blockId) } else { returnFromTitle() }
            return false
        }
        guard text.unicodeScalars.contains(where: { $0 == "\n" || $0 == "\r" }) else { return true }
        // Вставка нескольких строк: внутри блока — мягкий перенос (U+2028), в названии — пробел.
        let separator = textView.blockId == nil ? " " : "\u{2028}"
        let joined = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
            .replacingOccurrences(of: "\n", with: separator)
        if let start = textView.position(from: textView.beginningOfDocument, offset: range.location),
           let end = textView.position(from: start, offset: range.length),
           let replaced = textView.textRange(from: start, to: end) {
            textView.replace(replaced, withText: joined)
        }
        return false
    }

    public func textViewDidChange(_ textView: UITextView) {
        guard let textView = textView as? BlockTextView else { return }
        if let blockId = textView.blockId {
            (textView.enclosingCell as? TextBlockCell)?.updatePlaceholder()
            guard textView.markedTextRange == nil else { return }
            session.setText(InlineTextRendering.inlineText(from: textView.attributedText), ofBlock: blockId)
        } else {
            (textView.enclosingCell as? PageHeaderCell)?.updatePlaceholder()
            guard textView.markedTextRange == nil else { return }
            session.setTitle(textView.text)
        }
        revealCaret(in: textView)
    }

    public func textViewDidChangeSelection(_ textView: UITextView) {
        guard let textView = textView as? BlockTextView, textView.markedTextRange == nil else { return }
        if let blockId = textView.blockId, let row = row(blockId), case .text(let kind) = row.look {
            // Набор продолжает оформление знака перед курсором, но не ссылку и не упоминание.
            let text = InlineTextRendering.inlineText(from: textView.attributedText)
            textView.typingAttributes = rendering(for: row, kind: kind, traits: textView.traitCollection)
                .typingAttributes(in: text, at: textView.selectedRange.location)
        }
        revealCaret(in: textView)
    }

    public func textViewDidBeginEditing(_ textView: UITextView) {
        editingTextView = textView as? BlockTextView
    }

    public func textViewDidEndEditing(_ textView: UITextView) {
        if editingTextView === textView { editingTextView = nil }
    }
}

// MARK: - Касания строк

extension PhonePageViewController: UICollectionViewDelegate {
    public func collectionView(_ collectionView: UICollectionView, shouldHighlightItemAt indexPath: IndexPath) -> Bool {
        switch dataSource.itemIdentifier(for: indexPath) {
        case .tail: true
        case .block(let id): row(id)?.look == .pageLink
        default: false
        }
    }

    public func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        collectionView.deselectItem(at: indexPath, animated: false)
        switch dataSource.itemIdentifier(for: indexPath) {
        case .tail:
            refresh(focus: .block(session.tapBelowLastBlock()))
        case .block(let id):
            if let row = row(id), row.look == .pageLink, let linked = row.block.linkedPageId { onOpenPage(linked) }
        default:
            break
        }
    }
}

/// Строка списка: шапка, блок страницы, пустое место внизу.
enum PageItem: Hashable, Sendable {
    case header
    case block(UUID)
    case tail
}

/// Вид ячейки блока: при его смене ячейка не перенастраивается, а заменяется.
private enum CellKind: Equatable {
    case text, divider, pageLink, unsupported

    init(_ look: BlockLook) {
        switch look {
        case .text: self = .text
        case .divider: self = .divider
        case .pageLink: self = .pageLink
        case .unsupported: self = .unsupported
        }
    }
}

extension UIView {
    /// Ячейка списка, в которой лежит вид.
    fileprivate var enclosingCell: UICollectionViewCell? {
        var view = superview
        while let current = view {
            if let cell = current as? UICollectionViewCell { return cell }
            view = current.superview
        }
        return nil
    }
}
#endif
