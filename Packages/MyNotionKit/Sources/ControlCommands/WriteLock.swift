/// Замок записи (research R2): изменяющие команды идут строго по одной, по очереди прихода. Чтение замок не берёт.
@MainActor
final class WriteLock {
    private var isHeld = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func acquire() async {
        guard isHeld else {
            isHeld = true
            return
        }
        await withCheckedContinuation { waiters.append($0) }
    }

    /// Замок переходит следующему в очереди, не освобождаясь между ними.
    func release() {
        if waiters.isEmpty {
            isHeld = false
        } else {
            waiters.removeFirst().resume()
        }
    }
}
