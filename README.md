# WinBuild

Автоматизована збірка кастомних інсталяційних ISO-образів **Windows 10 Pro** та **Windows 11 Pro** із попередньо інтегрованими програмами, драйверами та офлайн-оновленнями. Призначений для швидкого розгортання роздрібних робочих місць — касових ПК, POS-терміналів із фіскальними/етикетковими принтерами та сканерами штрих-кодів.

Кінцеві ISO — гібридні (UEFI + BIOS), збираються через `oscdimg` із Windows ADK.

## Що робить

- Монтує офіційний ISO Microsoft (uk-UA, en-US — будь-який)
- Видобуває Pro-редакцію з `install.esd` у `install.wim` (`Export-WindowsImage`)
- Монтує WIM (`Mount-WindowsImage`)
- Інтегрує всередину образу:
  - програми у `C:\Setup\Apps\` (для подальшої інсталяції з `SetupComplete.cmd`)
  - драйвери офлайн (`Add-WindowsDriver -Recurse`)
  - портативні застосунки прямо у `Program Files (x86)`
  - ярлики на `C:\Users\Default\Desktop\` (з'являться у кожного нового користувача)
  - `SetupComplete.cmd` у `Windows\Setup\Scripts\`
- Зберігає WIM (`Dismount-WindowsImage -Save`)
- Збирає гібридний ISO через `oscdimg` (UDF 2.50, UEFI + BIOS)

## Навіщо це потрібно (контекст Intune)

Кастомний ISO — це **перший етап** розгортання. Повний цикл:

1. **Інсталяція з кастомного ISO** — Windows ставиться разом із попередньо інтегрованими програмами і драйверами.
2. **OOBE + `SetupComplete.cmd`** — після першого входу під SYSTEM виконуються MSI-інсталяції, які залежать від OOBE-фази (наприклад, `ALLUSERS=1`).
3. **Реєстрація в Autopilot/Intune** — оператор знімає hardware hash із пристрою (`Get-WindowsAutopilotInfo`) і завантажує його у Microsoft Intune.
4. **Передача керування Intune** — далі вся політика, оновлення й моніторинг ідуть через MDM.

**Чому ПЗ ставиться через образ, а не повністю через Intune:** інсталяція великого набору програм через Win32-apps займає години (кожен пакет качається з хмари, ставиться послідовно, з ретраями). Інтеграція в образ дає готову машину одразу після першого входу — лишається тільки додати hash у Intune.

## Структура проекту

```
WinBuild/
├── Build-CustomISO.ps1        # Основний скрипт збірки (8 кроків)
├── Build-All.cmd              # Батник: послідовно Win10 + Win11
├── Origin/                    # Вихідні ISO Microsoft (не у репо)
│   ├── Windows10.iso
│   └── Windows11.iso
├── Modified/                  # Готові кастомні ISO (не у репо)
├── Logs/                      # Журнали збірки
├── Assets/
│   ├── SetupComplete.cmd      # Пост-OOBE скрипт (шаблон)
│   ├── Apps/                  # Інсталятори програм (не у репо)
│   ├── Drivers/               # Драйвери для офлайн-інтеграції (не у репо)
│   └── Updates/               # Пакети оновлень .msu (не у репо)
│       ├── Win10/
│       └── Win11/
└── Work/                      # Тимчасова папка збірки
```

Папки `Origin/`, `Modified/`, `Logs/`, `Work/`, `Assets/Apps/`, `Assets/Drivers/`, `Assets/Updates/` виключені через `.gitignore` — вони містять великі бінарники, ліцензійні інсталятори та артефакти збірки.

## Вимоги

- Windows 10/11 (хост для запуску збірки)
- Права адміністратора
- **Windows ADK (Deployment Tools)** — для `oscdimg.exe`
- PowerShell 5.1+
- Орієнтовно 60+ ГБ вільного місця (Work + Modified)
- Тривалість: ~25–30 хв на один ISO

## Підготовка перед першим запуском

1. Скопіювати офіційні ISO Microsoft у `Origin\`:
   - `Origin\Windows10.iso`
   - `Origin\Windows11.iso`
2. Покласти інсталятори у `Assets\Apps\` (структура очікувань — див. `Assets\SetupComplete.cmd`):
   - `Office365\setup.exe` + `configuration.xml` (Office Deployment Tool)
   - `1CEnterprise\` із MSI та MST-трансформаціями
   - `googlechromestandaloneenterprise64.msi`
   - `1CBarCode.exe` + `1CBarCode.iss`
   - `ScanOPOS\` із MSI
   - (опційно) `Foxit Software\` — портативна копія, інтегрується у `Program Files (x86)`
   - (опційно) `1C.lnk` — ярлик, інтегрується на Default Desktop
3. Покласти драйвери у `Assets\Drivers\` (будь-які .inf, шукаються рекурсивно)
4. (Опційно) Покласти `.msu`-оновлення у `Assets\Updates\Win10\` та `Assets\Updates\Win11\`

`SetupComplete.cmd` написаний як **шаблон**: імена підпапок і файлів винесено у змінні на початку файлу. Якщо у вас інші версії — змініть значення змінних, не переписуючи логіку.

## Як запускати

**Варіант 1 — батник (рекомендовано):**

```cmd
cd WinBuild
Build-All.cmd
```

Правий клік → Run as administrator.

**Варіант 2 — PowerShell вручну:**

```powershell
cd WinBuild
Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass -Force
.\Build-CustomISO.ps1 -SourceISO ".\Origin\Windows10.iso" -OutputName "Win10"
.\Build-CustomISO.ps1 -SourceISO ".\Origin\Windows11.iso" -OutputName "Win11"
```

Якщо в `install.esd` назва Pro-редакції не стандартна, можна задати її явно:

```powershell
.\Build-CustomISO.ps1 -SourceISO ".\Origin\Win11.iso" -OutputName "Win11" -ProEditionName "Windows 11 Pro"
```

## Результат

Після успішної збірки:

- `Modified\Win10_Custom.iso` (~5–6 ГБ)
- `Modified\Win11_Custom.iso` (~8–9 ГБ)

Обидва — гібридні, завантажуються і з UEFI, і з BIOS. Тестувати рекомендується спочатку у віртуальній машині (Hyper-V, VirtualBox), потім на реальному залізі.

## Як це працює всередині (8 кроків)

1. **Монтування ISO** — `Mount-DiskImage`, очікування літери до 5 с
2. **Копіювання вмісту** — у `Work\<OutputName>\ISO`, знімається read-only
3. **Аналіз install.esd / install.wim** — `Get-WindowsImage`, пошук Pro за regex
4. **Експорт Pro у новий install.wim** — `Export-WindowsImage -CompressionType Maximum -CheckIntegrity`
5. **Монтування WIM** — `Mount-WindowsImage` у `Work\<OutputName>\Mount`
6. **Інтеграція вмісту** — `Apps\` → `C:\Setup\Apps`, `SetupComplete.cmd` → `Windows\Setup\Scripts\`, драйвери через `Add-WindowsDriver -Recurse`, портативні застосунки у `Program Files (x86)`, ярлики на Default Desktop
7. **Розмонтування WIM з комітом** — `Dismount-WindowsImage -Save`
8. **Збірка ISO** — `oscdimg` із гібридним UEFI (`efi\microsoft\boot\efisys.bin`) + BIOS (`boot\etfsboot.com`), UDF 2.50, прапори `-m -o -h -u2 -udfver102`

При будь-якій помилці WIM розмонтовується з `-Discard`, ISO відмонтовується, у `Logs\` пишеться повний журнал із рівнями INFO/WARN/ERROR/OK.

## Підводні камені

- **Кодування скриптів.** `Build-CustomISO.ps1` і `SetupComplete.cmd` мають кириличні коментарі. Не переводити автоматично у UTF-8 без BOM — деякі редактори ламають кодування й логи стають нечитаними.
- **Win11 24H2/25H2 і `SetupComplete.cmd`.** У нових збірках Win11 змінено поведінку OOBE — класичний `SetupComplete.cmd` із `Windows\Setup\Scripts\` може не запускатися. Якщо так — частина ПЗ не встановиться, доведеться доставляти через Intune (а це і є та проблема, яку проект мав уникнути). Перевіряйте лог `C:\Windows\Setup\Scripts\SetupComplete.log` після першого входу.
- **1С 32-бітна.** Українська редакція 8.3.17 — типово `x86`, навіть на 64-бітних системах.
- **Foxit як портативна копія.** При інтеграції портативної копії Foxit Reader реєстрові асоціації PDF і ярлики у меню «Пуск» не створюються. За потреби — додати окремо через `SetupComplete.cmd`.
- **`SetupComplete.cmd` не падає при відсутності компонента.** Кожен крок має `if not exist` і `goto :NEXT_LABEL` — пропуск файлу не зупиняє всю інсталяцію.

## Офлайн-інтеграція Windows Update

`.msu`-пакети кладуться у `Assets\Updates\Win10\` та `Assets\Updates\Win11\`. Завантажувати з [catalog.update.microsoft.com](https://www.catalog.update.microsoft.com), архітектура **x64**, тип **Cumulative Update** (не Dynamic). SSU окремо не потрібен — з Win10 22H2 і Win11 23H2+ він вбудований у LCU.

## Ліцензія

[MIT](LICENSE)

Цей репозиторій містить лише скрипти збірки. Інсталятори програм (Office, 1С, Chrome тощо), драйвери, оновлення Microsoft та офіційні ISO — **не входять у репо** і мають свої власні ліцензії правовласників.
