import AppKit
import NotesCore
import VisualStyle

/// Свёрнутые переключатели и заголовки страницы на этом Mac (research R1; contracts/blocks-and-keys.md, «Раскрывающийся
/// список»). Текст страницы не меняется: дети свёрнутых переключателей и разделы свёрнутых заголовков (`HeadingSections`)
/// прячутся от раскладки (`HiddenParagraphs`). Свёрнутость пишется сразу в `block_view_state` и не входит ни в отмену,
/// ни в синхронизацию.
@MainActor
final class CollapsedParagraphs {
    weak var textView: PageTextView?
    /// Где хранится свёрнутость; без него она живёт, пока открыта страница.
    var store: BlockViewStateStore?
    private(set) var collapsedIds: Set<UUID> = []

    func load(pageId: UUID) {
        collapsedIds = (try? store?.collapsedBlockIds(ofPage: pageId)) ?? []
    }

    func set(_ collapsed: Bool, _ id: UUID) {
        guard collapsedIds.contains(id) != collapsed else { return }
        if collapsed { collapsedIds.insert(id) } else { collapsedIds.remove(id) }
        try? store?.setCollapsed(collapsed, blockId: id)
    }

    /// Блоки, которые прячутся: поддеревья свёрнутых переключателей и разделы свёрнутых заголовков.
    func hiddenBlockIds(in blocks: [Block]) -> Set<UUID> {
        guard !collapsedIds.isEmpty else { return [] }
        var hidden: Set<UUID> = []
        var index = 0
        // Поля блоков читаются по месту, без копии блока: страница бывает на 10 000 блоков, а проход — на каждое нажатие.
        while index < blocks.count {
            guard Self.folds(blocks[index].kind), collapsedIds.contains(blocks[index].id),
                  let end = Self.foldedEnd(blocks, ofBlockAt: index) else {
                index += 1
                continue
            }
            for child in (index + 1)..<end { hidden.insert(blocks[child].id) }
            index = max(end, index + 1)
        }
        return hidden
    }

    /// Сворачивается ли блок такого типа: переключатель и заголовок.
    static func folds(_ kind: BlockKind) -> Bool { kind == .toggle || kind.isHeading }

    /// Конец того, что прячет свёрнутый блок `index`: детей переключателя, раздела заголовка; не сворачивается — `nil`.
    static func foldedEnd(_ blocks: [Block], ofBlockAt index: Int) -> Int? {
        switch blocks[index].kind {
        case .toggle: BlockMoveController.subtreeEnd(blocks, of: index)
        case .heading1, .heading2, .heading3: HeadingSections.sectionEnd(blocks, ofHeadingAt: index)
        default: nil
        }
    }

    // MARK: Вид абзацев по поддереву

    /// Поправки вида абзаца, которые зависят от соседей, а не только от самого блока (их не знает мэппер).
    struct Adjustment: Equatable {
        /// Добавочный отступ под абзацем: поля выноски снизу у её последнего видимого блока (у вложенных выносок —
        /// по полю на каждую), строка подсказки под раскрытым пустым переключателем, зазор над детьми раскрытого.
        var spacingAfter: CGFloat = 0
        /// Сдвиг абзаца вбок: дети цитаты и выноски — вровень с текстом родителя, как у Notion; слишком глубокий блок
        /// (после слияния правок двух Mac) — на допустимую глубину (`BlockNesting`).
        var shift: CGFloat = 0
    }

    /// Поправки, поставленные в текст.
    private(set) var adjustments: [UUID: Adjustment] = [:]
    /// Цитаты, выноски и блоки внутри них: только у них что-то рисуют общие рисователи по поддереву.
    private(set) var subtreePainted: Set<UUID> = []

    /// Поправки всех блоков страницы; блоки без поправок в словарь не входят.
    func adjustments(in blocks: [Block], isHidden: (UUID) -> Bool) -> [UUID: Adjustment] {
        var result: [UUID: Adjustment] = [:]
        subtreePainted = []
        // Страница без вложенности и без выносок и переключателей — без поправок; проход по месту, без копий блоков.
        guard blocks.indices.contains(where: { blocks[$0].indent > 0 || blocks[$0].kind == .callout || blocks[$0].kind == .toggle
            || blocks[$0].kind == .quote }) else { return result }

        let displayIndents = BlockNesting.displayIndents(blocks)
        let step = Metrics.Page.indentPerLevel
        // Предки текущего блока: глубина при показе, тип, сдвиг, лежит ли в цитате или выноске.
        var ancestors: [(indent: Int, kind: BlockKind, shift: CGFloat, painted: Bool)] = []
        for index in blocks.indices {
            let indent = displayIndents[index]
            while let last = ancestors.last, last.indent >= indent { ancestors.removeLast() }
            let parent = ancestors.last.flatMap { $0.indent == indent - 1 ? $0 : nil }
            var shift = CGFloat(indent - blocks[index].indent) * step
            if let parent { shift += parent.shift + Self.childShift(under: parent.kind) }
            let kind = blocks[index].kind
            let painted = kind == .quote || kind == .callout || (parent?.painted ?? false)
            if painted { subtreePainted.insert(blocks[index].id) }
            if shift != 0 { result[blocks[index].id, default: Adjustment()].shift = shift }
            ancestors.append((indent, kind, shift, painted))
        }

        for index in blocks.indices where blocks[index].kind == .callout || blocks[index].kind == .toggle {
            let block = blocks[index]
            guard !isHidden(block.id) else { continue }
            let end = BlockMoveController.subtreeEnd(blocks, of: index)
            if block.kind == .toggle {
                if !collapsedIds.contains(block.id) {
                    // Пустой раскрытый — строка подсказки; с детьми — первый ребёнок ниже на 4, как у Notion 7.39.
                    result[block.id, default: Adjustment()].spacingAfter += end == index + 1 ? Metrics.block(.paragraph).height
                        : Metrics.Toggle.childrenTopSpacing
                }
                continue
            }
            var last = end - 1
            while last > index, isHidden(blocks[last].id) { last -= 1 }
            result[blocks[last].id, default: Adjustment()].spacingAfter += Metrics.Callout.verticalPadding
        }
        return result
    }

    /// Насколько ребёнок сдвинут от шага вложенности: у цитаты и выноски он начинается там же, где текст родителя.
    static func childShift(under kind: BlockKind) -> CGFloat {
        switch kind {
        case .quote: Metrics.Quote.textInset - Metrics.Page.indentPerLevel
        case .callout: Metrics.Callout.textInset - Metrics.Page.indentPerLevel
        default: 0
        }
    }

    /// Поставить поправки в текст: у абзацев, где они появились, пропали или стёрлись перерисовкой блока (`only` —
    /// проверить только эти блоки).
    func apply(_ wanted: [UUID: Adjustment], in textView: PageTextView, only: Set<UUID>? = nil) {
        let touched = only ?? Set(wanted.keys).union(adjustments.keys)
        adjustments = wanted
        guard let textStorage = textView.textStorage, !touched.isEmpty else { return }
        var changed = false
        // Одна правка хранилища на все абзацы: открытие страницы с вложенными блоками — без правки на каждый.
        textStorage.beginEditing()
        defer { textStorage.endEditing() }
        // По порядку блоков: начало абзаца ищется от прошлого, а не с начала текста (T085, переключение вкладок).
        let indices = touched.compactMap { textView.document.index(ofBlock: $0) }.sorted()
        for index in indices {
            let block = textView.document.blocks[index]
            let id = block.id
            let range = textView.mapper.characterRange(ofBlocksAt: index..<index + 1)
            guard range.length > 0 else { continue }
            let adjustment = wanted[id] ?? Adjustment()
            let base = PageTextStorageMapper.baseAttributes(for: block)[.paragraphStyle] as? NSParagraphStyle
            let spacing = (base?.paragraphSpacing ?? 0) * textView.mapper.fontScale + adjustment.spacingAfter
            let head = (base?.headIndent ?? 0) + adjustment.shift
            let current = textStorage.attribute(.paragraphStyle, at: range.location, effectiveRange: nil) as? NSParagraphStyle
            guard current?.paragraphSpacing != spacing || current?.headIndent != head || current?.firstLineHeadIndent != head else { continue }
            changed = true
            textStorage.enumerateAttribute(.paragraphStyle, in: range) { value, run, _ in
                guard let style = (value as? NSParagraphStyle)?.mutableCopy() as? NSMutableParagraphStyle else { return }
                style.paragraphSpacing = spacing
                style.headIndent = head
                style.firstLineHeadIndent = head
                textStorage.addAttribute(.paragraphStyle, value: style, range: run)
            }
        }
        if changed { textView.needsDisplay = true }
    }
}

extension PageTextView {
    // MARK: Свёрнутость

    /// Где хранится свёрнутость на этом Mac; при установке — свёрнутые переключатели страницы прячут детей.
    public var blockViewState: BlockViewStateStore? {
        get { collapsedParagraphs.store }
        set {
            collapsedParagraphs.store = newValue
            // Без переключателей и заголовков на странице свёрнутости нет — база не читается (путь открытия страницы).
            guard document.blocks.contains(where: { CollapsedParagraphs.folds($0.kind) }) else { return }
            collapsedParagraphs.load(pageId: document.pageId)
            if !collapsedBlockIds.isEmpty { refreshBlockStructure() }
        }
    }

    /// Свёрнутые переключатели и заголовки на этом Mac.
    public var collapsedBlockIds: Set<UUID> { collapsedParagraphs.collapsedIds }

    /// Свернуть или раскрыть переключатель или заголовок. Не шаг отмены и не правка документа: пишется сразу в вид блока.
    public func setCollapsed(_ collapsed: Bool, ofBlock id: UUID) {
        guard let index = document.index(ofBlock: id), CollapsedParagraphs.folds(document.blocks[index].kind) || !collapsed else { return }
        commitEdits()
        collapsedParagraphs.set(collapsed, id)
        refreshBlockStructure()
        redrawBlocks([id])
        // Курсор, оставшийся внутри спрятанного, уходит к концу строки переключателя или заголовка.
        let selection = selectedRange()
        if collapsed, selection.length == 0, let position = mapper.blockPosition(at: selection.location),
           hiddenParagraphs.isHidden(document.blocks[position.index].id) {
            setSelectedRange(NSRange(location: mapper.paragraphStart(ofBlockAt: index) + document.blocks[index].pageTextLength, length: 0))
        } else {
            updateSelectionLook()
        }
    }

    /// Свёрнутость страницы сменили мимо редактора (команда `mynotion`): перечитать её и перерисовать изменённое.
    @objc func blockViewStateDidChangeOutsideEditor(_ notification: Notification) {
        guard collapsedParagraphs.store != nil,
              notification.userInfo?[BlockViewStateStore.pageIdKey] as? UUID == document.pageId else { return }
        let before = collapsedBlockIds
        collapsedParagraphs.load(pageId: document.pageId)
        let changed = before.symmetricDifference(collapsedBlockIds)
        guard !changed.isEmpty else { return }
        refreshBlockStructure()
        redrawBlocks(Array(changed))
        // Курсор, оставшийся внутри спрятанного, уходит из него, как при ⌘⌥T.
        if !collapsedBlockIds.isSubset(of: before) { setSelectedRange(selectedRange()) }
    }

    func toggleCollapsed(ofBlock id: UUID) {
        setCollapsed(!collapsedBlockIds.contains(id), ofBlock: id)
    }

    /// ⌘Enter на переключателях и заголовках под курсором или выделением: если хоть один раскрыт — свернуть все, иначе раскрыть.
    func toggleCollapsedSelectedBlocks() {
        guard let selected = selectedBlockRange() else { return }
        let toggles = selected.map { document.blocks[$0].id }.filter { document.block($0).map { CollapsedParagraphs.folds($0.kind) } ?? false }
        guard !toggles.isEmpty else { return }
        let collapse = toggles.contains { !collapsedBlockIds.contains($0) }
        for id in toggles { setCollapsed(collapse, ofBlock: id) }
    }

    /// ⌘⌥T: все переключатели страницы — свернуть, если хоть один раскрыт, иначе раскрыть.
    func toggleAllCollapsed() {
        let toggles = document.blocks.filter { $0.kind == .toggle }.map(\.id)
        guard !toggles.isEmpty else { return }
        let collapse = toggles.contains { !collapsedBlockIds.contains($0) }
        commitEdits()
        for id in toggles { collapsedParagraphs.set(collapse, id) }
        refreshBlockStructure()
        redrawBlocks(toggles)
        if collapse { setSelectedRange(selectedRange()) }
    }

    /// Раскрыть все свёрнутые блоки, которые прячут блок `index`: предков-переключателей и заголовки, в чьём разделе он лежит
    /// (выделение внутри спрятанного, переход к блоку).
    func expandAncestors(ofBlockAt index: Int) {
        let blocks = document.blocks
        let collapsed = collapsedBlockIds.filter { id in
            guard let owner = document.index(ofBlock: id), owner < index,
                  let end = CollapsedParagraphs.foldedEnd(blocks, ofBlockAt: owner) else { return false }
            return index < end
        }
        guard !collapsed.isEmpty else { return }
        for id in collapsed { collapsedParagraphs.set(false, id) }
        refreshBlockStructure()
        redrawBlocks(Array(collapsed))
    }

    /// Перейти к блоку (поиск страниц, оглавление): свёрнутые предки раскрываются, курсор — в начало блока.
    public func revealBlock(_ id: UUID) {
        guard let index = document.index(ofBlock: id) else { return revealNestedBlock(id) }
        commitEdits()
        expandAncestors(ofBlockAt: index)
        window?.makeFirstResponder(self)
        let location = mapper.paragraphStart(ofBlockAt: index)
        setSelectedRange(NSRange(location: location, length: 0))
        scrollRangeToVisible(NSRange(location: location, length: 0))
    }

    /// Блоки поменялись (правка, отмена, правка с другого Mac): спрятать ровно детей свёрнутых и поставить отступы
    /// по поддеревьям.
    func refreshBlockStructure() {
        let blocks = document.blocks
        hiddenParagraphs.setHiddenBlocks(collapsedParagraphs.hiddenBlockIds(in: blocks))
        let hidden = hiddenParagraphs
        collapsedParagraphs.apply(collapsedParagraphs.adjustments(in: blocks, isHidden: hidden.isHidden), in: self)
        blockHandles.updateFoldHandle()
    }

    /// Набор в блоке без смены блоков: мэппер переписал вид абзаца под курсором и соседей — вернуть им поправки.
    func reapplyAdjustments(aroundBlockAt index: Int) {
        let adjustments = collapsedParagraphs.adjustments
        guard !adjustments.isEmpty else { return }
        let blocks = document.blocks
        let nearby = Set(blocks[max(0, index - 1)..<min(blocks.count, index + 2)].map(\.id))
        collapsedParagraphs.apply(adjustments, in: self, only: nearby)
    }

    /// Сдвиг блока вбок от его глубины (дети цитаты и выноски, урезанная глубина).
    func layoutShift(ofBlock id: UUID) -> CGFloat {
        collapsedParagraphs.adjustments[id]?.shift ?? 0
    }

    /// Цитата, выноска или блок внутри них: только у них рисуют черта цитаты и подложка выноски.
    func isInsideSubtreePainting(_ id: UUID) -> Bool {
        collapsedParagraphs.subtreePainted.contains(id)
    }

    /// Левый край блока в координатах контейнера: глубина и сдвиг.
    func blockLeft(ofBlockAt index: Int) -> CGFloat {
        let block = document.blocks[index]
        return Self.blockLeft(atIndent: block.indent) + layoutShift(ofBlock: block.id)
    }

    /// Раскрытый переключатель без детей показывает под строкой подсказку.
    func showsEmptyToggleHint(_ block: Block) -> Bool {
        guard block.kind == .toggle, !collapsedBlockIds.contains(block.id), let index = document.index(ofBlock: block.id) else { return false }
        return BlockMoveController.subtreeEnd(document.blocks, of: index) == index + 1
    }

    // MARK: Курсор и выделение у спрятанного

    /// Спрятанный отрезок текста вокруг места: дети свёрнутого переключателя, раздел свёрнутого заголовка.
    /// `toggleEnd` — конец текста владельца: переключателя или заголовка.
    func hiddenRegion(at location: Int) -> (range: NSRange, toggleEnd: Int)? {
        guard !hiddenParagraphs.hiddenBlockIds.isEmpty, !mapper.hasPendingEdits,
              let position = mapper.blockPosition(at: location), hiddenParagraphs.isHidden(document.blocks[position.index].id),
              let owner = hiddenRunOwner(ofBlockAt: position.index) else { return nil }
        // Спрятанное идёт одним куском под владельцем — до первого видимого блока.
        let blocks = document.blocks
        var end = position.index
        while end < blocks.count, hiddenParagraphs.isHidden(blocks[end].id) { end += 1 }
        let start = mapper.paragraphStart(ofBlockAt: owner + 1)
        return (NSRange(location: start, length: mapper.paragraphStart(ofBlockAt: end) - start), start - 1)
    }

    /// Владелец спрятанного блока `index` — ближайший видимый блок выше: свёрнутый переключатель или заголовок.
    func hiddenRunOwner(ofBlockAt index: Int) -> Int? {
        var owner = index - 1
        while owner >= 0, hiddenParagraphs.isHidden(document.blocks[owner].id) { owner -= 1 }
        return owner >= 0 ? owner : nil
    }

    /// Выделение с учётом спрятанного (research R1): курсор внутри уходит к концу строки переключателя, а шагом вправо
    /// с конца этой строки — за спрятанное; край выделения, захватившего свёрнутый переключатель, тянется за его детей;
    /// выделение целиком внутри спрятанного (⌘F) раскрывает всех предков.
    func selectionRespectingCollapsed(_ range: NSRange, from previous: NSRange) -> NSRange {
        guard !hiddenParagraphs.hiddenBlockIds.isEmpty else { return range }
        let length = textStorage?.length ?? 0
        if range.length == 0 {
            guard let region = hiddenRegion(at: range.location) else { return range }
            let regionEnd = NSMaxRange(region.range)
            if previous.length == 0, previous.location == region.toggleEnd, range.location == region.range.location, regionEnd < length {
                return NSRange(location: regionEnd, length: 0)
            }
            return NSRange(location: region.toggleEnd, length: 0)
        }
        let startRegion = hiddenRegion(at: range.location)
        let endRegion = NSMaxRange(range) > range.location ? hiddenRegion(at: NSMaxRange(range) - 1) : nil
        if let startRegion, let endRegion, startRegion.range == endRegion.range {
            if let position = mapper.blockPosition(at: range.location) { expandAncestors(ofBlockAt: position.index) }
            if let position = mapper.blockPosition(at: NSMaxRange(range) - 1) { expandAncestors(ofBlockAt: position.index) }
            return range
        }
        var start = range.location
        var end = NSMaxRange(range)
        if let startRegion { start = startRegion.range.location }
        if let endRegion { end = NSMaxRange(endRegion.range) }
        return NSRange(location: start, length: end - start)
    }

    // MARK: ⌫ и Enter у переключателя

    /// ⌫ в начале абзаца сразу под свёрнутым переключателем или заголовком склеивает его с текстом владельца, а не
    /// со спрятанным блоком; владелец остаётся свёрнутым.
    func handleBackspaceUnderCollapsedToggle() -> Bool {
        let selection = selectedRange()
        guard selection.length == 0, !hiddenParagraphs.hiddenBlockIds.isEmpty,
              let position = mapper.blockPosition(at: selection.location), position.offset == 0, position.index > 0,
              document.blocks[position.index].kind == .paragraph,
              hiddenParagraphs.isHidden(document.blocks[position.index - 1].id),
              let toggle = hiddenRunOwner(ofBlockAt: position.index - 1)
        else { return false }
        let blocks = document.blocks
        let joined = blocks[position.index]
        var drafts = blocks[toggle..<position.index].map(BlockDraft.init)
        let toggleLength = (blocks[toggle].text.string as NSString).length
        let shift = toggleLength
        drafts[0].text = InlineText(blocks[toggle].text.string + joined.text.string,
                                    runs: blocks[toggle].text.runs + joined.text.runs.map {
                                        StyledRun(start: $0.start + shift, length: $0.length, style: $0.style)
                                    }).normalized()
        changeBlocks(toggle..<position.index + 1, to: drafts, actionName: "Склеить блоки")
        if let index = document.index(ofBlock: blocks[toggle].id) {
            setSelectedRange(NSRange(location: mapper.paragraphStart(ofBlockAt: index) + toggleLength, length: 0))
        }
        return true
    }

    /// ⌫ в начале переключателя, цитаты, выноски: блок — абзац, его дети поднимаются на уровень (у абзаца детей нет).
    func handleBackspaceAtContainerStart() -> Bool {
        let selection = selectedRange()
        guard selection.length == 0, let position = mapper.blockPosition(at: selection.location), position.offset == 0,
              document.blocks[position.index].kind.allowsHeadingChildren else { return false }
        let blocks = document.blocks
        let index = position.index
        let end = BlockMoveController.subtreeEnd(blocks, of: index)
        var parent = BlockDraft(blocks[index])
        parent.kind = .paragraph
        parent.color = blocks[index].color == .defaults(for: blocks[index].kind) ? BlockColor.none : blocks[index].color
        let children = blocks[(index + 1)..<end].map { child -> BlockDraft in
            var draft = BlockDraft(child)
            draft.indent = max(0, child.indent - 1)
            return draft
        }
        collapsedParagraphs.set(false, blocks[index].id)
        changeBlocks(index..<end, to: [parent] + children, actionName: "Тип блока")
        return true
    }

    /// Enter в конце текста переключателя или выноски. Раскрытый переключатель, выноска — новый блок первым ребёнком;
    /// свёрнутый — новый переключатель после всех детей. Пустой переключатель без детей — как пустой пункт: абзац.
    func handleNewlineInContainer() -> Bool {
        let selection = selectedRange()
        guard selection.length == 0, let position = mapper.blockPosition(at: selection.location) else { return false }
        let blocks = document.blocks
        let index = position.index
        let block = blocks[index]
        guard block.kind == .toggle || block.kind == .callout, position.offset == block.pageTextLength else { return false }
        let end = BlockMoveController.subtreeEnd(blocks, of: index)
        if block.kind == .toggle, block.text.string.isEmpty, end == index + 1 { return false }
        let inserted: BlockDraft
        let gap: Int
        if block.kind == .toggle, collapsedBlockIds.contains(block.id) {
            inserted = BlockDraft(id: nil, kind: .toggle, indent: block.indent)
            gap = end
        } else {
            inserted = BlockDraft(id: nil, kind: .paragraph, indent: min(block.indent + 1, Block.indentRange.upperBound))
            gap = index + 1
        }
        changeBlocks(gap..<gap, to: [inserted], actionName: "Новый блок")
        setSelectedRange(NSRange(location: mapper.paragraphStart(ofBlockAt: gap), length: 0))
        return true
    }

    /// Enter в свёрнутом заголовке: в конце — новый абзац после скрытой части (заголовок разворачивается), в начале
    /// непустого — пустой абзац над заголовком; в середине заголовок раскрывается, и текст делится как обычно.
    func handleNewlineInCollapsedHeading() -> Bool {
        let selection = selectedRange()
        guard selection.length == 0, let position = mapper.blockPosition(at: selection.location) else { return false }
        let blocks = document.blocks
        let index = position.index
        let heading = blocks[index]
        guard heading.kind.isHeading, collapsedBlockIds.contains(heading.id) else { return false }
        if position.offset == heading.pageTextLength {
            // Абзац после раздела сам входит в раздел (до следующего заголовка того же уровня): заголовок разворачивается,
            // чтобы новый абзац был виден.
            let gap = HeadingSections.sectionEnd(blocks, ofHeadingAt: index)
            setCollapsed(false, ofBlock: heading.id)
            changeBlocks(gap..<gap, to: [BlockDraft(id: nil, kind: .paragraph, indent: heading.indent)], actionName: "Новый блок")
            setSelectedRange(NSRange(location: mapper.paragraphStart(ofBlockAt: gap), length: 0))
            return true
        }
        if position.offset == 0 {
            changeBlocks(index..<index, to: [BlockDraft(id: nil, kind: .paragraph, indent: heading.indent)], actionName: "Новый блок")
            setSelectedRange(NSRange(location: mapper.paragraphStart(ofBlockAt: index + 1), length: 0))
            return true
        }
        setCollapsed(false, ofBlock: heading.id)
        return false
    }

    /// Enter в пустом вложенном абзаце — выход на уровень выше, как ⇧Tab.
    func handleNewlineInEmptyChild() -> Bool {
        let selection = selectedRange()
        guard selection.length == 0, let position = mapper.blockPosition(at: selection.location) else { return false }
        let block = document.blocks[position.index]
        guard block.kind == .paragraph, block.indent > 0, block.text.string.isEmpty else { return false }
        indentSelectedBlocks(by: -1)
        return true
    }

    // MARK: Мышь

    /// Треугольник переключателя в координатах окна текста.
    public func toggleTriangleRect(ofBlock id: UUID) -> NSRect? {
        guard let index = document.index(ofBlock: id), document.blocks[index].kind == .toggle,
              let line = markerLine(ofBlockAt: index) else { return nil }
        let origin = textContainerOrigin
        return line.markerColumn.offsetBy(dx: origin.x, dy: origin.y)
    }

    /// Переключатель, чей треугольник под точкой (координаты окна текста).
    public func toggle(at point: NSPoint) -> UUID? {
        guard let (index, line) = markerLineNear(point), document.blocks[index].kind == .toggle else { return nil }
        let origin = textContainerOrigin
        return line.markerColumn.offsetBy(dx: origin.x, dy: origin.y).contains(point) ? document.blocks[index].id : nil
    }

    /// Подсказка пустого раскрытого переключателя под точкой: щелчок создаёт первого ребёнка.
    func emptyToggleHint(at point: NSPoint) -> Int? {
        let origin = textContainerOrigin
        let height = Metrics.block(.paragraph).height
        guard let index = blockIndex(atY: point.y - height) ?? blockIndex(atY: point.y), document.blocks[index].kind == .toggle,
              showsEmptyToggleHint(document.blocks[index]), let line = markerLine(ofBlockAt: index) else { return nil }
        let hintTop = origin.y + line.top + line.height
        return (hintTop...hintTop + height).contains(point.y) ? index : nil
    }

    func addFirstChild(toToggleAt index: Int) {
        let toggle = document.blocks[index]
        changeBlocks(index + 1..<index + 1, to: [BlockDraft(id: nil, kind: .paragraph, indent: toggle.indent + 1)], actionName: "Новый блок")
        window?.makeFirstResponder(self)
        setSelectedRange(NSRange(location: mapper.paragraphStart(ofBlockAt: index + 1), length: 0))
    }
}
