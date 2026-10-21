extension PageRowMenuItem {
    /// «Открыть в новой вкладке» (US3): справа от текущей, активная остаётся (как ⌘-щелчок).
    static let openInNewTab: PageRowMenuItem? = PageRowMenuItem(slot: .openInNewTab) { _ in "Открыть в новой вкладке" }
}
