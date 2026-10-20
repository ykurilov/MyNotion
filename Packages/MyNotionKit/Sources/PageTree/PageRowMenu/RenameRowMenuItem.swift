extension PageRowMenuItem {
    /// «Переименовать» (001): название правится прямо в строке.
    static let rename: PageRowMenuItem? = PageRowMenuItem(slot: .rename) { _ in "Переименовать" }
}
