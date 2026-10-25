// Курсор и текст окна MyNotion через «Универсальный доступ» (AX), для живых проверок на iMac.
// Страница — один текстовый вид (AXTextArea): курсор — его AXSelectedTextRange.
//
//   ax-text-probe <pid> set <фрагмент> <сдвиг>   поставить курсор в слова «фрагмент» на «сдвиг» знаков от начала
//   ax-text-probe <pid> get                       место курсора: «loc=<число> ctx=<текст вокруг>» (контекст не зависит от правок выше)
//   ax-text-probe <pid> wait <текст> <секунды>    ждать, пока текст появится в окне; печатает «ms=<мс>» или «TIMEOUT»
import AppKit
import ApplicationServices

setvbuf(stdout, nil, _IOLBF, 0)
let args = CommandLine.arguments
guard args.count >= 3, let pid = pid_t(args[1]) else { print("usage: ax-text-probe <pid> set|get|wait …"); exit(2) }
guard AXIsProcessTrusted() else { print("FAIL: процесс без права «Универсальный доступ»"); exit(3) }
let app = AXUIElementCreateApplication(pid)

func attribute(_ element: AXUIElement, _ name: String) -> AnyObject? {
    var value: CFTypeRef?
    return AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success ? value : nil
}

/// Все элементы окна в глубину.
func walk(_ element: AXUIElement, depth: Int = 0, _ visit: (AXUIElement) -> Void) {
    visit(element)
    guard depth < 14, let children = attribute(element, "AXChildren") as? [AXUIElement] else { return }
    for child in children { walk(child, depth: depth + 1, visit) }
}

/// Текстовый вид страницы: самый длинный AXTextArea.
func pageTextArea() -> (element: AXUIElement, text: NSString)? {
    var best: (AXUIElement, NSString)?
    walk(app) { element in
        guard attribute(element, "AXRole") as? String == "AXTextArea", let text = attribute(element, "AXValue") as? String else { return }
        if best == nil || text.utf16.count > best!.1.length { best = (element, text as NSString) }
    }
    return best
}

func caretLocation(_ element: AXUIElement) -> Int? {
    guard let raw = attribute(element, "AXSelectedTextRange") else { return nil }
    var range = CFRange()
    return AXValueGetValue(raw as! AXValue, .cfRange, &range) ? range.location : nil
}

switch args[2] {
case "set":
    guard args.count >= 5, let shift = Int(args[4]), let (area, text) = pageTextArea() else { print("FAIL: нет текстового вида или аргументов"); exit(1) }
    let found = text.range(of: args[3])
    guard found.location != NSNotFound else { print("FAIL: в окне нет «\(args[3])»"); exit(1) }
    AXUIElementSetAttributeValue(area, "AXFocused" as CFString, kCFBooleanTrue)
    var range = CFRange(location: found.location + shift, length: 0)
    guard let value = AXValueCreate(.cfRange, &range),
          AXUIElementSetAttributeValue(area, "AXSelectedTextRange" as CFString, value) == .success else { print("FAIL: курсор не поставился"); exit(1) }
    print("OK loc=\(range.location)")
case "get":
    guard let (area, text) = pageTextArea(), let location = caretLocation(area) else { print("FAIL: курсора нет"); exit(1) }
    let from = max(0, location - 6), to = min(text.length, location + 10)
    print("loc=\(location) ctx=\(text.substring(with: NSRange(location: from, length: to - from)).replacingOccurrences(of: "\n", with: "⏎"))")
case "wait":
    guard args.count >= 5, let seconds = Double(args[4]) else { print("usage: wait <текст> <секунды>"); exit(2) }
    let started = Date()
    while Date().timeIntervalSince(started) < seconds {
        var seen = false
        walk(app) { element in
            for name in ["AXValue", "AXTitle"] where (attribute(element, name) as? String)?.contains(args[3]) == true { seen = true }
        }
        if seen { print("ms=\(Int(Date().timeIntervalSince(started) * 1000))"); exit(0) }
        usleep(20_000)
    }
    print("TIMEOUT")
    exit(1)
default:
    print("неизвестная команда \(args[2])"); exit(2)
}
