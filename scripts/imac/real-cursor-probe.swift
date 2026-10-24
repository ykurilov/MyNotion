// Живая проверка указателя настоящими событиями мыши (CGEvent .mouseMoved в .cghidEventTap), как от руки.
// Выполняется НА iMac из процесса с правом «Универсальный доступ» (см. real-cursor-check.zsh): иначе macOS
// молча выбрасывает события. Мышь ведётся плавно, шагом 8 мс, с остановками и дрожанием на месте;
// системный указатель (NSCursor.currentSystem) читается каждые 5 мс в этом же процессе.
//
//   real-cursor-probe <pid приложения> <журнал> [page|inactive|window|foreign]
//
// page     — страница: обложка, иконка, название, H1, абзац, ручки ⋮⋮ и +; итог PASS/FAIL по ожиданиям.
// inactive — то же, затем те же полосы, когда впереди другое приложение (окно MyNotion видно, но не активно).
// foreign  — эталон: чужое приложение (Chrome со страницей текста и ссылки), активное и позади другого.
// window   — обход всего окна по сетке: для каждого места — элемент под мышью (AX) и указатель; итог — список,
//            FAIL — если у нажимаемого (включённые кнопки, строки и названия в дереве) больше всего стрелки.
import AppKit
import ApplicationServices

setvbuf(stdout, nil, _IOLBF, 0)
let args = CommandLine.arguments
guard args.count >= 3, let pid = pid_t(args[1]) else { print("usage: real-cursor-probe <pid> <log> [page|inactive|window|foreign]"); exit(2) }
let logPath = args[2], mode = args.count > 3 ? args[3] : "page"
_ = NSApplication.shared

guard AXIsProcessTrusted() else { print("FAIL: процесс без права «Универсальный доступ» — события мыши не дойдут"); exit(3) }
guard let app = NSRunningApplication(processIdentifier: pid) else { print("FAIL: процесс \(pid) не запущен"); exit(3) }

// MARK: Эталоны указателей

func cursorKey(_ cursor: NSCursor?) -> String {
    guard let cursor, let tiff = cursor.image.tiffRepresentation else { return "nil" }
    var hash: UInt64 = 1469598103934665603
    for byte in tiff { hash = (hash ^ UInt64(byte)) &* 1099511628211 }
    return String(hash, radix: 16) + "@\(Int(cursor.hotSpot.x)),\(Int(cursor.hotSpot.y))"
}
let references: [String: String] = [
    cursorKey(.arrow): "ARROW", cursorKey(.iBeam): "IBEAM", cursorKey(.pointingHand): "HAND",
    cursorKey(.openHand): "OPENHAND", cursorKey(.closedHand): "CLOSEDHAND",
    cursorKey(.resizeLeftRight): "RESIZE_LR", cursorKey(.resizeUpDown): "RESIZE_UD",
]
func currentCursorName() -> String {
    let key = cursorKey(NSCursor.currentSystem)
    return references[key] ?? "OTHER:\(key)"
}

// MARK: Accessibility: где что лежит в окне (верхний левый угол экрана — 0,0, как у CGEvent)

let axApp = AXUIElementCreateApplication(app.processIdentifier)
func attribute<T>(_ element: AXUIElement, _ name: String) -> T? {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
    return value as? T
}
func frame(of element: AXUIElement) -> CGRect? {
    guard let position: AXValue = attribute(element, kAXPositionAttribute), let size: AXValue = attribute(element, kAXSizeAttribute)
    else { return nil }
    var point = CGPoint.zero, extent = CGSize.zero
    AXValueGetValue(position, .cgPoint, &point); AXValueGetValue(size, .cgSize, &extent)
    return CGRect(origin: point, size: extent)
}
func find(_ identifier: String, in root: AXUIElement = axApp, depth: Int = 0) -> [AXUIElement] {
    guard depth < 40 else { return [] }
    var found: [AXUIElement] = []
    if (attribute(root, kAXIdentifierAttribute) as String?) == identifier { found.append(root) }
    for child in (attribute(root, kAXChildrenAttribute) as [AXUIElement]?) ?? [] { found += find(identifier, in: child, depth: depth + 1) }
    return found
}
func visibleFrame(_ identifier: String) -> CGRect? {
    find(identifier).compactMap(frame).first { $0.width > 0 && $0.height > 0 }
}
/// Рамка строки текста `needle` внутри текстового вида `page-body`.
func textFrame(_ needle: String) -> CGRect? {
    guard let body = find("page-body").first, let value: String = attribute(body, kAXValueAttribute),
          let range = value.range(of: needle) else { return nil }
    var cfRange = CFRange(location: value.utf16.distance(from: value.utf16.startIndex, to: range.lowerBound.samePosition(in: value.utf16)!),
                          length: needle.utf16.count)
    guard let param = AXValueCreate(.cfRange, &cfRange) else { return nil }
    var bounds: CFTypeRef?
    guard AXUIElementCopyParameterizedAttributeValue(body, kAXBoundsForRangeParameterizedAttribute as CFString, param, &bounds) == .success,
          let axBounds = bounds else { return nil }
    var rect = CGRect.zero
    AXValueGetValue(axBounds as! AXValue, .cgRect, &rect)
    return rect
}
/// Что под точкой: роль/идентификатор ближайшего элемента с идентификатором.
func describeElement(at point: CGPoint) -> String {
    var element: AXUIElement?
    guard AXUIElementCopyElementAtPosition(axApp, Float(point.x), Float(point.y), &element) == .success, var current = element
    else { return "?" }
    let role: String = attribute(current, kAXRoleAttribute) ?? "?"
    let desc: String = attribute(current, kAXDescriptionAttribute) ?? attribute(current, kAXTitleAttribute) ?? ""
    for _ in 0..<6 {
        if let id: String = attribute(current, kAXIdentifierAttribute), !id.isEmpty {
            let disabled = (attribute(current, kAXEnabledAttribute) as Bool?) == false ? " [выкл]" : ""
            return "\(role)#\(id)" + (desc.isEmpty ? "" : " «\(desc)»") + disabled
        }
        guard let parent: AXUIElement = attribute(current, kAXParentAttribute) else { break }
        current = parent
    }
    return role + (desc.isEmpty ? "" : " «\(desc)»")
}

/// Верхнее окно под точкой, если это не главное окно приложения: «владелец «заголовок» слой рамка».
func foreignTopWindow(at point: CGPoint, mainFrame: CGRect) -> String? {
    let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
    for info in list {
        let layer = info[kCGWindowLayer as String] as? Int ?? 0
        guard layer < Int(CGWindowLevelForKey(.cursorWindow)),
              let bounds = (info[kCGWindowBounds as String] as? NSDictionary).flatMap({ CGRect(dictionaryRepresentation: $0) }),
              bounds.contains(point), (info[kCGWindowAlpha as String] as? Double ?? 1) > 0 else { continue }
        let owner = info[kCGWindowOwnerName as String] as? String ?? "?"
        let ownerPid = info[kCGWindowOwnerPID as String] as? pid_t ?? 0
        // Прозрачные системные слои на весь экран (Центр уведомлений) мышь не перехватывают.
        if ownerPid != pid, layer > 0, NSScreen.screens.contains(where: { $0.frame.size == bounds.size }) { continue }
        if ownerPid == pid, bounds.integral == mainFrame.integral { return nil }
        let title = info[kCGWindowName as String] as? String ?? ""
        return "\(owner) «\(title)» слой \(layer) \(Int(bounds.minX)),\(Int(bounds.minY)) \(Int(bounds.width))×\(Int(bounds.height))"
    }
    return nil
}

// MARK: Наблюдатель: указатель каждые 5 мс; ожидание задаёт текущий участок пути по месту мыши

/// Какие указатели допустимы в точке; nil — точка не судится (граница, переход).
typealias Expectation = @Sendable (CGPoint) -> Set<String>?
final class Recorder: @unchecked Sendable {
    struct Sample { var time: Double; var cursor: String; var point: CGPoint; var segment: String; var expected: Set<String>? }
    private let lock = NSLock()
    private var segment = "setup", expectation: Expectation = { _ in nil }
    private var samples: [Sample] = []
    let start = Date()
    var now: Double { Date().timeIntervalSince(start) }
    func enter(_ name: String, _ expect: @escaping Expectation) {
        lock.lock(); segment = name; expectation = expect; lock.unlock()
    }
    func record(cursor: String, point: CGPoint) {
        lock.lock()
        samples.append(Sample(time: now, cursor: cursor, point: point, segment: segment, expected: expectation(point)))
        lock.unlock()
    }
    func snapshot() -> [Sample] { lock.lock(); defer { lock.unlock() }; return samples }
}
let recorder = Recorder()
let screenTop = NSScreen.screens.first!.frame.maxY

// MARK: Движение настоящими событиями

var mouse: CGPoint = { let p = NSEvent.mouseLocation; return CGPoint(x: p.x, y: screenTop - p.y) }()
func post(_ point: CGPoint, type: CGEventType = .mouseMoved) {
    CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: point, mouseButton: .left)?.post(tap: .cghidEventTap)
    mouse = point
}
/// Плавно к точке: шаг 8 мс, с лёгким дрожанием по пути, как у руки.
func glide(to target: CGPoint, speed: Double = 300) {
    let distance = hypot(target.x - mouse.x, target.y - mouse.y)
    let steps = max(1, Int(distance / (speed * 0.008)))
    let from = mouse
    for step in 1...steps {
        let t = Double(step) / Double(steps)
        let eased = t * t * (3 - 2 * t)
        let wobble = step == steps ? 0 : Double.random(in: -0.6...0.6)
        post(CGPoint(x: from.x + (target.x - from.x) * eased + wobble, y: from.y + (target.y - from.y) * eased + wobble))
        usleep(8000)
    }
}
/// Остановка: рука не неподвижна — редкие сдвиги на 1 пт, как у настоящей мыши на столе.
func rest(_ seconds: Double, jitter: Bool = true) {
    let center = mouse, until = recorder.now + seconds
    while recorder.now < until {
        if jitter, Int.random(in: 0..<6) == 0 {
            post(CGPoint(x: center.x + Double(Int.random(in: -1...1)), y: center.y + Double(Int.random(in: -1...1))))
        }
        usleep(8000)
    }
    post(center)
}
func click() {
    post(mouse, type: .leftMouseDown); usleep(60_000); post(mouse, type: .leftMouseUp); usleep(200_000)
}
func segment(_ name: String, _ expect: @escaping Expectation, _ body: () -> Void) {
    recorder.enter(name, expect)
    body()
    recorder.enter("transit", { _ in nil })
}
func everywhere(_ cursors: Set<String>) -> Expectation { { _ in cursors } }
/// I-beam везде в `area`, рука в `controls`; у границ нажимаемого (3 пт) не судим.
func textExcept(_ controls: [CGRect], in area: CGRect = .infinite) -> Expectation {
    { point in
        guard area.contains(point) else { return nil }
        if controls.contains(where: { $0.insetBy(dx: 3, dy: 3).contains(point) }) { return ["HAND"] }
        if controls.contains(where: { $0.insetBy(dx: -3, dy: -3).contains(point) }) { return nil }
        return ["IBEAM"]
    }
}

// MARK: Сценарии

let log = FileHandle(forWritingAtPath: logPath) ?? {
    FileManager.default.createFile(atPath: logPath, contents: nil); return FileHandle(forWritingAtPath: logPath)!
}()
func write(_ line: String) { print(line); log.write((line + "\n").data(using: .utf8)!) }

func activate() {
    app.activate(options: [.activateAllWindows])
    for _ in 0..<50 where NSWorkspace.shared.frontmostApplication?.processIdentifier != app.processIdentifier { usleep(100_000) }
    write("front=\(NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "?") pid=\(app.processIdentifier)")
}

func runPage() -> Bool {
    let hand = everywhere(["HAND"])
    guard let window = (attribute(axApp, kAXWindowsAttribute) as [AXUIElement]?)?.first, let windowFrame = frame(of: window),
          let title = visibleFrame("page-title"), let cover = visibleFrame("page-cover"), let icon = visibleFrame("page-icon"),
          let h1 = textFrame("Заголовок первого уровня"), let paragraph = textFrame("Абзац под заголовком первого уровня.")
    else { write("FAIL: не нашёл окно, обложку, иконку, название или строки H1/абзаца (AX)"); return false }
    write("window=\(windowFrame) cover=\(cover) icon=\(icon) title=\(title) h1=\(h1) paragraph=\(paragraph)")
    let column = CGRect(x: title.minX, y: cover.maxY, width: title.width, height: paragraph.maxY + 40 - cover.maxY)
    var ok = true

    // Вход в окно сверху, как рукой; кнопки обложки видны при наведении на неё.
    glide(to: CGPoint(x: windowFrame.midX, y: windowFrame.minY + 4), speed: 600)
    glide(to: CGPoint(x: cover.midX, y: cover.midY)); rest(0.6)
    let coverButtons = ["change-page-cover", "reposition-page-cover"].compactMap(visibleFrame)
    if coverButtons.count != 2 { write("FAIL: кнопки обложки не появились"); ok = false }

    // Полосы под обложкой поперёк всей колонки: обложка, ряд иконки, над названием, название, зазор, H1, абзац.
    let levels: [(String, CGFloat)] = [
        ("cover-bottom", cover.maxY - 12), ("icon-row", icon.midY), ("above-title", (icon.maxY + title.minY) / 2),
        ("title-row", title.midY), ("title-gap", (title.maxY + h1.minY) / 2), ("h1-row", h1.midY), ("paragraph-row", paragraph.midY),
    ]
    for (index, (name, y)) in levels.enumerated() {
        let from = index % 2 == 0 ? column.minX + 4 : column.maxX - 4, to = index % 2 == 0 ? column.maxX - 4 : column.minX + 4
        glide(to: CGPoint(x: from, y: y), speed: 500)
        segment("sweep-\(name)", textExcept([icon] + coverButtons, in: column.union(cover))) {
            glide(to: CGPoint(x: (from + to) / 2, y: y), speed: 260); rest(0.8)
            glide(to: CGPoint(x: to, y: y), speed: 260); rest(0.5)
        }
    }
    glide(to: CGPoint(x: icon.midX, y: icon.midY))
    segment("icon", hand) { rest(1.2) }

    // Название, H1, абзац: проход с остановками и обратно.
    func sweep(_ name: String, _ rect: CGRect) {
        let y = rect.midY, left = rect.minX + 6, right = min(rect.maxX - 6, rect.minX + 420)
        glide(to: CGPoint(x: left, y: y))
        segment(name, everywhere(["IBEAM"])) {
            rest(0.8)
            for x in stride(from: left, through: right, by: (right - left) / 4) { glide(to: CGPoint(x: x, y: y + .random(in: -3...3)), speed: 220); rest(0.9) }
            glide(to: CGPoint(x: left, y: y), speed: 500)
            rest(1.5)
        }
    }
    sweep("title", title.insetBy(dx: 0, dy: title.height * 0.25))
    sweep("h1", h1.insetBy(dx: 0, dy: h1.height * 0.2))
    sweep("paragraph", paragraph.insetBy(dx: 0, dy: paragraph.height * 0.2))

    // Ручки появляются у строки под мышью: с текста влево на ⋮⋮ и +, назад на текст.
    for (line, name) in [(h1, "h1"), (paragraph, "paragraph")] {
        glide(to: CGPoint(x: line.minX + 40, y: line.midY)); rest(0.5)
        let drags = find("block-handle-drag").compactMap(frame).filter { $0.width > 0 && abs($0.midY - line.midY) < line.height }
        let adds = find("block-handle-add").compactMap(frame).filter { $0.width > 0 && abs($0.midY - line.midY) < line.height }
        guard let drag = drags.first, let add = adds.first else { write("FAIL: ручки у \(name) не появились"); ok = false; continue }
        glide(to: CGPoint(x: drag.midX, y: drag.midY), speed: 200)
        segment("\(name)-drag-handle", hand) { rest(1.5) }
        glide(to: CGPoint(x: add.midX, y: add.midY), speed: 200)
        segment("\(name)-add-handle", hand) { rest(1.5) }
        glide(to: CGPoint(x: drag.midX, y: drag.midY), speed: 200)
        segment("\(name)-drag-handle-back", hand) { rest(1.0) }
        glide(to: CGPoint(x: line.minX + 60, y: line.midY), speed: 250)
        segment("\(name)-after-handles", everywhere(["IBEAM"])) { rest(1.2) }
    }
    // Кнопки обложки.
    glide(to: CGPoint(x: cover.midX, y: cover.midY)); rest(0.6)
    for (id, button) in zip(["change-page-cover", "reposition-page-cover"], coverButtons) {
        glide(to: CGPoint(x: button.midX, y: button.midY), speed: 200)
        segment(id, hand) { rest(1.2) }
    }
    // Долгая стоянка над H1, как у Юрия: 5 с с дрожанием.
    glide(to: CGPoint(x: h1.minX + 80, y: h1.midY))
    segment("h1-long-rest", everywhere(["IBEAM"])) { rest(5) }

    // Курсор вставки в названии (щелчок настоящей мышью), затем снова название и H1.
    glide(to: CGPoint(x: title.minX + 40, y: title.midY)); click()
    sweep("title-focused", title.insetBy(dx: 0, dy: title.height * 0.25))
    sweep("h1-title-focused", h1.insetBy(dx: 0, dy: h1.height * 0.2))
    // Курсор вставки в тексте страницы.
    glide(to: CGPoint(x: paragraph.maxX - 4, y: paragraph.midY)); click()
    sweep("h1-text-focused", h1.insetBy(dx: 0, dy: h1.height * 0.2))
    glide(to: CGPoint(x: h1.minX + 80, y: h1.midY))
    segment("h1-long-rest-text-focused", everywhere(["IBEAM"])) { rest(3) }
    guard mode == "inactive" else { return ok }

    guard bringProbeToFront(checking: [CGPoint(x: h1.midX, y: h1.midY)], windowFrame: windowFrame) else { return false }
    for (index, (name, y)) in levels.dropFirst().enumerated() {
        let from = index % 2 == 0 ? column.minX + 4 : column.maxX - 4, to = index % 2 == 0 ? column.maxX - 4 : column.minX + 4
        glide(to: CGPoint(x: from, y: y), speed: 500)
        segment("inactive-sweep-\(name)", textExcept([icon], in: column)) {
            glide(to: CGPoint(x: (from + to) / 2, y: y), speed: 260); rest(0.8)
            glide(to: CGPoint(x: to, y: y), speed: 260); rest(0.5)
        }
    }
    glide(to: CGPoint(x: h1.minX + 80, y: h1.midY))
    segment("inactive-h1-long-rest", everywhere(["IBEAM"])) { rest(3) }
    return ok
}

/// Окно приложения видно, но впереди другое приложение (так Юрий работает рядом с Paseo):
/// впереди становится сам probe с окошком 1×1 в углу экрана — оно ничего не заслоняет.
func bringProbeToFront(checking points: [CGPoint], windowFrame: CGRect) -> Bool {
    DispatchQueue.main.sync {
        NSApplication.shared.setActivationPolicy(.regular)
        NSApp.finishLaunching()
        let corner = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1, height: 1), styleMask: .borderless, backing: .buffered, defer: false)
        corner.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
    for _ in 0..<30 where NSWorkspace.shared.frontmostApplication?.processIdentifier == app.processIdentifier { usleep(100_000) }
    let front = NSWorkspace.shared.frontmostApplication
    write("inactive: front=\(front?.bundleIdentifier ?? front?.localizedName ?? "?")")
    if front?.processIdentifier == app.processIdentifier { write("FAIL: приложение осталось впереди, неактивное окно не проверено"); return false }
    for point in points {
        if let cover = foreignTopWindow(at: point, mainFrame: windowFrame) { write("FAIL: (\(Int(point.x)),\(Int(point.y))) заслонено: \(cover)"); return false }
    }
    return true
}

/// Эталон: чужое приложение (Chrome со страницей из background-cursor-reference.zsh — сверху сплошной текст,
/// снизу ссылка во всю ширину). Ставит ли оно I-beam и руку, когда впереди другое приложение.
func runForeign() -> Bool {
    guard let window = (attribute(axApp, kAXWindowsAttribute) as [AXUIElement]?)?.first, let windowFrame = frame(of: window)
    else { write("FAIL: нет окна"); return false }
    write("window=\(windowFrame)")
    let text = CGPoint(x: windowFrame.midX, y: windowFrame.minY + windowFrame.height * 0.4)
    let link = CGPoint(x: windowFrame.midX, y: windowFrame.minY + windowFrame.height * 0.85)
    glide(to: text, speed: 600); segment("active-text", everywhere(["IBEAM"])) { rest(1.5) }
    glide(to: link); segment("active-link", everywhere(["HAND"])) { rest(1.5) }
    guard bringProbeToFront(checking: [text, link], windowFrame: windowFrame) else { return false }
    glide(to: text); segment("inactive-text", everywhere(["IBEAM"])) { rest(2) }
    glide(to: link); segment("inactive-link", everywhere(["HAND"])) { rest(2) }
    glide(to: text); segment("inactive-text-back", everywhere(["IBEAM"])) { rest(2) }
    // Окно с неизвестной раскладкой (Notion): сетка позади другого приложения — ставит ли оно хоть где-то не стрелку.
    let grid = windowFrame.insetBy(dx: 40, dy: 60)
    segment("inactive-grid", everywhere(["IBEAM", "HAND"])) {
        for y in stride(from: grid.minY, through: grid.maxY, by: grid.height / 6) {
            for x in stride(from: grid.minX, through: grid.maxX, by: grid.width / 8) { glide(to: CGPoint(x: x, y: y), speed: 1200); rest(0.25) }
        }
    }
    return true
}

/// Обход окна по сетке: в каждой точке — остановка с дрожанием, элемент под мышью (AX) и все указатели за стоянку.
func runWindow() -> Bool {
    guard let window = (attribute(axApp, kAXWindowsAttribute) as [AXUIElement]?)?.first, let windowFrame = frame(of: window)
    else { write("FAIL: нет окна"); return false }
    write("window=\(windowFrame)")
    struct Place { var element: String; var point: CGPoint; var cursors: [String: Int] }
    var places: [Place] = []
    let stepX = 36.0, stepY = 28.0
    var row = 0
    // PROBE_MAX_X / PROBE_MAX_Y (экранные точки) — пройти только часть окна, например боковую панель.
    let environment = ProcessInfo.processInfo.environment
    let maxX = environment["PROBE_MAX_X"].flatMap(Double.init) ?? windowFrame.maxX - 3
    let maxY = environment["PROBE_MAX_Y"].flatMap(Double.init) ?? windowFrame.maxY - 3
    for y in stride(from: windowFrame.minY + 5, to: maxY, by: stepY) {
        let xs = Array(stride(from: windowFrame.minX + 5, to: maxX, by: stepX))
        for x in (row % 2 == 0 ? xs : xs.reversed()) {
            glide(to: CGPoint(x: x, y: y), speed: 1200)
            var element = describeElement(at: mouse)
            if let foreign = foreignTopWindow(at: mouse, mainFrame: windowFrame) { element = "ПОВЕРХ: \(foreign)" }
            usleep(40_000)
            let from = recorder.now
            rest(0.15)
            var cursors: [String: Int] = [:]
            for sample in recorder.snapshot().reversed() {
                guard sample.time >= from else { break }
                cursors[sample.cursor, default: 0] += 1
            }
            places.append(Place(element: element, point: mouse, cursors: cursors))
        }
        row += 1
    }
    write("--- элементы окна: точек с указателем (за стоянку 150 мс каждая точка) ---")
    var byElement: [String: [String: Int]] = [:], arrowExample: [String: CGPoint] = [:], flicker: [String: Int] = [:]
    for place in places {
        let main = place.cursors.max { $0.value < $1.value }?.key ?? "?"
        byElement[place.element, default: [:]][main, default: 0] += 1
        if place.cursors.keys.contains("ARROW"), arrowExample[place.element] == nil { arrowExample[place.element] = place.point }
        if place.cursors.count > 1 { flicker[place.element, default: 0] += 1 }
    }
    for (element, cursors) in byElement.sorted(by: { $0.key < $1.key }) {
        let arrow = arrowExample[element].map { "  стрелка, напр. (\(Int($0.x)),\(Int($0.y)))" } ?? ""
        let blink = flicker[element].map { "  мигание в \($0) точк." } ?? ""
        write("\(element): " + cursors.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: " ") + arrow + blink)
    }
    write("--- точки (x,y): указатели ---")
    for place in places where place.cursors.count > 1 || place.cursors.keys.contains("ARROW") {
        write("(\(Int(place.point.x)),\(Int(place.point.y))) \(place.element): " + place.cursors.map { "\($0.key)=\($0.value)" }.sorted().joined(separator: " "))
    }
    let clickable = ["AXButton", "AXCell", "AXStaticText#page-tree-title"]
    let arrowOnClickable = places.filter { place in
        place.cursors.max { $0.value < $1.value }?.key == "ARROW" && !place.element.hasSuffix("[выкл]")
            && clickable.contains { place.element.hasPrefix($0) }
    }
    write("--- нажимаемое со стрелкой: \(arrowOnClickable.count) точк. ---")
    for place in arrowOnClickable { write("BAD (\(Int(place.point.x)),\(Int(place.point.y))) \(place.element)") }
    return arrowOnClickable.isEmpty
}

// Наблюдатель — на главном потоке, движение — на отдельном.
let sampler = Timer(timeInterval: 0.005, repeats: true) { _ in
    let p = NSEvent.mouseLocation
    recorder.record(cursor: currentCursorName(), point: CGPoint(x: p.x, y: screenTop - p.y))
}
RunLoop.main.add(sampler, forMode: .common)

Thread.detachNewThread {
    activate()
    let ok = mode == "window" ? runWindow() : mode == "foreign" ? runForeign() : runPage()
    DispatchQueue.main.async {
        sampler.invalidate()
        let samples = recorder.snapshot()
        // Журнал смен указателя: время, указатель, точка, участок.
        var last = ""
        for sample in samples where sample.cursor != last {
            write(String(format: "%8.3f  %-10@ (%.0f,%.0f)  %@", sample.time, sample.cursor, sample.point.x, sample.point.y, sample.segment))
            last = sample.cursor
        }
        var pass = ok
        if mode != "window" {
            write("--- итог по участкам (отсчёт каждые 5 мс; 60 мс после входа и после смены ожидания не судятся: доставка события) ---")
            var order: [String] = [], counts: [String: [String: Int]] = [:], bad: [String: Int] = [:], examples: [String: String] = [:]
            var settledFrom = 0.0, previous: (segment: String, expected: Set<String>?)? = nil
            for sample in samples {
                if previous?.segment != sample.segment || previous?.expected != sample.expected { settledFrom = sample.time + 0.06 }
                previous = (sample.segment, sample.expected)
                guard let expected = sample.expected else { continue }
                if counts[sample.segment] == nil { order.append(sample.segment) }
                counts[sample.segment, default: [:]][sample.cursor, default: 0] += 1
                if sample.time >= settledFrom, !expected.contains(sample.cursor) {
                    bad[sample.segment, default: 0] += 1
                    if examples[sample.segment] == nil {
                        examples[sample.segment] = String(format: "%.3f %@ (%.0f,%.0f)", sample.time, sample.cursor, sample.point.x, sample.point.y)
                    }
                }
            }
            for name in order {
                let wrong = bad[name] ?? 0
                if wrong > 0 { pass = false }
                write("\(wrong == 0 ? "ok  " : "BAD ") \(name): " + counts[name]!.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: " ")
                      + (wrong > 0 ? "  неверных=\(wrong), первый: \(examples[name]!)" : ""))
            }
        }
        write(pass ? "RESULT: PASS" : "RESULT: FAIL")
        exit(pass ? 0 : 1)
    }
}
RunLoop.main.run()
