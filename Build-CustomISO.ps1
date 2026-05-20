<#
.SYNOPSIS
    Автоматизована збірка кастомного ISO-образу Windows 10/11 PRO
    з інтеграцією програм та SetupComplete.cmd.

.DESCRIPTION
    Кроки збірки:
      1. Монтування вихідного ISO з папки Origin
      2. Копіювання вмісту у робочу папку
      3. Пошук PRO-редакції з install.esd у новий install.wim
      4. Монтування install.wim
      5. Інтеграція Apps та SetupComplete.cmd всередині образу
      6. Збереження та розмонтування образу
      7. Збірка фінального ISO через oscdimg.exe (UEFI + BIOS)

.PARAMETER SourceISO
    Шлях до вихідного інсталяційного ISO (наприклад, .\Origin\Win10.iso)

.PARAMETER OutputName
    Префікс імені для робочих папок та вихідного ISO (наприклад, Win10 або Win11)

.PARAMETER ProEditionName
    Назва PRO-редакції у install.esd. По замовчуванню "Windows 10 Pro" / "Windows 11 Pro"
    використовується автоматично, але можна задати вручну.

.EXAMPLE
    .\Build-CustomISO.ps1 -SourceISO ".\Origin\Win10.iso" -OutputName "Win10"
    .\Build-CustomISO.ps1 -SourceISO ".\Origin\Win11.iso" -OutputName "Win11"

.NOTES
    ЗАПУСКАТИ ВІД АДМІНІСТРАТОРА.
    Потрібен встановлений Windows ADK (для oscdimg.exe).
    Тривалість ~25-30 хв на один образ.
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$SourceISO,

    [Parameter(Mandatory = $true)]
    [string]$OutputName,

    [Parameter(Mandatory = $false)]
    [string]$ProEditionName = $null
)

# ============================================================================
# КОНФІГУРАЦІЯ
# ============================================================================

$ErrorActionPreference = 'Stop'
# ProgressPreference залишаємо дефолтний: для Copy-Item мовчимо, для DISM виводимо
# (у PS5 Copy-Item progress страшно гальмує, а DISM-прогрес є нативним)

# Лічильник прогресу кроків для прогрес-бару
$Script:TotalSteps  = 8
$Script:CurrentStep = 0

function Step-Progress {
    param(
        [Parameter(Mandatory = $true)][string]$Activity
    )
    $Script:CurrentStep++
    $percent = [int](($Script:CurrentStep / $Script:TotalSteps) * 100)
    Write-Progress -Id 0 -Activity "Збірка $OutputName" `
        -Status "[$Script:CurrentStep/$Script:TotalSteps] $Activity" `
        -PercentComplete $percent
}

function Complete-Progress {
    Write-Progress -Id 0 -Activity "Збірка $OutputName" -Completed
}

# Коренева папка проекту = папка де лежить сам скрипт (не залежить від поточної папки)
$RootDir = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent (Resolve-Path $MyInvocation.MyCommand.Path) }

$AssetsDir  = Join-Path $RootDir 'Assets'
$AppsDir    = Join-Path $AssetsDir 'Apps'
$DriversDir = Join-Path $AssetsDir 'Drivers'
$SetupCmd   = Join-Path $AssetsDir 'SetupComplete.cmd'

$WorkDir     = Join-Path $RootDir 'Work'
$ModifiedDir = Join-Path $RootDir 'Modified'

$ProjectWork = Join-Path $WorkDir $OutputName
$IsoExtract  = Join-Path $ProjectWork 'ISO'
$MountDir    = Join-Path $ProjectWork 'Mount'

$LogDir  = Join-Path $RootDir 'Logs'
$LogFile = Join-Path $LogDir ("Build_{0}_{1:yyyyMMdd_HHmmss}.log" -f $OutputName, (Get-Date))

# ============================================================================
# ФУНКЦІЇ ВИВЕДЕННЯ ТА ВАЛІДАЦІЇ
# ============================================================================

function Write-Log {
    param(
        [Parameter(Mandatory = $true)][string]$Message,
        [ValidateSet('INFO', 'WARN', 'ERROR', 'OK')][string]$Level = 'INFO'
    )
    $timestamp = Get-Date -Format 'yyyy-MM-dd HHmmss'
    $line      = "[$timestamp] [$Level] $Message"

    switch ($Level) {
        'ERROR' { Write-Host $line -ForegroundColor Red }
        'WARN'  { Write-Host $line -ForegroundColor Yellow }
        'OK'    { Write-Host $line -ForegroundColor Green }
        default { Write-Host $line -ForegroundColor Cyan }
    }
    Add-Content -Path $LogFile -Value $line -Encoding UTF8 -ErrorAction SilentlyContinue
}

function Test-Administrator {
    $current   = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($current)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Find-Oscdimg {
    # Стандартні шляхи Windows ADK
    $candidates = @(
        "${env:ProgramFiles(x86)}\Windows Kits\10\Assessment and Deployment Kit\Deployment Tools\amd64\Oscdimg\oscdimg.exe",
        "${env:ProgramFiles}\Windows Kits\10\Assessment and Deployment Kit\Deployment Tools\amd64\Oscdimg\oscdimg.exe",
        "${env:ProgramFiles(x86)}\Windows Kits\10\Assessment and Deployment Kit\Deployment Tools\x86\Oscdimg\oscdimg.exe"
    )
    foreach ($path in $candidates) {
        if (Test-Path $path) { return $path }
    }
    return $null
}

# ============================================================================
# ПЕРЕВІРКИ ПЕРЕДУМОВ
# ============================================================================

# Створюємо папку логу
New-Item -ItemType Directory -Path $LogDir -Force | Out-Null

Write-Log "Ім'я збірки: $OutputName" -Level 'INFO'
Write-Log "Папка проекту: $RootDir" -Level 'INFO'

if (-not (Test-Administrator)) {
    Write-Log "Скрипт треба запускати від адміністратора." -Level 'ERROR'
    exit 1
}

if (-not (Test-Path $SourceISO)) {
    Write-Log "Не знайдено вихідний ISO: $SourceISO" -Level 'ERROR'
    exit 1
}

# Нормалізуємо до абсолютного шляху, бо Mount-DiskImage не любить відносні шляхи
$SourceISO = (Resolve-Path -LiteralPath $SourceISO).ProviderPath
Write-Log "Абсолютний шлях до ISO: $SourceISO" -Level 'INFO'

if (-not (Test-Path $AppsDir)) {
    Write-Log "Не знайдено папку програм: $AppsDir" -Level 'ERROR'
    exit 1
}

if (-not (Test-Path $SetupCmd)) {
    Write-Log "Не знайдено SetupComplete.cmd: $SetupCmd" -Level 'ERROR'
    exit 1
}

$Oscdimg = Find-Oscdimg
if (-not $Oscdimg) {
    Write-Log "Не знайдено oscdimg.exe. Встановіть Windows ADK (Deployment Tools)." -Level 'ERROR'
    exit 1
}
Write-Log "Знайдено oscdimg: $Oscdimg" -Level 'OK'

# ============================================================================
# ПІДГОТОВКА РОБОЧОЇ ПАПКИ
# ============================================================================

Write-Log "Підготовка робочої папки..." -Level 'INFO'

# Якщо залишились сміття з минулої перерваної збірки — очищаємо
if (Test-Path $MountDir) {
    try {
        Write-Log "Знайдено залишки минулої збірки. Скидаємо WIM без збереження..." -Level 'WARN'
        Dismount-WindowsImage -Path $MountDir -Discard -ErrorAction SilentlyContinue | Out-Null
    } catch { }
}

# Якщо ISO залишився змонтованим від попереднього запуску
try {
    $existingMount = Get-DiskImage -ImagePath $SourceISO -ErrorAction SilentlyContinue
    if ($existingMount -and $existingMount.Attached) {
        Write-Log "Знайдено змонтований ISO від минулої збірки. Відмонтовуємо..." -Level 'WARN'
        Dismount-DiskImage -ImagePath $SourceISO -ErrorAction SilentlyContinue | Out-Null
    }
} catch { }

# Очищаємо папку робочої збірки
if (Test-Path $ProjectWork) {
    Write-Log "Очищаємо папку робочої збірки: $ProjectWork" -Level 'INFO'
    Remove-Item -Path $ProjectWork -Recurse -Force -ErrorAction SilentlyContinue
}

New-Item -ItemType Directory -Path $IsoExtract  -Force | Out-Null
New-Item -ItemType Directory -Path $MountDir    -Force | Out-Null
New-Item -ItemType Directory -Path $ModifiedDir -Force | Out-Null

# ============================================================================
# КРОК 1-2: МОНТУВАННЯ ISO ТА КОПІЮВАННЯ
# ============================================================================

Write-Log "=== Крок 1-2 монтування та копіювання ISO ===" -Level 'INFO'
Step-Progress "Монтування вихідного ISO"

$mountedImage = $null
try {
    $mountedImage = Mount-DiskImage -ImagePath $SourceISO -PassThru -ErrorAction Stop

    # Іноді Get-Volume повертає $null одразу після монтування — чекаємо до 5 секунд через цикл
    $driveLetter = $null
    for ($i = 0; $i -lt 10; $i++) {
        Start-Sleep -Milliseconds 500
        $vol = $mountedImage | Get-Volume -ErrorAction SilentlyContinue
        if ($vol -and $vol.DriveLetter) {
            $driveLetter = $vol.DriveLetter
            break
        }
    }

    if (-not $driveLetter) {
        throw "Не вдалось отримати літеру диску для змонтованого ISO (10 спроб)"
    }

    $sourcePath = "${driveLetter}:\"
    Write-Log "ISO змонтовано на ${driveLetter}:" -Level 'OK'

    Write-Log "Копіюємо файли ISO до $IsoExtract ..." -Level 'INFO'
    Step-Progress "Копіювання файлів ISO"

    # Без прогрес-бару Copy-Item (він страшно гальмує у PS5)
    Copy-Item -Path (Join-Path $sourcePath '*') -Destination $IsoExtract -Recurse -Force -ErrorAction Stop

    Write-Log "Копіювання завершено." -Level 'OK'
}
catch {
    Write-Log "Помилка: $_" -Level 'ERROR'
    throw
}
finally {
    # Відмонтовуємо ISO ОДРАЗУ після копіювання (до будь-яких подальших кроків)
    if ($mountedImage) {
        Dismount-DiskImage -ImagePath $SourceISO -ErrorAction SilentlyContinue | Out-Null
        Write-Log "Вихідний ISO відмонтовано." -Level 'INFO'
    }
}

# Знімаємо атрибут "тільки для читання" з усіх скопійованих файлів
Get-ChildItem -Path $IsoExtract -Recurse -File | ForEach-Object {
    if ($_.IsReadOnly) { $_.IsReadOnly = $false }
}

# ============================================================================
# КРОК 3: ВИЗНАЧЕННЯ ДЖЕРЕЛА ОБРАЗУ (ESD або WIM) ТА ПОШУК PRO
# ============================================================================

Write-Log "=== Крок 3: пошук PRO-редакції ===" -Level 'INFO'

$sourcesDir = Join-Path $IsoExtract 'sources'
$installEsd = Join-Path $sourcesDir 'install.esd'
$installWim = Join-Path $sourcesDir 'install.wim'

if (Test-Path $installEsd) {
    $sourceImage = $installEsd
    $sourceType  = 'ESD'
} elseif (Test-Path $installWim) {
    $sourceImage = $installWim
    $sourceType  = 'WIM'
} else {
    Write-Log "Не знайдено install.esd або install.wim у sources" -Level 'ERROR'
    exit 1
}

Write-Log "Джерело образу: $sourceImage ($sourceType)" -Level 'INFO'

# Отримуємо список редакцій
$images = Get-WindowsImage -ImagePath $sourceImage
Write-Log "Знайдено редакцій: $($images.Count)" -Level 'INFO'
$images | ForEach-Object { Write-Log "  [$($_.ImageIndex)] $($_.ImageName)" -Level 'INFO' }

# Шукаємо PRO (лише точна назва, щоб не впасти на Pro N, Pro for Workstations тощо)
if ($ProEditionName) {
    $proImage = $images | Where-Object { $_.ImageName -eq $ProEditionName }
} else {
    $proImage = $images | Where-Object { $_.ImageName -match '^Windows (10|11) Pro$' }
}

if (-not $proImage) {
    Write-Log "PRO-редакція не знайдена. Вкажіть параметр -ProEditionName." -Level 'ERROR'
    exit 1
}

Write-Log "Обрано: [$($proImage.ImageIndex)] $($proImage.ImageName)" -Level 'OK'

# ============================================================================
# КРОК 4 (тривалий): КОНВЕРТАЦІЯ ESD -> WIM (тільки PRO індекс)
# ============================================================================

Write-Log "=== Крок 4: експорт PRO у install.wim ===" -Level 'INFO'
Step-Progress "Експорт PRO-редакції (це довго, чекай ~5-15 хв)"

$newWim = Join-Path $sourcesDir 'install.wim.new'
if (Test-Path $newWim) { Remove-Item $newWim -Force }

# Cmdlet підтягує Write-Progress — бачимо прогрес нативно
Export-WindowsImage `
    -SourceImagePath      $sourceImage `
    -SourceIndex          $proImage.ImageIndex `
    -DestinationImagePath $newWim `
    -CompressionType      Maximum `
    -CheckIntegrity | Out-Null

Write-Log "Експорт завершено." -Level 'OK'

# Видаляємо оригінальний install.esd/install.wim
Remove-Item $sourceImage -Force
# Перейменовуємо новий у install.wim
Move-Item -Path $newWim -Destination $installWim -Force
Write-Log "Образ перейменовано у install.wim" -Level 'OK'

# ============================================================================
# КРОК 4 (фін) - 5: МОНТУВАННЯ WIM ТА ІНТЕГРАЦІЯ ВМІСТУ
# ============================================================================

Write-Log "=== Крок 4-5: монтування WIM та інтеграція вмісту ===" -Level 'INFO'
Step-Progress "Монтування WIM"

Mount-WindowsImage -ImagePath $installWim -Index 1 -Path $MountDir | Out-Null
Write-Log "WIM змонтовано у $MountDir" -Level 'OK'

try {
    # --- 5.1 Копіюємо програми у C:\Setup\Apps всередині образу ---
    $targetApps = Join-Path $MountDir 'Setup\Apps'
    New-Item -ItemType Directory -Path $targetApps -Force | Out-Null

    Write-Log "Копіюємо програми з $AppsDir у образ..." -Level 'INFO'
    Step-Progress "Копіювання програм у образ"

    Copy-Item -Path (Join-Path $AppsDir '*') -Destination $targetApps -Recurse -Force -ErrorAction Stop
    Write-Log "Програми скопійовано." -Level 'OK'

    # --- 5.2 Копіюємо SetupComplete.cmd у Windows\Setup\Scripts ---
    $targetScripts = Join-Path $MountDir 'Windows\Setup\Scripts'
    New-Item -ItemType Directory -Path $targetScripts -Force | Out-Null
    Copy-Item -Path $SetupCmd -Destination (Join-Path $targetScripts 'SetupComplete.cmd') -Force
    Write-Log "SetupComplete.cmd скопійовано." -Level 'OK'

    # --- 5.2.1 Foxit Reader (портативний) у Program Files (x86) ---
    $foxitSrc = Join-Path $AppsDir 'Foxit Software'
    $foxitDst = Join-Path $MountDir 'Program Files (x86)\Foxit Software'
    if (Test-Path $foxitSrc) {
        Write-Log "Інтегруємо Foxit Reader у Program Files (x86)..." -Level 'INFO'
        New-Item -ItemType Directory -Path $foxitDst -Force | Out-Null
        Copy-Item -Path (Join-Path $foxitSrc '*') -Destination $foxitDst -Recurse -Force
        Write-Log "Foxit Reader інтегровано." -Level 'OK'
    } else {
        Write-Log "Foxit Software не знайдено у Apps, пропускаємо." -Level 'WARN'
    }

    # --- 5.2.2 Ярлик 1C на робочий стіл Default-профілю ---
    $lnkSrc = Join-Path $AppsDir '1C.lnk'
    $defaultDesktop = Join-Path $MountDir 'Users\Default\Desktop'
    if (Test-Path $lnkSrc) {
        Write-Log "Копіюємо ярлик 1C на Default Desktop..." -Level 'INFO'
        New-Item -ItemType Directory -Path $defaultDesktop -Force | Out-Null
        Copy-Item -Path $lnkSrc -Destination (Join-Path $defaultDesktop '1C.lnk') -Force
        Write-Log "Ярлик 1C скопійовано." -Level 'OK'
    } else {
        Write-Log "1C.lnk не знайдено у Apps, пропускаємо." -Level 'WARN'
    }

    # --- 5.3 Офлайн-інтеграція драйверів ---
    if (Test-Path $DriversDir) {
        $infFiles = Get-ChildItem -Path $DriversDir -Filter '*.inf' -Recurse
        if ($infFiles.Count -gt 0) {
            $infCount = $infFiles.Count
            Write-Log "Інтегруємо драйвери з $DriversDir ($infCount .inf файлів)..." -Level 'INFO'
            Step-Progress "Інтеграція драйверів"
            Add-WindowsDriver -Path $MountDir -Driver $DriversDir -Recurse | Out-Null
            Write-Log "Драйвери інтегровано." -Level 'OK'
        } else {
            Write-Log "Папка Drivers порожня, пропускаємо." -Level 'WARN'
        }
    } else {
        Write-Log "Папка Drivers не знайдена, пропускаємо." -Level 'INFO'
    }

    # ПРИМІТКА: інтеграція Windows Update (.msu) винесена у окремий скрипт
    # Update-CustomISO.ps1 — він накладає оновлення на готовий ISO у Modified\.
    # Тут лишається тільки ПЗ + драйвери.
}
catch {
    Write-Log "Помилка під час інтеграції вмісту: $_" -Level 'ERROR'
    Write-Log "Скидаємо WIM без збереження..." -Level 'WARN'
    Dismount-WindowsImage -Path $MountDir -Discard -ErrorAction SilentlyContinue | Out-Null
    throw
}

# ============================================================================
# КРОК 6: ЗБЕРЕЖЕННЯ ТА РОЗМОНТУВАННЯ ОБРАЗУ
# ============================================================================

Write-Log "=== Крок 6: збереження змін у WIM ===" -Level 'INFO'
Step-Progress "Збереження WIM (commit, ~3-10 хв)"

Dismount-WindowsImage -Path $MountDir -Save | Out-Null
Write-Log "Зміни збережено, образ розмонтовано." -Level 'OK'

# ============================================================================
# КРОК 7-10: ЗБІРКА ФІНАЛЬНОГО ISO
# ============================================================================

Write-Log "=== Крок 7-10: збірка фінального ISO ===" -Level 'INFO'
Step-Progress "Збірка фінального ISO"

# Файли завантажувача для гібридного UEFI+BIOS ISO
$etfsBoot = Join-Path $IsoExtract 'boot\etfsboot.com'               # BIOS
$efiBoot  = Join-Path $IsoExtract 'efi\microsoft\boot\efisys.bin'   # UEFI

if (-not (Test-Path $etfsBoot)) { Write-Log "Не знайдено $etfsBoot" -Level 'ERROR'; exit 1 }
if (-not (Test-Path $efiBoot))  { Write-Log "Не знайдено $efiBoot"  -Level 'ERROR'; exit 1 }

$outputISO = Join-Path $ModifiedDir "${OutputName}_Custom.iso"
if (Test-Path $outputISO) { Remove-Item $outputISO -Force }

# Параметри oscdimg:
#   -m           образ без ліміту розміру (>4.7 ГБ дозволено)
#   -o           оптимізація (дублікати об'єднані)
#   -h           приховані файли включаються
#   -u2          UDF 2.50
#   -udfver102   додаткова сумісність разом з -u2
#   -bootdata    мультизавантажувальні boot-сектори (BIOS + UEFI)
#   -l           мітка тому
$bootData    = "2#p0,e,b`"$etfsBoot`"#pEF,e,b`"$efiBoot`""
$volumeLabel = "${OutputName}_CUSTOM"

Write-Log "Запускаємо oscdimg..." -Level 'INFO'
$oscArgs = @(
    "-m",
    "-o",
    "-h",
    "-u2",
    "-udfver102",
    "-bootdata:$bootData",
    "-l$volumeLabel",
    $IsoExtract,
    $outputISO
)

# oscdimg пише вивід у stderr — PS5 вважає це помилкою.
# Тимчасово вимикаємо Stop лише для цього виклику.
$oldEAP = $ErrorActionPreference
$ErrorActionPreference = 'Continue'
try {
    & $Oscdimg @oscArgs 2>&1 | ForEach-Object {
        if ($_ -is [System.Management.Automation.ErrorRecord]) {
            Write-Host $_.Exception.Message
        } else {
            Write-Host $_
        }
    }
    $exitCode = $LASTEXITCODE
}
finally {
    $ErrorActionPreference = $oldEAP
}

if ($exitCode -ne 0) {
    Write-Log "oscdimg завершився з помилкою (код $exitCode)." -Level 'ERROR'
    Complete-Progress
    exit 1
}

if (-not (Test-Path $outputISO)) {
    Write-Log "ISO не створено, хоча oscdimg вийшов з кодом 0." -Level 'ERROR'
    exit 1
}

$sizeMB = [math]::Round((Get-Item $outputISO).Length / 1MB, 2)
Write-Log "Готово! $outputISO ($sizeMB МБ)" -Level 'OK'

# ============================================================================
# ОЧИЩЕННЯ
# ============================================================================

Write-Log "Очищення тимчасових папок..." -Level 'INFO'
if (Test-Path $WorkDir) {
    Remove-Item -Path $WorkDir -Recurse -Force -ErrorAction SilentlyContinue
    Write-Log "Папка Work очищена." -Level 'INFO'
}

Complete-Progress
Write-Log "Збірку завершено успішно." -Level 'OK'
