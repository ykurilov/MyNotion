extension PageRowMenuItem {
    /// «Новая страница по шаблону» — только у строки шаблона, первым пунктом.
    static let newFromTemplate: PageRowMenuItem? = PageRowMenuItem(slot: .newFromTemplate) {
        $0.isTemplate ? "Новая страница по шаблону" : nil
    }
}
