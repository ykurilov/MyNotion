import Foundation
import AppKit
import Navigation

extension PageOpenRequest {
    /// Просьба из щелчка: ⌘ в этот момент — открыть в новой вкладке (research R5).
    @MainActor
    static func fromClick(_ pageId: UUID, revealing blockId: UUID? = nil) -> PageOpenRequest {
        PageOpenRequest(pageId: pageId, inNewTab: NSEvent.modifierFlags.contains(.command), revealBlockId: blockId)
    }
}
