# SafeNet 1.0.0 — проверка сборки

Дата: 2026-11-18. Машина сборки и проверки: macOS 13.7.8, Intel (x86_64), Command Line Tools 14.3.1
(Swift 5.8.1), без Xcode. Пути ниже сокращены: `<repo>` — папка проекта, `<tmp>` — временная папка.

Правила проверки: приложение запускалось только в тестовом режиме (`SAFENET_FAKE_IP` или
`SAFENET_FAKE_OFFLINE`) с временной `SAFENET_CONFIG_DIR`. Защищаемым «приложением» была
одноразовая копия `/bin/sleep` (`<tmp>/snsleeper`), которую ловило правило по полному пути.
Настоящие приложения не замораживались. Настоящая папка `~/Library/Application Support/SafeNet`
не создавалась (её нет и после проверки). В /Applications и /usr/local ничего не ставилось.

## 1. Автоматические проверки, выполненные здесь

### 1.1 Тесты: `scripts/test.sh` (полный набор), два прогона подряд

```
Executed 181 tests, 0 failures      # SafeNetCoreTests
Executed 96 tests, 0 failures       # SafeNetUITests
exit 0
```
Оба прогона одинаковые (после исправления открытия панели, см. 1.5).

### 1.2 Сборка: `scripts/build-app.sh`

```
Architectures in the fat file: .build/SafeNetApp are: x86_64 arm64
dist/SafeNet.app/Contents/Info.plist: OK
dist/SafeNet.app: valid on disk
dist/SafeNet.app: satisfies its Designated Requirement
Identifier=local.safenet.app
Format=app bundle with Mach-O universal (x86_64 arm64)
CodeDirectory v=20500 size=25106 flags=0x10002(adhoc,runtime) hashes=778+3 location=embedded
Signature=adhoc
543e203f959edd482d7beff2531e06fc71bcb507e0e81876b9939e36b3d828fd  SafeNet.zip
```

Подпись: `codesign --force --deep --sign - --options runtime --timestamp=none`. Hardened runtime
с ad-hoc подписью допустим и ничего не ломает (SafeNet грузит только системные библиотеки, без
JIT, плагинов и DYLD-переменных). Приложение из подписанного бандла запускается и работает (1.3).
Перед подписью `xattr -cr`. Иконка генерируется `scripts/make-icon.swift` (CoreGraphics) →
`iconutil -c icns`.

SHA-256 зависит от времени сборки: при каждой пересборке `build-app.sh` печатает новый хеш и
пишет его в `dist/SafeNet.zip.sha256`. Указанный выше хеш относится к сборке, проверенной здесь.

### 1.3 Сквозная проверка бандла: `scripts/verify-app.sh` → `ALL CHECKS PASSED` (62 проверки)

Статические: `codesign --verify --deep --strict`; подпись ad-hoc, идентификатор `local.safenet.app`,
флаг runtime; `lipo -archs` = `x86_64 arm64`; `plutil -lint`; ключи Info.plist (идентификатор,
имя, исполняемый файл, версии 1.0.0/1, LSMinimumSystemVersion 13.0, LSUIElement, NSHighResolutionCapable,
NSPrincipalClass, иконка, категория); нет ключей `*UsageDescription`; есть AppIcon.icns; нет xattr.

Запуск бинарника из бандла (`SafeNet.app/Contents/MacOS/SafeNetApp`) с
`SAFENET_FAKE_IP=1.2.3.4,RU`, в конфиге разрешена только NL:
```
ok   sleeper frozen after launch (stat T)
ok   watchdog 55727 is a direct child of the app (55709)
ok   journal frozen.json lists the sleeper
ok   events.jsonl has a 'frozen' event
ok   socket created / socket mode 0600
     | Приложения заморожены (маршрут до ИИ-сервисов идёт мимо разрешённых адресов, закрытие через 600 с)
     | ТЕСТОВЫЙ РЕЖИМ
     | IP: 1.2.3.4 (RU)
     | VPN-туннель: да
     | Защищаемые приложения:
     |   snsleeper: заморожено
     | Конфиг: <tmp>/cfg/config.yaml
ok   safenet version: SafeNet 1.0.0          # версия читается из Info.plist бандла
ok   safenet config = temp config
ok   safenet panel: Окно SafeNet открыто (a visible panel window exists)
ok   unknown command exit 2
ok   safenet allow RU: Разрешена страна RU
ok   sleeper resumed after allow RU / config.yaml now allows RU / status: Защита включена
ok   hot reload (RU removed) froze the sleeper again
ok   broken config.yaml: app alive, sleeper still frozen (old settings)
ok   app exited on SIGTERM / sleeper resumed / socket removed / watchdog gone / journal cleared
ok   status when not running: exit 3
ok   relaunch froze the sleeper
ok   kill -9: watchdog resumed the sleeper / watchdog exited afterwards
ok   stale socket after kill -9: status exit 3
ok   start over a stale socket: frozen again / CLI works after stale socket
ok   final SIGTERM resumed the sleeper / final: no watchdog, no socket
ok   app log has no crash lines
ok   real config dir untouched (absent)
ok   no leftover processes
```
(Причина заморозки — «маршрут до ИИ-сервисов…»: в тестовом режиме проверка маршрута тоже отвечает
1.2.3.4/RU, она проверяется раньше страны. Это ожидаемо.)

### 1.4 Срок заморозки и оффлайн (вручную, бандл, `grace: 10`, `close_timeout: 2`, `check_interval: 1`)

```
t+3  с: snsleeper TN (заморожен)
t+15 с: snsleeper завершён; события: frozen, leak, closed      # закрыт по истечении срока
SAFENET_FAKE_OFFLINE=1:
t+3  с: TN;  t+17 с: TN (не закрыт, хотя срок 10 с прошёл)        # оффлайн = заморозка без закрытия
status: «Приложения заморожены (нет сети)», «IP: нет ответа (нет сети)»
после SIGTERM: SN (разморожен)
```

### 1.5 Окно панели по команде `safenet panel` — найдена и исправлена ошибка

Снимок экрана (`screencapture -x`) здесь бесполезен: без разрешения «Запись экрана» он содержит
только обои и строку меню активного приложения, без значков статуса и чужих окон. Список окон через
`osascript … System Events` отклонён: «Функции Универсального доступа для osascript не разрешены
(-1728)». Разрешения не менялись.

Вместо этого окна процесса перечислялись через `CGWindowListCopyWindowInfo` (уровень, размер,
видимость доступны без разрешений). До исправления: после `safenet panel` (ответ «Окно SafeNet
открыто») окна панели НЕ было, только значок в строке меню (уровень 25, 99×24 pt). Причина
подтверждена на минимальном SwiftUI-приложении: `openWindow`, взятый из environment ярлыка
MenuBarExtra, на macOS 13 ничего не открывает; `openWindow` из содержимого меню и пункт
«SafeNet» в меню Window открывают окно. Исправление (коммит «fix: 'safenet panel' opened
nothing…»): действие запоминается из содержимого меню, а до первого открытия меню используется
пункт меню Window. CLI отвечает «открыто» только если видимое окно панели действительно есть.
После исправления: окно уровня 0, 720×488 pt, на экране; повторный `panel` не создаёт второе окно.

Кнопка «Открыть панель» в меню и раньше использовала environment содержимого меню (рабочий путь),
но кликом её здесь не проверить.

### 1.6 Уведомления внутри бандла (`/usr/bin/log show --predicate 'process == "SafeNetApp"'`)

```
[local.safenet.app] Creating a user notification center
[local.safenet.app] Requesting authorization with options 6
[local.safenet.app] Adding notification request … Added notification request: [ hasError: 0 … ]
usernoted: Sending request for permission for local.safenet.app with path …/dist/SafeNet.app
(следующие запуски) Requested authorization [ didGrant: 0 hasError: 1 … ]
```
`UNUserNotificationCenter` внутри .app включается и не падает. Система показала запрос разрешения на
уведомления (на него никто не ответил, поэтому дальше «didGrant: 0»). Само появление баннера не
проверено (см. раздел 2).

### 1.7 Автозапуск (SMAppService) для ad-hoc подписанного приложения

Настоящий SafeNet.app не регистрировался. Вместо этого временная копия бандла с другим идентификатором
(`local.safenet.autostart-probe`), ad-hoc + runtime, внутри которой маленькая программа вызывала
API приложения `Autostart.set(true)` / `Autostart.set(false)`:
```
bundle id: local.safenet.autostart-probe available: true
before: notFound isEnabled: false
register: ok
after register: enabled isEnabled: true
unregister: ok
after unregister: notRegistered isEnabled: false
```
`sfltool dumpbtm` после этого: запись `SNAutostartProbe`, `Disposition: [disabled, allowed, visible,
notified]`, идентификатор — cdhash. Объект входа выключен (не зарегистрирован). Неактивная запись
остаётся в базе фоновых объектов macOS: так macOS хранит историю, и удалить её можно только
`sfltool resetbtm` (сброс всех записей, нужен администратор). Это не делалось. Пробное приложение
удалено.

Вывод: ad-hoc приложение регистрируется как объект входа без ошибок. macOS опознаёт его по cdhash,
а cdhash меняется при каждой пересборке. После обновления SafeNet новой сборкой переключатель
автозапуска, возможно, придётся включить заново.

### 1.8 Архив

```
unzip -l dist/SafeNet.zip
  SafeNet/ПРОЧТИ-МЕНЯ.txt   (unzip печатает кириллицу как ????, ditto/Finder распаковывают правильно)
  SafeNet/SafeNet.app/Contents/{_CodeSignature/CodeResources, MacOS/SafeNetApp, Resources/AppIcon.icns,
                                Resources/safenet, Info.plist, PkgInfo}
ditto -x -k dist/SafeNet.zip <tmp>      → SafeNet/SafeNet.app, SafeNet/ПРОЧТИ-МЕНЯ.txt
codesign --verify --deep --strict        → valid on disk, satisfies its Designated Requirement
spctl -a -vv -t exec                     → rejected   (ожидаемо: не нотаризовано; поэтому инструкция
                                           «Открыть» / «Всё равно открыть» в ПРОЧТИ-МЕНЯ.txt)
scripts/verify-app.sh <tmp>/SafeNet/SafeNet.app → ALL CHECKS PASSED (CLI через обёртку внутри бандла)
```
Обёртка `safenet` через симлинк (`ln -s dist/safenet <tmp>/safenet`, `ln -s …/Resources/safenet …`):
`version` → «SafeNet 1.0.0»; без аргументов выводит справку (приложение не запускает).

## 2. Что здесь проверить НЕЛЬЗЯ — пошаговые инструкции

Здесь не проверено: нет разрешений «Запись экрана» и «Универсальный доступ» для терминала, слайс
arm64 не запускается на Intel, нет macOS 15/26. Нужен человек.

### 2.0 Подготовка

**На этом Mac (Intel, macOS 13)** можно запускать прямо из `dist/` (сборка уже без карантина).
Для демонстрации с подставным IP, не трогая настоящих настроек:
```sh
mkdir -p /tmp/sn-demo
SAFENET_CONFIG_DIR=/tmp/sn-demo SAFENET_FAKE_IP=1.2.3.4,RU \
  dist/SafeNet.app/Contents/MacOS/SafeNetApp
```
(завершить: Ctrl-C в этом терминале или «Выйти из SafeNet» в меню).

**У друга (macOS 26, скорее всего Apple Silicon):** получить `SafeNet.zip`, сверить хеш
(`shasum -a 256 SafeNet.zip` должен совпасть с присланным), распаковать двойным щелчком,
перетащить SafeNet.app в «Программы».

### 2.1 Первый запуск и Gatekeeper (только на другом Mac)
1. Двойной щелчок по SafeNet.app. Ожидается предупреждение, что приложение не проверено.
2. macOS 13–14: правый щелчок → «Открыть» → «Открыть». macOS 15/26: закрыть предупреждение →
   Системные настройки → Конфиденциальность и безопасность → внизу «Всё равно открыть» → пароль.
3. Ожидается: значок SafeNet в строке меню, в Доке значка НЕТ.
4. Запишите, какой путь сработал и какие были тексты окон (для ПРОЧТИ-МЕНЯ).
5. Проверка slice arm64: в Терминале `file /Applications/SafeNet.app/Contents/MacOS/SafeNetApp`
   и «Мониторинг системы» → столбец «Тип» для SafeNetApp должен быть «Apple», не «Intel».

### 2.2 Первая настройка (first-run)
1. Новая установка, настроек нет. Щёлкнуть значок в строке меню.
2. Ожидается в меню призыв «Выберите разрешённые страны или IP» и пояснение, что пока список пуст,
   выбранные приложения будут заморожены. Кнопка «Открыть панель».
3. Включить VPN → в меню (или на вкладке «Обзор») «Разрешить этот IP», либо добавить страну на
   вкладке «Разрешено» → строка меню показывает флаг и IP, состояние «ок».

### 2.3 Значок в строке меню
1. Ожидается: флаг страны + IP (например «🇳🇱 185.x.x.x»); при заморозке рядом символ состояния.
2. Панель → Настройки → вид строки меню: IP / страна / только значок — каждый вариант меняет значок
   сразу.
3. Проверить, что текст не обрезан и читается в тёмной и светлой строке меню.

### 2.4 Окно меню и панель, тёмная/светлая тема, акцент
1. Щёлкнуть значок → окно меню. Проверить вид в тёмной теме: фон, карточки, переключатели (видна ли
   ручка переключателя), цвета статусов (зелёный/оранжевый/красный).
2. «Открыть панель» → окно «SafeNet» должно открыться ПОВЕРХ других окон и сразу получить фокус
   (можно печатать без дополнительного щелчка). Пройти все 7 вкладок.
3. Закрыть панель красной кнопкой → SafeNet продолжает работать (значок остаётся).
4. В Терминале `safenet panel` (если команда подключена) → панель открывается и выходит вперёд, даже
   если меню ещё ни разу не открывали. Повторить после закрытия панели.
5. Системные настройки → Оформление → Светлое: меню и панель перекрашиваются без перезапуска
   (если в SafeNet тема «как в системе»). Затем «Тёмное». Затем «Автоматически» — SafeNet должен
   следовать текущему виду системы.
6. Панель → Настройки → тема «Светлая»/«Тёмная» принудительно: вид не зависит от системы.
7. Сменить акцент (синий/фиолетовый/оранжевый/розовый…): кнопки и выделения меняют цвет, цвета
   статусов не меняются.

### 2.5 Уведомления
1. Тестовый режим (2.0) с выбранным приложением, которого нет в разрешённых.
2. При первой заморозке macOS спрашивает разрешение на уведомления от SafeNet → «Разрешить».
3. Ожидается баннер «Приложения заморожены: …». После «Разрешить этот IP» или `safenet allow RU` →
   «Защита восстановлена». В текстах нет IP, путей и имён пользователя.
4. Испортить `config.yaml` (например дописать `allow: [`) → уведомление «SafeNet: ошибка в config.yaml»,
   работа продолжается на прежних настройках.

### 2.6 Автозапуск
(Только из SafeNet.app в «Программах», не в тестовом режиме на чужой папке настроек.)
1. Панель → Настройки → «Запускать при входе в систему» → включить.
2. Системные настройки → Основные → Объекты входа: в списке «Открывать при входе» есть SafeNet.
   macOS может показать уведомление «Добавлен фоновый объект».
3. Выйти из системы и войти снова → SafeNet в строке меню.
4. Выключить переключатель → SafeNet пропал из «Объектов входа».
5. На macOS 26 записать, просит ли система подтверждение (статус «requires approval»).

### 2.7 Пауза и «Закрыть сейчас»
1. В меню «Пауза» → 5 мин: состояние «пауза до ЧЧ:ММ», замороженные приложения оживают.
   По окончании паузы защита возвращается сама.
2. При заморозке: «Продлить» отодвигает закрытие на 60 с (отсчёт в меню растёт).
3. При заморозке: «Закрыть сейчас» → кнопка меняется на «Точно закрыть?» → второй щелчок закрывает
   замороженные приложения; без второго щелчка ничего не закрывается.

### 2.8 Демонстрация тестового режима с настоящим приложением (по желанию)
1. Запуск как в 2.0, в панели «Приложения» выбрать, например, TextEdit (не нужное для работы).
2. Ожидается: TextEdit не реагирует (заморожен), в меню «ЗАМОРОЖЕНО», бейдж «ТЕСТОВЫЙ РЕЖИМ».
3. Через 20 с (срок по умолчанию) TextEdit закрывается. `SAFENET_FAKE_OFFLINE=1` вместо
   `SAFENET_FAKE_IP`: заморожен, но не закрывается.
4. «Выйти из SafeNet» → всё замороженное оживает.

### 2.9 Сон и пробуждение
1. Включить защиту, добиться заморозки (тестовый режим), закрыть крышку/усыпить Mac на 1–2 минуты
   (дольше срока 20 с).
2. После пробуждения приложение НЕ должно оказаться закрытым из-за сна: идёт новая проверка и новый
   отсчёт. (Логика покрыта тестом `testSleepDoesNotConsumeGrace`; на железе не проверялась.)

### 2.10 Настоящий VPN (у вас и у друга)
1. Разрешить страну/IP VPN, включить VPN → «ок».
2. Выключить VPN → заморозка за доли секунды; включить обратно → разморозка после проверки.
3. Сменить сервер VPN на другую страну без отключения → заморозка в пределах интервала
   проверки (5 с по умолчанию).

### 2.11 Команда safenet
1. `sudo ln -s /Applications/SafeNet.app/Contents/Resources/safenet /usr/local/bin/safenet`
2. `safenet status`, `safenet allow`, `safenet allow NL`, `safenet panel`, `safenet config`,
   `safenet version` → русские ответы, коды выхода 0; при выключенном SafeNet `status` → «SafeNet не
   запущен…», код 3.

## 3. Прочее, не проверенное здесь
- arm64: только собран и подписан; запуск на Apple Silicon — пункт 2.1.5.
- Поведение на macOS 15/26 (Gatekeeper, объекты входа, внешний вид SwiftUI) — у друга.
- Проверка маршрута до ИИ-сервисов и IPv6 на настоящей сети с VPN — 2.10.
