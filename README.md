<p align="center">
  <img src="docs/media/icon.png" width="96" height="96" alt="">
</p>

<h1 align="center">SafeNet</h1>

<p align="center">Защита приложений при смене IP или отключении VPN на macOS.</p>

<p align="center">
  <strong><a href="https://github.com/orleony/safenet/releases/latest">Скачать SafeNet для Mac ↓</a></strong>
  ·
  <a href="https://github.com/orleony/safenet/releases">Все версии</a>
  <br>
  macOS 13 и новее · Intel и Apple Silicon
</p>

<p align="center">
  <img src="docs/media/overview.webp" width="900" alt="Вкладка «Обзор» SafeNet. Видны внешний IP, страна и результаты проверок VPN, IPv6, DNS и маршрутов ИИ">
</p>

SafeNet живёт в строке меню и сверяет внешний IP и страну с вашими правилами. Если проверка не проходит, SafeNet приостанавливает выбранные приложения и возобновляет их после успешной проверки. Вы задаёте время ожидания и выбираете действие по таймеру. SafeNet может закрыть приложение, оставить его замороженным или возобновить.

## Установка и первый запуск

1. Откройте [последний релиз](https://github.com/orleony/safenet/releases/latest) и в разделе **Assets** скачайте `SafeNet-<версия>.zip`. Например, [SafeNet-1.0.7.zip](https://github.com/orleony/safenet/releases/download/v1.0.7/SafeNet-1.0.7.zip).
2. Распакуйте архив, перетащите `SafeNet.app` в «Программы» и запустите. Сборка подписана ad hoc, без нотаризации Apple. Если macOS запросит подтверждение, откройте «Системные настройки» → «Конфиденциальность и безопасность» → «Всё равно открыть». [Справка Apple](https://support.apple.com/en-us/102445)
3. Включите VPN. В меню SafeNet нажмите «Открыть панель» и добавьте разрешённые IP, подсети или страны во вкладке «Разрешено».
4. Во вкладке «Приложения» выберите, что защищать. SafeNet замораживает выбранные приложения с пустым списком разрешений и ждёт, пока вы добавите правило.

## Возможности

| Возможность | Как работает |
| --- | --- |
| **Правила для каждого приложения** | Готовые варианты для Claude, Claude Code, ChatGPT, Codex и других. Можно добавить своё приложение и задать ему отдельный список разрешений и время заморозки. |
| **Проверка сети** | Отдельное определение IP и страны, диагностика DNS и IPv6, проверка маршрутов до пяти ИИ-сервисов и признаки раздельной маршрутизации. |
| **Управление из строки меню** | Текущий IP или страна, пауза защиты, таймер заморозки и действия с приложениями. |
| **Журнал и настройки** | История событий и счётчики, доверенные сети, светлая, тёмная или системная тема, цвет акцента и часовой пояс журнала. |

## Скриншоты

Интерфейс SafeNet 1.0.7 с демонстрационными адресами и событиями.

| Приложения | Настройки защиты |
| :---: | :---: |
| <img src="docs/media/apps.webp" width="420" alt="Список приложений с переключателями защиты и отдельными правилами"> | <img src="docs/media/settings.webp" width="420" alt="Настройки времени заморозки, действия по таймеру и сетевых проверок"> |

<details>
<summary>Остальные вкладки, светлая тема и меню заморозки</summary>

| Разрешённые адреса и страны | Доверенные сети |
| :---: | :---: |
| <img src="docs/media/allowed.webp" width="420" alt="Разрешённые страны, IP-адреса и подсети"> | <img src="docs/media/networks.webp" width="420" alt="Данные текущей сети и список доверенных сетей"> |

| Результаты диагностики | Журнал событий |
| :---: | :---: |
| <img src="docs/media/check.webp" width="420" alt="Результаты проверки внешнего IPv4 и баз геолокации"> | <img src="docs/media/journal.webp" width="420" alt="Счётчики заморозок и закрытий, фильтры и журнал событий"> |

| Светлая тема | Меню во время заморозки |
| :---: | :---: |
| <img src="docs/media/settings-light.webp" width="420" alt="Настройки SafeNet в светлой теме"> | <img src="docs/media/menu.webp" width="236" alt="Меню SafeNet с обратным отсчётом до закрытия приложений"> |

</details>

## Как работает защита

SafeNet приостанавливает процессы после обнаружения сетевого события или смены IP. Если внешний адрес меняется без события macOS, SafeNet узнаёт об этом при очередной проверке. До неё приложение может успеть отправить трафик. Для блокировки трафика на уровне сети оставьте включённым kill switch вашего VPN. Системные приложения из `/System`, в том числе Safari, SafeNet пропускает.

Настройки и журнал хранятся на Mac. Приложение обращается к сервисам определения IP и страны, проверяет маршруты до поддерживаемых ИИ-сервисов и загружает обновления из GitHub Releases, если они включены. Телеметрии нет.

[Подробная инструкция](Resources/ПРОЧТИ-МЕНЯ.txt) · [Сборка и CLI](docs/development.md) · [Сообщить о проблеме](https://github.com/orleony/safenet/issues)

<details>
<summary>English quick start</summary>

SafeNet is a macOS 13+ menu-bar app that pauses selected apps when your external IP or country fails your rules. You can set a timeout and choose what happens when it expires.

Download `SafeNet-<version>.zip` from the [latest release](https://github.com/orleony/safenet/releases/latest) and move `SafeNet.app` to Applications. In the SafeNet panel, add your VPN addresses or countries under «Разрешено», then select the apps to protect under «Приложения». Keep your VPN's own kill switch enabled to block traffic at the network level.

</details>
