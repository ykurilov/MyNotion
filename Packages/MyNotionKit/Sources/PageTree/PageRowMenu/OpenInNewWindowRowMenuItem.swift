extension PageRowMenuItem {
    /// «Открыть в новом окне» (меню ссылки на страницу): новое окно с этой страницей, как `mynotion open --newWindow`.
    static let openInNewWindow = PageRowMenuItem(slot: .openInNewWindow) { _ in "Открыть в новом окне" }
}
