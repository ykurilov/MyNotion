import CoreGraphics
import Foundation
// displaymode            — список режимов главного экрана
// displaymode W H        — включить режим W×H точек с ретиной (2×), если есть
let display = CGMainDisplayID()
let options = [kCGDisplayShowDuplicateLowResolutionModes: true] as CFDictionary
let modes = (CGDisplayCopyAllDisplayModes(display, options) as? [CGDisplayMode]) ?? []
let args = CommandLine.arguments.dropFirst().compactMap { Int($0) }
if args.count == 2 {
    guard let mode = modes.first(where: { $0.width == args[0] && $0.height == args[1] && $0.pixelWidth == 2 * $0.width }) else {
        print("нет режима \(args[0])×\(args[1]) @2x"); exit(1)
    }
    var config: CGDisplayConfigRef?
    CGBeginDisplayConfiguration(&config)
    CGConfigureDisplayWithDisplayMode(config, display, mode, nil)
    print(CGCompleteDisplayConfiguration(config, .permanently) == .success ? "включён \(mode.width)×\(mode.height) @2x" : "не включился")
} else {
    for m in modes { print("\(m.width)x\(m.height) px \(m.pixelWidth)x\(m.pixelHeight)") }
}
