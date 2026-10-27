import NotesCore
import PhoneShell
import SwiftUI

/// Точка подключения экрана страницы. Оболочка показывает здесь страницу по `pageId`; сейчас — заглушка только
/// для чтения, при слиянии сюда встаёт редактор страницы. Что оболочка даёт экрану страницы:
/// - `library.openDocuments` — открытые страницы: синхронизация сама вызывает `applyExternalChanges` для них,
///   а уход приложения в фон — `saveAll()` (`PhoneSyncController.didEnterBackground`);
/// - `library.store` — база записей; `library.browser` — дерево (названия подстраниц, путь);
/// - `library.sync.remoteChangeCount` — растёт, когда пришли правки с других устройств.
/// Верхняя полоса («назад», «+» новой подстраницы) — у оболочки (`PageContainer`), не у экрана страницы.
struct PageScreen: View {
    let pageId: UUID
    let library: PhoneLibrary

    var body: some View {
        PageStubView(pageId: pageId, library: library)
    }
}
