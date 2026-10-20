extension PageRowMenuItem {
    /// «Сделать шаблоном» / «Перестать быть шаблоном» — по тому, шаблон ли страница.
    static let template: PageRowMenuItem? = PageRowMenuItem(slot: .template) {
        $0.isTemplate ? "Перестать быть шаблоном" : "Сделать шаблоном"
    }
}
