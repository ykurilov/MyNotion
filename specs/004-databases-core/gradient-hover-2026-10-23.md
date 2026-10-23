# Градиент обложки и нативное наведение, 23.10.2026

Ветка fix-hover-flicker, общая база 634d55f (merge559bdf8). Основной checkout не менялся. Все сборки и проверки выполнялись на iMac через imac-run --no-fallback --wait1800, jobs4. GUI через scripts/imac/run-on-imac.sh lock; очередь с агентом профилирования соблюдена. Новый runner сам будит дисплей, отдельный caffeinate не применялся.

## Градиент: подтверждённая причина и red → green

CoverGallery.bitmap передавал CGContext внешний указатель на локальный [UInt8] внутри withUnsafeMutableBytes. Возвращаемый CGImage продолжал жить после освобождения массива. Создание других изображений переиспользовало память, включая alpha: дефект относится ко всем градиентам/цветам с этим путём, а не только gradients_3. CoverView при переоткрытии страницы вновь получает изображение галереи; изменение рисунка не потребовало гипотезы о stale cache.

4599e1f: CGDataProvider удерживает Data(bytes), CGImage использует этот provider. Палитры и интерполяция не менялись.

79784b4: CoverGalleryLifetimeTests удерживает изображения всех элементов галереи, создаёт ещё16 и сравнивает крайние RGBA с палитрой, включая alpha255. На старом коде **RED**: 1 test failed,22 issues,0.114s (/tmp/cover-gallery-red.log). Например gradients_3: начало [224,213,224,94] вместо [91,57,66,255], конец [124,0,0,0] вместо [139,198,213,255]. После исправления **GREEN**: CoverGalleryLifetimeTests + CoverViewTests + PageCoverOperationsTests,17tests/3suites PASS,0.536s (/tmp/cover-gallery-green.log).

Свежая Debug build-for-testing прошла, реальный build.exit0: iMac .imac-runner-hover-build/gradient-hover-review/build.exit, build.log. При следующем incremental сначала получен rc66 (синхронизация удалила генерируемый .xcodeproj); после xcodegen generate выполнена новая сборка с exit0, slow-build.log. Старый binary при ошибке не использовался.

## Проба ручек

UITests/HoverHandlesLiveTests использует готовую EditorScenarioFixture без набора текста, светлую тему, окно активировано, каретка в title. Нативный XCUI hover задаётся относительно ОКНА, а не AX-рамки длинного body. NSEvent.mouseLocation проверяет физическую позицию с точностью2pt. Перед исследованием flicker подтверждены exists и isHittable ручки над heading2 и paragraph.

Первый адресный прогон: 1/1 PASS за12.772s (/tmp/hover-native-uitest.log). Heading target976.5/440pt совпал с фактическим указателем, ручка867.5/432.95390625,18×24pt. Paragraph target976.5/480pt также совпал, ручка867.5/476.1890625,18×24pt. Окно520/245,1200×800pt. Поэтому прежнее отсутствие ручек в Cua-сериях не доказывало дефект продукта; нативная проба достигает реального hover без изменений редактора.

Первый Cua-проход показал правильный насыщенный gradients_3 на initial, но снимок gradient-return остался на дочерней странице. Этот возврат и последующие resize НЕ засчитаны. Для продолжения применены AX-действия с проверкой фактически открытой страницы.

## Финальная живая серия: PASS с ограничениями hover

Очередь дождалась освобождения perf GUI; наша серия завершилась0, слот освобождён до разбора кадров. Preflight desktop видим. Использовался свежий build.exit0; системное уведомление Xcode в углу не закрывало проверяемое окно и действий не блокировало.

Нативный тест HoverHandlesLiveTests: **1/1 PASS,73.352s**, /tmp/gradient-hover-final/uitest.log.16 шагов над heading2 и16 над paragraph, шаг10pt по X и ±3pt по Y. Ручки над обеими строками реально видны на PNG и isHittable, minY стабилен с точностью1pt. Во всех32 сравнениях полосы500×40pt число пикселей с отличием>8 равно0. Контроль: doubleClick выделяет слово в той же области и даёт1051 изменённый пиксель heading и4351 paragraph. Это исключает сравнение пустого ROI. Фактические начальные координаты указателя совпали с ожидаемыми, выше. Каретка во время измерений находилась в title, а не body.

**Исходное мерцание не воспроизвелось.** Product hover не менялся, red→green для flicker нет. Проба не исключает кратковременное изменение между снимками и не покрывает все состояния, в частности медленное наведение при редактировании body, другие страницы/виды блоков, меню ручки и undo. Старый Cua-маршрут не считать доказательством отсутствия ручек в продукте; на текущей сборке нативное наведение их показывает.

Далее открыта свежая собственная база с gradients_3, noicon/title/emptyheading. AX подтвердил сначала «Название страницы», затем «Подстраница первая», после нажатия AX-кнопки «Назад» вновь «Название страницы». App PID87075/window4432, размер1740×1000pt. Реальный resize1000→1740 подтверждён frame и снимками. Насыщенный плавный градиент сохраняется на initial/return/wide; в центральном ROI cover PNG x300…900,y110…300 (600×190px) initial против return и wide **побайтно совпадает**,0 изменённых пикселей. При narrow меняется штатное кадрирование градиента; после возврата ширины рисунок восстановлен. Title и пустая подсказка раздельны, cover остаётся выше них.

Локальные артефакты /tmp/gradient-hover-final/: gradient-initial.png, other-page.png, gradient-return.png, gradient-narrow.png, gradient-wide.png, native-hover-heading.png, native-hover-paragraph.png, attachments/, actions.jsonl, uitest.log, hover.exit0. iMac: ~/work/shots/gradient-hover-final/. Общий контроллер /tmp/gradient-hover-final.py, журнал /tmp/gradient-hover-final.log, исходная серия /tmp/gradient-hover-review.py и /tmp/gradient-hover-review/ (её ошибочный возврат выше явно не засчитан).

Градиент исправлен и подтверждён unit red→green и реальным page-return/resize. Hover получил работающую нативную диагностическую пробу, остаётся невоспроизведённым дефектом, а не заявленным исправлением.
