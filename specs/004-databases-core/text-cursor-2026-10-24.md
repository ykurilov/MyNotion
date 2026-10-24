# Указатель мыши: итог проверки 24.10.2026

## Результат и контракт

Свежая сборка production-коммита `13e6d93` прошла адресную живую приёмку на iMac: **2 UI-теста без ошибок**. Рабочая ветка `fix-text-cursor`, только worktree `MyNotion-fix-hover`; основной checkout не изменялся. База `2210d0f` ранее принята координатором.

Эталон поведения предоставил Юрий после проверки оригинального Notion. Прежняя цель «стрелка над ручками» отменена.

| Область | Итоговый курсор |
|---|---|
| H1, абзац, пустое поле текстовой колонки | I-beam |
| Ручки ⋮⋮ и +, иконка страницы, кнопки шапки и обложки | pointingHand |
| Обложка вне кнопок | I-beam, заданный fallback |
| Перемещение обложки | openHand; при удержании closedHand; после отпускания openHand |

## Причина и исправление

Custom controls явно выбирали `arrow` в `cursorUpdate` и `resetCursorRects`. Они переведены на `pointingHand`; обычная поверхность обложки выбирает I-beam.

Отдельный конфликт подтверждён трассой реального активного окна: над `CoverView` родительский `PageTextView.mouseMoved` вызывал inherited `NSTextView.mouseMoved`, после чего выбранный дочерним видом курсор сменялся на I-beam. Это мешало кнопкам обложки и режиму перемещения сохранять свой курсор. Родитель больше не вызывает этот inherited обработчик внутри `coverSlot.view.frame`; текстовая обработка и обновление ручек сохранены. Артефакт: `/tmp/text-cursor-trace/attachments/app-cursor-trace_0_A1B6B815-D071-40F3-A534-783A5BF4B82B.txt`.

После `NSCursor.pop()` в конце перемещения обложки восстанавливался прежний курсор стека, который не обязательно был openHand. `mouseUp` явно восстанавливает openHand для продолжающегося режима перемещения.

Затронуты `BlockHandlesOverlay.swift`, `PageHeaderView.swift`, `CoverView.swift`. Раскладка, шрифты и содержимое страницы не менялись. Временная DEBUG-трасса удалена до финальной сборки и живой проверки.

## RED → GREEN

Все сборки и тесты выполнялись на iMac через `imac-run --no-fallback --wait 1800`, максимум 4 потока. GUI сериализован штатной очередью. Локальных сборок, запуска приложения и VM не было.

- Новый контракт pointingHand на старом исходнике дал 4 ошибки PageEditor: ручка после mouseMoved/cursorUpdate, иконка и кнопка шапки оставляли arrow. Кнопка обложки также оставляла arrow вместо pointingHand. Лог `/tmp/pointing-hand-red.log`.
- Первая fixture обложки без native NSWindow некорректно калибровала I-beam. Эта часть первого failure не считается самостоятельным RED продукта. Fixture исправлена: NSWindow с NSTextView first responder.
- На исправленной fixture openHand до жеста и closedHand при удержании проходили; после mouseUp/pop openHand терялся: **1 ошибка**, `/tmp/pointing-hand-cover-parent-red.log`. Явное восстановление устранило ошибку.
- Проверка сохранения курсора родителем в скрытом unit-окне проходила и до пропуска inherited mouseMoved. Поэтому для этого конфликта доказательством служит трасса активного приложения, а не вымышленный unit RED.

Финальный результат `/tmp/pointing-hand-final-unit.log`: **453 PageEditorTests / 70 suites PASS**, 50.785s; **18 PageCoverTests / 4 suites PASS**, 0.407s. Всего 471 тест. Включены проверки embedded divider: его resize-курсор не подменяется текстовым.

Свежий Debug build-for-testing, Xcode 27.1, завершился с фактическим **build.exit=0**. Локальные артефакты `/tmp/pointing-hand-review/build.exit` и `/tmp/pointing-hand-review/build.log`. Старый bundle и fallback не использовались.

## Живая приёмка свежего исходника

Лог `/tmp/pointing-hand-review/uitest.log`, снимки `/tmp/pointing-hand-review/attachments/`. Перед тестами выполнен свежий desktop/CGWindowList preflight, включая UserNotificationCenter. Приложение подтверждено foreground; видимая страница с cover, иконкой, H1 и абзацем не перекрыта в проверяемых точках. Баннер Xcode в углу рабочего стола не пересекает их.

**2/2 UI PASS, 0 failures, 65.806s:**

- `HoverHandlesLiveTests.testNativeHoverShowsHandlesOnHeadingAndParagraph`: PASS 31.004s. Ручки heading и paragraph реально видимы и hittable. 32 медленных движения: изменение пикселей текста 0, фреймы ручек стабильны. Положительный контроль выделения меняет 1051/4353 пикселя.
- `TextPointerCursorLiveTests.testCoveredH1ParagraphAndHandles`: PASS 34.802s. Свежая изолированная fixture с cover gradients_3 и иконкой. Физические координаты `NSEvent.mouseLocation` проверены после наведения. H1: 385 отсчётов; paragraph: 379; empty: 370. Всего **1134 отсчёта, wrong=0**. Проверены 36 точек движения и остановки в каждой строке.
- Дополнительно **63 независимых свежих чтения AppKit NSCursor.currentSystem** из отдельных процессов, без установки курсора и AppleEvents: 36 конечных точек движения, 3 остановки строк и 24 стабильных чтения 8 контрольных областей.
- H1 ⋮⋮/+, paragraph ⋮⋮/+, иконка страницы, кнопки смены/перемещения обложки дали pointingHand; поверхность обложки вне кнопок дала I-beam. Каждая контрольная область подтверждена тремя независимыми чтениями. Приложение оставалось foreground.

Эталоны измерителя: I-beam 23×22, hotspot 12/11; pointingHand 32×32, hotspot 12/8. Пустой NSCursor.iBeam из UI-runner не использован как эталон: I-beam калибруется настоящим title text field. Независимые чтения добавлены из-за расхождения отдельных прежних немедленных показаний runner с app-side трассой; причина этого расхождения в macOS не установлена. Задержка запуска процесса чтения не трактуется как задержка интерфейса.

Показательные PNG:

- `/tmp/pointing-hand-review/attachments/text-cursor-h1_0_B8498AB8-B788-48C2-847E-D6B6B656D9FF.png`
- `/tmp/pointing-hand-review/attachments/text-cursor-paragraph_0_CD1B3B7D-CC0A-4D3D-B358-FA0C56CBC0F3.png`
- `/tmp/pointing-hand-review/attachments/text-cursor-page-cover_0_C085BF92-E254-497B-8432-8130B21F1536.png`
- `/tmp/pointing-hand-review/attachments/cursor-reference-pointing-hand_0_78240CE4-9C5F-46CF-BB5E-22CA933C7F35.png`

XCUITest-снимки показывают состояние страницы и ручек; форму системного указателя подтверждают измерения в журнале, а не изображение без курсора.

## Ограничения и завершение

Исходное самопроизвольное чередование arrow/I-beam над текстом не поймано в чистой baseline-серии. На финальной проверенной траектории и остановках нарушений нет; это не доказательство отсутствия любой возможной последовательности событий.

Живой drag обложки в финальной серии не выполнялся; openHand/closedHand и восстановление после mouseUp подтверждены unit-тестом. Сравнение с оригинальным Notion остановлено по прямому указанию координатора: используется эталон Юрия. На доступной странице Notion не было обложки. Прежние пробы с неподтверждённым физическим движением или hover не считаются эталонными измерениями. Временный `NotionPointerReferenceProbeTests.swift` удалён, не запускался и в коммиты не включён.

Коммиты после принятого `2210d0f`: `80bc886` — контракт pointingHand; `3579b4b` — cover gesture и независимые системные чтения; `13e6d93` — production fix. Этот отчёт фиксируется отдельным коммитом. Интеграцию выполняет координатор.
