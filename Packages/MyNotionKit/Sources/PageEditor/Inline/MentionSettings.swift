import AppKit
import NotesCore

/// Что хозяин страницы даёт упоминаниям и датам: справочник, поиск страниц, разрешение на уведомления.
public struct MentionSettings {
    public var directory: MentionDirectory
    public var lookup: (any PageLookup)?
    public var requestReminderPermission: (@MainActor () async -> Bool)?

    public init(directory: MentionDirectory = MentionDirectory(), lookup: (any PageLookup)? = nil,
                requestReminderPermission: (@MainActor () async -> Bool)? = nil) {
        self.directory = directory
        self.lookup = lookup
        self.requestReminderPermission = requestReminderPermission
    }

    @MainActor
    func apply(to textView: PageTextView) {
        textView.mentionDirectory = directory
        textView.pageLookup = lookup
        textView.onRequestReminderPermission = requestReminderPermission
    }
}

extension PageTextView {
    /// Щелчок по уведомлению напоминания: открыть страницу у блока. Редактор страницы, уже открытой или открытой
    /// следом, ставит курсор в начало блока и прокручивает к нему.
    public static func requestReveal(block blockId: UUID, inPage pageId: UUID) {
        pendingReveals[pageId] = blockId
        NotificationCenter.default.post(name: revealRequested, object: nil)
    }

    nonisolated(unsafe) private static var pendingReveals: [UUID: UUID] = [:]
    static let revealRequested = Notification.Name("PageTextView.revealRequested")

    /// Показать блок, если для этой страницы его просили, а редактор уже в окне.
    func revealPendingBlock() {
        guard window != nil, let blockId = Self.pendingReveals[document.pageId], let index = document.index(ofBlock: blockId) else { return }
        Self.pendingReveals[document.pageId] = nil
        let location = mapper.paragraphStart(ofBlockAt: index)
        window?.makeFirstResponder(self)
        setSelectedRange(NSRange(location: location, length: 0))
        scrollRangeToVisible(NSRange(location: location, length: 0))
    }

    func observeRevealRequests() {
        NotificationCenter.default.addObserver(forName: Self.revealRequested, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.revealPendingBlock() }
        }
    }
}
