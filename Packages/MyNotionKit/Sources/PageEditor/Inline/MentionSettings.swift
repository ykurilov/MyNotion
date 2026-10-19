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
