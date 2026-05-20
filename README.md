# WinBuild

Автоматизована збірка кастомних інсталяційних ISO-образів **Windows 10 Pro** та **Windows 11 Pro** із попередньо інтегрованими програмами, драйверами та офлайн-оновленнями.

Кінцеві ISO — гібридні (UEFI + BIOS), збираються через `oscdimg` із Windows ADK.

## Що робить

- Монтує офіційний ISO Microsoft (будь-яка локаль)
- Видобуває Pro-редакцію з `install.esd` у `install.wim` (`Export-WindowsImage`)
- Монтує WIM (`Mount-WindowsImage`)
- Інтегрує всередину образу:
  - інсталятори у `C:\Setup\Apps\` (для подальшої інсталяції з `SetupComplete.cmd`)
  - драйвери офлайн (`Add-WindowsDriver -Recurse`)
  - портативні застосунки прямо у `Program Files (x86)` (за потреби)
  - ярлики на `C:\Users\Default\Desktop\` (з'являться у кожного нового користувача)
  - `SetupComplete.cmd` у `Windows\Setup\Scripts\`
- (Опційно) Інтегрує `.msu`-оновлення Microsoft через `Add-WindowsPackage`
- Зберігає WIM (`Dismount-WindowsImage -Save`)
- Збирає гібридний ISO через `oscdimg` (UDF 2.50, UEFI + BIOS)

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
2. Покласти інсталятори у `Assets\Apps\` — структура папок і файлів має відповідати тому, на що посилається `Assets\SetupComplete.cmd`. Скрипт `SetupComplete.cmd` написаний як **шаблон**: усі шляхи винесено у змінні на початку файлу, додайте/змініть кроки під свій набір ПЗ.
3. Покласти драйвери у `Assets\Drivers\` (будь-які `.inf`, шукаються рекурсивно).
4. (Опційно) Покласти `.msu`-оновлення у `Assets\Updates\Win10\` та `Assets\Updates\Win11\`.

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

- `Modified\Win10_Custom.iso`
- `Modified\Win11_Custom.iso`

Обидва — гібридні, завантажуються і з UEFI, і з BIOS. Тестувати рекомендується спочатку у віртуальній машині (Hyper-V, VirtualBox), потім на реальному залізі.

## Як це працює всередині (8 кроків)

1. **Монтування ISO** — `Mount-DiskImage`, очікування літери до 5 с
2. **Копіювання вмісту** — у `Work\<OutputName>\ISO`, знімається read-only
3. **Аналіз install.esd / install.wim** — `Get-WindowsImage`, пошук Pro за regex
4. **Експорт Pro у новий install.wim** — `Export-WindowsImage -CompressionType Maximum -CheckIntegrity`
5. **Монтування WIM** — `Mount-WindowsImage` у `Work\<OutputName>\Mount`
6. **Інтеграція вмісту** — `Apps\` → `C:\Setup\Apps`, `SetupComplete.cmd` → `Windows\Setup\Scripts\`, драйвери через `Add-WindowsDriver -Recurse`
7. **Розмонтування WIM з комітом** — `Dismount-WindowsImage -Save`
8. **Збірка ISO** — `oscdimg` із гібридним UEFI (`efi\microsoft\boot\efisys.bin`) + BIOS (`boot\etfsboot.com`), UDF 2.50, прапори `-m -o -h -u2 -udfver102`

При будь-якій помилці WIM розмонтовується з `-Discard`, ISO відмонтовується, у `Logs\` пишеться повний журнал із рівнями INFO/WARN/ERROR/OK.

## Підводні камені

- **Кодування скриптів.** `Build-CustomISO.ps1` має кириличні коментарі. Не переводити автоматично у UTF-8 без BOM — деякі редактори ламають кодування й логи стають нечитаними.
- **Win11 24H2/25H2 і `SetupComplete.cmd`.** У нових збірках Win11 змінено поведінку OOBE — класичний `SetupComplete.cmd` із `Windows\Setup\Scripts\` може не запускатися. Якщо так — частина ПЗ не встановиться. Перевіряйте лог `C:\Windows\Setup\Scripts\SetupComplete.log` після першого входу.
- **`SetupComplete.cmd` не падає при відсутності компонента.** Кожен крок має `if not exist` і `goto :NEXT_LABEL` — пропуск файлу не зупиняє всю інсталяцію.

## Офлайн-інтеграція Windows Update

`.msu`-пакети кладуться у `Assets\Updates\Win10\` та `Assets\Updates\Win11\`. Завантажувати з [catalog.update.microsoft.com](https://www.catalog.update.microsoft.com), архітектура **x64**, тип **Cumulative Update** (не Dynamic). SSU окремо не потрібен — з Win10 22H2 і Win11 23H2+ він вбудований у LCU.

## Ліцензія

[MIT](LICENSE)

Цей репозиторій містить лише скрипти збірки. Інсталятори програм, драйвери, оновлення Microsoft та офіційні ISO — **не входять у репо** і мають свої власні ліцензії правовласників.
