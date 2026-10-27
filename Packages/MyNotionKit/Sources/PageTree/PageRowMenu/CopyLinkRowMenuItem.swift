extension PageRowMenuItem {
    /// «Копировать ссылку»: адрес `mynotion://page/<id>` в буфер обмена — дать агенту или открыть щелчком.
    static let copyLink: PageRowMenuItem? = PageRowMenuItem(slot: .copyLink) { _ in "Копировать ссылку" }
}
