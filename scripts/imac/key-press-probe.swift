// Настоящие нажатия клавиш в процесс MyNotion (CGEvent), для живых проверок на iMac.
//
//   key-press-probe <pid> <код клавиши> <сколько раз> <пауза, мс>
//
// ⌫ — код 51. Пауза 35 мс — темп автоповтора зажатой клавиши. Нажатия с пометкой автоповтора без настоящей
// зажатой клавиши окно не получает (проверено на iMac: из пяти дошло одно), поэтому каждое — нажатие и отпускание.
// Нужно право «Универсальный доступ» (у входа по SSH оно есть).
import AppKit
import ApplicationServices

let args = CommandLine.arguments
guard args.count == 5, let pid = pid_t(args[1]), let key = CGKeyCode(args[2]), let count = Int(args[3]), let pause = UInt32(args[4]) else {
    print("usage: key-press-probe <pid> <код> <раз> <пауза мс>"); exit(2)
}
guard AXIsProcessTrusted() else { print("FAIL: процесс без права «Универсальный доступ»"); exit(3) }
func post(down: Bool) {
    guard let event = CGEvent(keyboardEventSource: nil, virtualKey: key, keyDown: down) else { print("FAIL: событие не создалось"); exit(1) }
    event.postToPid(pid)
}
for _ in 0..<count {
    post(down: true)
    post(down: false)
    usleep(pause * 1000)
}
print("OK \(count)")
