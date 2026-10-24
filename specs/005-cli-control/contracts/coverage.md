# Контракт: операция интерфейса → команда (SC-408)

Проверка охвата: у каждой операции из окна, входящей в охват, есть команда. Источник операций — публичные методы `PageTreeOperations`, `DatabaseOperations`, `MainWindowModel`, `WindowTabs` и меню приложения (снято 24.10.2026). Новая операция в этих классах после 005 — строка сюда и команда. Этап 8 сверяет таблицу с кодом (тест `CoverageTableTests`: каждый публичный метод операций либо назван здесь, либо в списке «не входит»).

| Операция в коде | Команда |
|-----------------|---------|
| `MainWindowModel.createPage`, `PageTreeOperations.createSubpage` | `page create` |
| `rename`, `setIcon` | `page rename`, `page icon` |
| `move(_:toParent:at:)` | `page move` |
| `moveToTrash`, `restore`, `deleteForever`, `emptyTrash` | `page trash`, `page restore`, `trash delete --force`, `trash empty --force` |
| `setCover`, `setCoverOffset`, `setFullWidth`, `setSmallText` | `page cover`, `page layout` |
| `addToFavorites`, `removeFromFavorites`, `moveFavorite` | `favorites add/remove/move` |
| `makeTemplate`, `stopBeingTemplate`, `createPage(fromTemplate:)`, `fill(_:fromTemplate:)` | `template mark/unmark`, `page create --template` |
| `duplicate` | `page duplicate` |
| `moveBlocks(_:from:to:)` | `block move-to-page` |
| `restoreVersion` | `history restore` |
| `turnIntoSubpage` | `block update --kind pageLink` |
| Правка блоков в `PageTextView` (вставка, текст, вид, отступ, перенос, отметка, раскрытие, удаление) | `block insert/update/indent/outdent/move/check/uncheck/expand/collapse/delete` |
| `DatabaseOperations.createDatabase` | `db create` |
| `addProperty`, `insertProperty`, `renameProperty`, `setPropertyConfig`, `changeType`/`startChangeType`, `moveProperty`, `duplicateProperty`, `setDeleted`, `eraseProperty` | `db prop add/update/type/move/duplicate/delete/restore` |
| `createOption`, `renameOption`, `setOptionColor`, `moveOption`, `deleteOption`, `removeOption`, `setOptionSort` | `db option …`, `db prop update --config` |
| `addRow`, `duplicateRows`, `trashRows`, `setRowsTrashed`, `moveRows`, `setTitle`, `setCell`, `writeCells` | `db row add/duplicate/trash/restore/update`, `db cell set`, `db view update --order-rows` |
| `addRelation`, `setRelationLimit`, `setRelatedProperty`, `linkRow`, `unlinkRow`, `createLinkedRow`, `setRollup` | `db prop add --type relation/rollup`, `db prop update`, `db relation link/unlink` |
| `setFormula` | `db prop update --formula` |
| `addFiles`, `removeFile` | `attachment add <база> <строка> <свойство>`, `db cell set` |
| `setFilter`, `addFilter`, `setSorts`, `sort(by:)`, `moveSort`, `removeSort`, `setVisible`, `moveColumn`, `setColumnWidth`, `setWrap`, `setCalculation`, `setGroup`, `group(by:)`, скрытие/свёртка/порядок групп, `setOpenRowsIn`, `setLoadLimit` | `db view update` (`--filter --sort --group --visible --hidden --order --width --wrap --calc --open-in --load-limit`, `--group-hide/--group-collapse/--group-order`) |
| Скрыть свойство (FR-419) — скрытие в виде, как в окне | `db view update --hidden` |
| Открыть строку базы как страницу (FR-419) — строка и есть страница | `page get/read <строка>`, `open <строка>` |
| `addView`, `renameView`, `duplicateView`, `deleteView`, `moveView` | `db view add/rename/duplicate/delete/move` |
| Шаблоны строк 004 (US6) | `db template …` |
| Выгрузка базы | `db export` |
| `PageSearch.results` | `search` |
| `recentPages` | `recents` |
| `PageVersionStore.versions`, `snapshot` | `history list/show` |
| `AttachmentStore.importFile`, `fileURL` | `attachment add/get/list` |
| `MainWindowModel.open/select`, `openInNewTab`, `goBack`, `goForward`; `WindowTabs.open/close/reopenClosedTab`; новое окно | `open`, `tab …`, `nav …` |
| Импорт Notion, выгрузка Markdown (меню «Файл») | `import notion`, `export page/all` |
| Синхронизация: состояние, «Синхронизировать сейчас» | `sync status/now` |

**Не входит** (spec, Assumptions): настройки приложения, вход и сервер синхронизации, ключ Notion и «Дочитать схему», тема и внешний вид, окно конфликта, сочетания клавиш, напоминания как уведомления (дата с напоминанием ставится через ячейку и упоминание даты в тексте), галерея состояний.
