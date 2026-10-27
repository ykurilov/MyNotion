import Observation

/// База записей, открытая один раз на жизнь процесса. Неудача не запоминается: система может запустить приложение
/// ради пуша до первой разблокировки iPhone, когда файлы ещё закрыты, — тогда база открывается при следующем случае
/// (следующий пуш, выход на экран).
@MainActor
@Observable
final class PhoneLibraryOpener {
    private(set) var result: Result<PhoneLibrary, any Error>
    @ObservationIgnored private let open: () throws -> PhoneLibrary

    init(open: @escaping () throws -> PhoneLibrary) {
        self.open = open
        result = Result { try open() }
    }

    /// Открытая база; не открылась раньше — ещё одна попытка.
    var library: PhoneLibrary? {
        if case .failure = result { result = Result { try open() } }
        return try? result.get()
    }
}
