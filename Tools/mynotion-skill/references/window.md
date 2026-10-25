# Окна и вкладки

Показать Юрию результат: открыть страницу, переключить вкладку, вернуться назад. Данные от этого не меняются.
Окна на передний план сами не выходят: Юрий продолжает работать там, где работал. Вперёд приложение выводит только `--activate`.

## С чего начать

```bash
mynotion window state --agent Codex      # окна, вкладки, страница каждой, переднее окно
mynotion open Проекты/Встреча --new-tab --agent Codex
```

`window state` → `{windows:[{index, front, tabs:[{index, pageId, title, selected}], canGoBack, canGoForward, canReopenTab, busy}], front}`.
Окна и вкладки считаются с 1, как в этом ответе. Вкладка без страницы показывает «Недавние»: `pageId: null`.

## Открыть страницу

```bash
mynotion open Проекты/Встреча                  # в текущей вкладке переднего окна, с записью в «назад»
mynotion open Проекты/Встреча --new-tab        # новой вкладкой в конце, она становится выбранной
mynotion open Проекты/Встреча --new-window     # новое окно
mynotion open <стр> --block <блок>             # прокрутить к блоку этой страницы
mynotion open <стр> --activate                 # вывести MyNotion вперёд (иначе окно только поднимается над другими)
```

- Страница — id, путь или `current`. `--new-tab` и `--new-window` вместе — `invalid_argument`.
- Окон нет (все закрыты) — страница открывается в новом окне, какие бы флаги ни были.
- Блок другой страницы — `wrong_page`. Страница в корзине — `page_in_trash`.
- Ответ: `{page:{id,title}, window:{…}}` — окно после открытия, номер нового окна — `window.index`.

## Вкладки

```bash
mynotion tab new                     # пустая вкладка в конце («Недавние»), выбранная
mynotion tab select --tab 2
mynotion tab close --tab 2           # без --tab — выбранная
mynotion tab reopen                  # вернуть последнюю закрытую вкладку этого окна
mynotion tab new --window 2          # другое окно, номер из window state
```

- Без `--window` — переднее окно.
- Нет вкладки с таким номером — `tab_not_found`; нет окна — `window_not_found`.
- Последнюю вкладку окна не закрыть (`invalid_argument`): команды «закрыть окно» нет. Открой в ней другую страницу — `open`.
- `tab reopen` помнит закрытые вкладки, пока окно открыто (до 20); нечего возвращать — `tab_not_found` (`canReopenTab: false`).

## Назад и вперёд

```bash
mynotion nav back
mynotion nav forward --window 2
```

Истории нет (`canGoBack` / `canGoForward` — `false`) — это не ошибка: `ok`, `moved: false`, окно как было.

## Нельзя

- Открыт лист или диалог (импорт, настройки, окно «Открыть в новой вкладке») — команды окна отвечают `window_busy` (код выхода 4). Команды данных работают. Подожди и повтори; `open --new-window` проходит и так.
- Команды окна нельзя класть в `batch` (`not_batchable`): у окна нет отмены.
