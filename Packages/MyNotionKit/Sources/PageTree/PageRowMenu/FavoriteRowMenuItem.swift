extension PageRowMenuItem {
    /// «Добавить в избранное» / «Убрать из избранного» — по тому, в избранном ли страница.
    static let favorite: PageRowMenuItem? = PageRowMenuItem(slot: .favorite) {
        $0.isFavorite ? "Убрать из избранного" : "Добавить в избранное"
    }
}
