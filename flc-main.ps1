# flc-main.ps1 - Fake Location CLI for iPhone (Windows, portable)
# Powered by pymobiledevice3. English-only UI for portability.
#
# Internal engine. The supported entry point is flc.cmd, which sets FLC_ARGS from
# the raw command line (so short switches like -i/-s are never mistaken for
# PowerShell common parameters). If this script is run directly
# (powershell -File flc-main.ps1 ...), we fall back to the literal $args tokens.
#
# Layout (all downloaded/runtime dependencies live under assets\):
#   flc.cmd, flc-main.ps1, flc_*.py, requirements.txt, README*
#   data\ logs\
#   assets\
#     dist\                 build materials downloaded by "flc configure"
#       python-<ver>.nupkg    official python.org NuGet package
#       wheels\               pinned dependency wheels (offline build)
#     python\               minimal runtime built by "flc make"
#     drivers\*.msi          offline Apple USB driver
#     ddi\                   offline Developer Disk Image
#
# Lifecycle:
#   flc configure   download all official materials into assets\ (idempotent)
#   flc make        build the minimal runtime from those materials (offline)
#   flc make update [gitee|github]   update program sources to the latest
#   flc make clean  remove assets\ (sources only)
#   flc make install [--prefix=PATH]   copy (optional) + add to user PATH
#   flc make uninstall                 remove from PATH (+ optionally delete)

# Parse the raw command line passed by flc.cmd via FLC_ARGS.
$CliArgs = @()
if ($env:FLC_ARGS) {
    $tokens = $null; $perr = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseInput($env:FLC_ARGS, [ref]$tokens, [ref]$perr)
    foreach ($t in $tokens) {
        if ($t.Kind -in @('Generic','Identifier','Number','StringLiteral','Parameter','StringExpandable','Variable')) {
            if ($t.Extent.Text -ne $null -and $t.Extent.Text -ne '') {
                $v = $t.Extent.Text
                if ($v.StartsWith('"') -and $v.EndsWith('"')) { $v = $v.Substring(1,$v.Length-2) }
                $CliArgs += $v
            }
        }
    }
}
elseif ($args -and $args.Count -gt 0) {
    foreach ($a in $args) { $CliArgs += [string]$a }
}

$ErrorActionPreference = 'Continue'
$OutputEncoding = [System.Text.Encoding]::UTF8
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch {}
$env:NO_COLOR = '1'
$env:PYTHONIOENCODING = 'utf-8'

# ---- locate everything relative to this script ----
$ROOT        = $PSScriptRoot
$ASSETS      = Join-Path $ROOT 'assets'
$DIST        = Join-Path $ASSETS 'dist'
$WHEELS      = Join-Path $DIST 'wheels'
$PYDIR       = Join-Path $ASSETS 'python'
$PY          = Join-Path $PYDIR 'python.exe'
$DRIVERDIR   = Join-Path $ASSETS 'drivers'
$DRIVERMSI   = Join-Path $DRIVERDIR 'AppleMobileDeviceSupport64.msi'
$DDIDIR      = Join-Path $ASSETS 'ddi'
$DATADIR     = Join-Path $ROOT 'data'
$LOGDIR      = Join-Path $ROOT 'logs'
$DDISCRIPT   = Join-Path $ROOT 'flc_ddi.py'
$LOGFILE     = Join-Path $LOGDIR 'flc.log'
$REQUIREMENTS = Join-Path $ROOT 'requirements.txt'

$AMDS_SERVICE = 'Apple Mobile Device Service'
$DRIVER_URL   = 'https://swcdn.apple.com/content/downloads/20/49/047-76422/qcw2a7028lr8yp4rdkrfyzkvlhi9q1gg2g/AppleMobileDeviceSupport64.msi'
$DRIVER_SHA   = 'b60533fb54e7bd81ffc52d99678a9cce04e58cb54a76281bd7b1309f20d360e9'
$TUNNELD_PORT = 49151

$PY_VERSION = '3.12.10'
$NUPKG      = Join-Path $DIST ("python-" + $PY_VERSION + ".nupkg")
$NUGET_PY_MIRRORS = @(
    'https://www.nuget.org/api/v2/package/python/3.12.10'
)
$PIP_MIRROR = 'https://pypi.tuna.tsinghua.edu.cn/simple'

if (-not (Test-Path $DATADIR)) { New-Item -ItemType Directory -Force -Path $DATADIR | Out-Null }
if (-not (Test-Path $LOGDIR))  { New-Item -ItemType Directory -Force -Path $LOGDIR  | Out-Null }

function Log($msg) {
    try {
        if (-not (Test-Path $LOGDIR)) { New-Item -ItemType Directory -Force -Path $LOGDIR | Out-Null }
        $line = ('{0}  {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $msg)
        Add-Content -Path $LOGFILE -Value $line -ErrorAction SilentlyContinue
    } catch {}
}

function Test-Admin {
    return ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

# Relaunch this same script elevated (UAC). The elevated window stays open.
function Normalize-PathEntries([string]$s) {
    if (-not $s) { return @() }
    return @($s -split ';' | ForEach-Object { ($_ -replace '[\x00-\x1F]','').Trim() } | Where-Object { $_ })
}

function Invoke-Elevated {
    param([string[]]$ForwardArgs)
    if (Test-Admin) { return $false }
    # Reconstruct the raw command line the elevated window should run. Prefer the
    # exact string the launcher received; otherwise join the parsed tokens.
    $raw = $env:FLC_ARGS
    if (-not $raw) {
        $raw = ($ForwardArgs | ForEach-Object {
            if ($_ -match '[\s"]') { '"' + ($_ -replace '"','\"') + '"' } else { $_ }
        }) -join ' '
    }
    # Embed as single-quoted literals, then Base64 (UTF-16LE) the whole command so
    # UAC/Start-Process can never drop or re-quote embedded quotes/spaces.
    $rawLit  = "'" + ($raw -replace "'", "''") + "'"
    $pathLit = "'" + ($PSCommandPath -replace "'", "''") + "'"
    $inner = "`$env:FLC_ARGS = $rawLit; & $pathLit"
    $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($inner))
    Write-Host 'This action needs administrator rights. Approve the UAC prompt (click Yes)...'
    try {
        Start-Process -FilePath 'powershell.exe' -Verb RunAs -ArgumentList @('-NoProfile','-ExecutionPolicy','Bypass','-NoExit','-EncodedCommand',$encoded) | Out-Null
    } catch {
        Write-Host ('ERROR: elevation failed or was cancelled: ' + $_.Exception.Message)
    }
    return $true
}

# Run a flc command elevated and WAIT for it (the elevated window closes itself).
# Output is mirrored to logs\elevated-setup.log. Returns $false if the user cancels UAC.
function Invoke-ElevatedWait($rawCmd) {
    $rawLit  = "'" + ($rawCmd -replace "'", "''") + "'"
    $pathLit = "'" + ($PSCommandPath -replace "'", "''") + "'"
    $logLit  = "'" + ((Join-Path $LOGDIR 'elevated-setup.log') -replace "'", "''") + "'"
    $inner = "`$env:FLC_ARGS = $rawLit; & $pathLit *>&1 | Tee-Object -FilePath $logLit"
    $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($inner))
    try {
        $null = Start-Process -FilePath 'powershell.exe' -Verb RunAs -Wait -PassThru `
            -ArgumentList @('-NoProfile','-ExecutionPolicy','Bypass','-EncodedCommand',$encoded)
        return $true
    } catch {
        Write-Host ('UAC was cancelled or elevation failed: ' + $_.Exception.Message)
        return $false
    }
}

function Test-DriverInstalled {
    $svc = Get-Service -Name $AMDS_SERVICE -ErrorAction SilentlyContinue
    if ($svc) { return $true }
    $reg = Get-ItemProperty 'HKLM:\SOFTWARE\Apple Inc.\Apple Mobile Device Support' -ErrorAction SilentlyContinue
    return [bool]$reg
}

function Get-ConnectedDevices {
    if (-not (Test-Path $PY)) { return $null }
    $raw = & $PY -m pymobiledevice3 --no-color usbmux list 2>$null
    $json = ($raw -join "`n").Trim()
    try { $list = $json | ConvertFrom-Json } catch { return $null }
    if (-not $list) { return $null }
    return @($list)
}

# Runs automatically at the end of "make install": install the Apple USB driver
# (one UAC prompt), cache the offline DDI, and (if a phone is connected) put the
# DDI on the phone - so no separate "drivers install" / "ddi install" is needed.
function Invoke-PostInstallSetup {
    Write-Host ''
    Write-Host '=== Automatic setup: USB driver + Developer Disk Image ==='

    Write-Host '[1/2] Apple Mobile Device Support (USB driver)...'
    if (Test-DriverInstalled) {
        Write-Host '      already installed.'
        $svc = Get-Service -Name $AMDS_SERVICE -ErrorAction SilentlyContinue
        if ($svc -and $svc.Status -ne 'Running') {
            try { Start-Service -Name $AMDS_SERVICE -ErrorAction Stop; Start-Sleep -Seconds 1 } catch {}
        }
    }
    elseif (-not (Test-Path $DRIVERMSI)) {
        Write-Host '      installer missing in assets\drivers. Run "flc configure" then "flc make"; skipping.'
    }
    elseif (Test-Admin) {
        Install-Drivers
    }
    else {
        Write-Host '      The Apple USB driver is needed. Approve the UAC prompt (click Yes)...'
        $null = Invoke-ElevatedWait 'drivers install'
        if (Test-DriverInstalled) { Write-Host '      Apple Mobile Device Support installed.' }
        else {
            Write-Host '      Driver install did not complete. Finish it later with: flc drivers install'
            Write-Host '      (elevated log: logs\elevated-setup.log)'
        }
    }

    Write-Host '[2/2] Offline Developer Disk Image...'
    if (Test-Path $DDIDIR) {
        & $PY -u $DDISCRIPT sync
    } else {
        Write-Host '      assets\ddi missing. Run "flc configure" to download it; otherwise the first "flc set" fetches it online.'
    }

    if (Test-DriverInstalled) {
        $devs = Get-ConnectedDevices
        if ($devs -and $devs.Count -gt 0) {
            Write-Host 'A connected iPhone was detected; installing the DDI on the device...'
            & $PY -u $DDISCRIPT install
            if ($LASTEXITCODE -ne 0) {
                Write-Host '      DDI-to-device step did not finish now; it runs automatically on the first "flc set".'
            }
        } else {
            Write-Host 'No iPhone connected yet. After you connect and trust the phone, the first "flc set" installs the DDI automatically.'
        }
    }
    Write-Host '=== Automatic setup finished ==='
    Write-Host ''
}

function Invoke-Py {
    param([string[]]$PyArgs, [switch]$NoColor)
    $all = @('-m','pymobiledevice3')
    if ($NoColor) { $all += '--no-color' }
    $all += $PyArgs
    & $PY @all
}

# ---------------- configure / make ----------------

# Extract the NuGet nupkg's tools\ tree into a fresh temp folder; return its path.
function New-StagePython {
    if (-not ((Test-Path $NUPKG) -and (Get-Item $NUPKG).Length -gt 1MB)) {
        Write-Host 'ERROR: NuGet package missing in assets\dist. Run "flc configure".'
        return $null
    }
    $stage = Join-Path $env:TEMP ('flc-stage-' + [guid]::NewGuid().ToString('N').Substring(0,8))
    New-Item -ItemType Directory -Force -Path $stage | Out-Null
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $z = [System.IO.Compression.ZipFile]::OpenRead($NUPKG)
    foreach ($e in $z.Entries) {
        if ($e.FullName -notlike 'tools/*') { continue }
        $rel = $e.FullName.Substring(6)
        if ([string]::IsNullOrEmpty($rel)) { continue }
        $dest = Join-Path $stage ($rel -replace '/', '\')
        if ($e.FullName.EndsWith('/')) { New-Item -ItemType Directory -Force -Path $dest | Out-Null }
        else {
            $d = Split-Path $dest -Parent
            if (-not (Test-Path $d)) { New-Item -ItemType Directory -Force -Path $d | Out-Null }
            [System.IO.Compression.ZipFileExtensions]::ExtractToFile($e, $dest, $true)
        }
    }
    $z.Dispose()
    if (Test-Path (Join-Path $stage 'python.exe')) { return $stage }
    Write-Host 'ERROR: could not stage python from the NuGet package.'
    return $null
}

function Test-DdiComplete {
    if (-not (Test-Path $DDIDIR)) { return $false }
    $rel = @(
        'Xcode_iOS_DDI_Personalized\Image.dmg','Xcode_iOS_DDI_Personalized\BuildManifest.plist','Xcode_iOS_DDI_Personalized\Image.trustcache',
        'Xcode_iOS_DDI_Cryptex\Image.dmg','Xcode_iOS_DDI_Cryptex\BuildManifest.plist','Xcode_iOS_DDI_Cryptex\Image.dmg.trustcache',
        'Xcode_iOS_DDI_Cryptex\Image.dmg.cryptex_info','Xcode_iOS_DDI_Cryptex\Image.dmg.root_hash'
    )
    foreach ($r in $rel) {
        $p = Join-Path $DDIDIR $r
        if (-not (Test-Path $p)) { return $false }
        $len = (Get-Item $p).Length
        if ($len -le 0) { return $false }
        # the two DDI images are ~15 MB; a smaller file means a truncated download
        if ($r -like '*Image.dmg' -and $len -lt 1000000) { return $false }
    }
    return $true
}

# Download the 8 DDI files into assets\ddi (mirrored, resumes per file).
function Download-DdiFiles {
    $files = @(
        @{ P='PersonalizedImages/Xcode_iOS_DDI_Personalized/Image.dmg';            L='Xcode_iOS_DDI_Personalized\Image.dmg' },
        @{ P='PersonalizedImages/Xcode_iOS_DDI_Personalized/BuildManifest.plist';   L='Xcode_iOS_DDI_Personalized\BuildManifest.plist' },
        @{ P='PersonalizedImages/Xcode_iOS_DDI_Personalized/Image.dmg.trustcache';  L='Xcode_iOS_DDI_Personalized\Image.trustcache' },
        @{ P='PersonalizedImages/Xcode_iOS_DDI_Cryptex/Image.dmg';                 L='Xcode_iOS_DDI_Cryptex\Image.dmg' },
        @{ P='PersonalizedImages/Xcode_iOS_DDI_Cryptex/BuildManifest.plist';        L='Xcode_iOS_DDI_Cryptex\BuildManifest.plist' },
        @{ P='PersonalizedImages/Xcode_iOS_DDI_Cryptex/Image.dmg.trustcache';       L='Xcode_iOS_DDI_Cryptex\Image.dmg.trustcache' },
        @{ P='PersonalizedImages/Xcode_iOS_DDI_Cryptex/Image.dmg.cryptex_info';     L='Xcode_iOS_DDI_Cryptex\Image.dmg.cryptex_info' },
        @{ P='PersonalizedImages/Xcode_iOS_DDI_Cryptex/Image.dmg.root_hash';        L='Xcode_iOS_DDI_Cryptex\Image.dmg.root_hash' }
    )
    $mirrors = @(
        'https://raw.githubusercontent.com/doronz88/DeveloperDiskImage/main/{0}',
        'https://cdn.jsdelivr.net/gh/doronz88/DeveloperDiskImage@main/{0}',
        'https://fastly.jsdelivr.net/gh/doronz88/DeveloperDiskImage@main/{0}',
        'https://gh-proxy.com/https://raw.githubusercontent.com/doronz88/DeveloperDiskImage/main/{0}'
    )
    $ProgressPreference = 'SilentlyContinue'
    Write-Host 'Downloading the offline Developer Disk Image (~32 MB, mirrored)...'
    foreach ($f in $files) {
        $dest = Join-Path $DDIDIR $f.L
        $min = if ($f.L -like '*Image.dmg') { 1000000 } else { 1 }
        if ((Test-Path $dest) -and (Get-Item $dest).Length -ge $min) { continue }
        if (Test-Path $dest) { Remove-Item $dest -Force }
        New-Item -ItemType Directory -Force -Path (Split-Path $dest) | Out-Null
        $ok = $false
        foreach ($m in $mirrors) {
            $url = $m -f $f.P
            Write-Host ("  {0}  <- {1}" -f $f.L, $url)
            try { curl.exe -L --fail --retry 3 --retry-all-errors --connect-timeout 20 -s -o $dest $url } catch {}
            if ((Test-Path $dest) -and (Get-Item $dest).Length -ge $min) { $ok = $true; break }
            if (Test-Path $dest) { Remove-Item $dest -Force }
        }
        if (-not $ok) {
            Write-Host ("FAILED to download: {0}" -f $f.L)
            return $false
        }
    }
    return $true
}

# Download the Apple USB driver MSI into assets\drivers (hash-verified).
function Get-DriverMSI {
    if (Test-Path $DRIVERMSI) { return $true }
    Write-Host 'Downloading Apple Mobile Device Support from apple.com (~38 MB)...'
    if (-not (Test-Path $DRIVERDIR)) { New-Item -ItemType Directory -Force -Path $DRIVERDIR | Out-Null }
    $tmp = $DRIVERMSI + '.part'
    $ProgressPreference = 'SilentlyContinue'
    try { curl.exe -L --fail -s -o $tmp $DRIVER_URL } catch {}
    if (-not (Test-Path $tmp)) { Write-Host 'Download failed.'; return $false }
    $h = (Get-FileHash $tmp -Algorithm SHA256).Hash
    if ($h -ne $DRIVER_SHA) {
        Write-Host 'ERROR: downloaded driver hash does not match the official value.'
        Remove-Item $tmp -Force -ErrorAction SilentlyContinue
        return $false
    }
    Move-Item $tmp $DRIVERMSI -Force -ErrorAction Stop
    return $true
}

# configure: download every official material into assets\ (idempotent).
function Invoke-Configure {
    Write-Host '=== flc configure ==='
    Write-Host 'Downloading all runtime dependencies from official sources into assets\.'
    Write-Host 'Items already present and complete are skipped.'
    Write-Host ''
    New-Item -ItemType Directory -Force -Path $DIST | Out-Null
    $ok = $true

    # 1) official NuGet python package
    if ((Test-Path $NUPKG) -and (Get-Item $NUPKG).Length -gt 1MB) {
        Write-Host '[skip] Official python NuGet package already present.'
    } else {
        Write-Host ("Downloading official python.org NuGet package {0} (~14 MB)..." -f $PY_VERSION)
        $got = $false
        foreach ($u in $NUGET_PY_MIRRORS) {
            $tmp = $NUPKG + '.part'
            try { curl.exe -L --fail -s -o $tmp $u } catch {}
            if ((Test-Path $tmp) -and (Get-Item $tmp).Length -gt 1MB) { Move-Item $tmp $NUPKG -Force -ErrorAction Stop; $got = $true; break }
            Remove-Item $tmp -Force -ErrorAction SilentlyContinue
        }
        if ($got) { Write-Host '[ok] NuGet package ready.' } else { Write-Host '[FAIL] NuGet package download failed.'; $ok = $false }
    }

    # 2) pinned dependency wheels (run pip download inside a staged python)
    $marker = Join-Path $WHEELS '.complete'
    if (Test-Path $marker) {
        Write-Host '[skip] Python dependency wheels already downloaded.'
    } elseif (-not (Test-Path $REQUIREMENTS)) {
        Write-Host '[FAIL] requirements.txt is missing from this folder.'; $ok = $false
    } else {
        $stage = New-StagePython
        if ($stage) {
            $stagePy = Join-Path $stage 'python.exe'
            New-Item -ItemType Directory -Force -Path $WHEELS | Out-Null
            Write-Host 'Downloading pinned Python dependency wheels (one-time)...'
            $dl = @('-m','pip','download','--no-deps','-q','--disable-pip-version-check',
                    '-i','https://pypi.org/simple','-r',$REQUIREMENTS,'setuptools','wheel','-d',$WHEELS)
            $out = & $stagePy @dl 2>&1
            $out | ForEach-Object { $_.ToString() } | Select-Object -Last 4
            if ($LASTEXITCODE -ne 0) {
                Write-Host 'Default PyPI failed, retrying via the Tsinghua mirror...'
                $dl2 = @('-m','pip','download','--no-deps','-q',
                         '--disable-pip-version-check','-i',$PIP_MIRROR,'-r',$REQUIREMENTS,'setuptools','wheel','-d',$WHEELS)
                $out2 = & $stagePy @dl2 2>&1
                $out2 | ForEach-Object { $_.ToString() } | Select-Object -Last 4
            }
            if ($LASTEXITCODE -eq 0) {
                New-Item -ItemType File -Force -Path $marker | Out-Null
                $n = (Get-ChildItem $WHEELS -Filter '*.whl' -ErrorAction SilentlyContinue).Count
                Write-Host ("[ok] {0} wheels cached." -f $n)
            } else {
                Write-Host '[FAIL] wheel download failed (check network / PyPI access).'; $ok = $false
            }
            Remove-Item $stage -Recurse -Force -ErrorAction SilentlyContinue
        } else { $ok = $false }
    }

    # 3) Apple driver MSI
    if (Test-Path $DRIVERMSI) {
        Write-Host '[skip] Apple driver MSI already present.'
    } else {
        if (Get-DriverMSI) { Write-Host '[ok] Apple driver MSI ready.' }
        else { Write-Host '[FAIL] driver MSI download failed.'; $ok = $false }
    }

    # 4) DDI
    if (Test-DdiComplete) {
        Write-Host '[skip] DDI files already present.'
    } else {
        if (Download-DdiFiles) { Write-Host '[ok] DDI files ready.' }
        else { Write-Host '[FAIL] DDI download incomplete.'; $ok = $false }
    }

    Write-Host ''
    if ($ok) {
        Write-Host 'Configure complete. Next run: flc make'
    } else {
        Write-Host 'Configure finished with failures (see [FAIL] above). Re-run "flc configure" to resume.'
    }
    Log 'configure'
}

# Build the minimal runtime from the materials in assets\dist (offline).
function Build-Runtime {
    $materials = (Test-Path $NUPKG) -and (Test-Path (Join-Path $WHEELS '.complete')) -and
                 (Test-Path $DRIVERMSI) -and (Test-DdiComplete)
    if (-not $materials) {
        Write-Host 'Build materials are incomplete. Running "flc configure" first...'
        Invoke-Configure
        $materials = (Test-Path $NUPKG) -and (Test-Path (Join-Path $WHEELS '.complete')) -and
                     (Test-Path $DRIVERMSI) -and (Test-DdiComplete)
        if (-not $materials) {
            Write-Host 'ERROR: materials are still incomplete after configure; cannot build.'
            exit 1
        }
    }

    $stage = New-StagePython
    if (-not $stage) { exit 1 }
    $pmd = $null
    try {
        $stagePy = Join-Path $stage 'python.exe'

        Write-Host 'Installing pinned dependencies from the local wheel cache (offline, exact set)...'
        $pi = @('-m','pip','install','--no-index','--find-links',$WHEELS,'--no-deps','--no-warn-script-location',
                '--disable-pip-version-check','-r',$REQUIREMENTS)
        $po = & $stagePy @pi 2>&1
        $po | ForEach-Object { $_.ToString() } | Select-Object -Last 3
        if ($LASTEXITCODE -ne 0) {
            Write-Host 'ERROR: offline wheel install failed. The wheel cache may be incomplete; run "flc configure".'
            exit 1
        }

        Write-Host 'Trimming development/GUI/test components...'
        $remove = @(
            'include','libs','tcl','Doc','Scripts','Lib\test','Lib\idlelib','Lib\tkinter','Lib\ensurepip',
            'Lib\site-packages\pip','Lib\site-packages\setuptools','Lib\site-packages\wheel','Lib\site-packages\pkg_resources',
            'Lib\site-packages\pythonwin','Lib\site-packages\win32comext','Lib\site-packages\adodbapi','Lib\site-packages\isapi',
            'Lib\site-packages\Crypto\SelfTest'
        )
        foreach ($r in $remove) {
            $p = Join-Path $stage $r
            if (Test-Path $p) { Remove-Item $p -Recurse -Force -ErrorAction SilentlyContinue }
        }
        foreach ($pat in @('pip-*.dist-info','setuptools-*.dist-info','wheel-*.dist-info')) {
            Get-ChildItem (Join-Path $stage 'Lib\site-packages') -Directory -Filter $pat -ErrorAction SilentlyContinue |
                Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
        }
        Get-ChildItem $stage -Recurse -Directory -Filter '__pycache__' -ErrorAction SilentlyContinue |
            Remove-Item -Recurse -Force -ErrorAction SilentlyContinue

        Write-Host 'Verifying the built runtime...'
        $pmd = & $stagePy -m pymobiledevice3 version 2>&1
        if ($LASTEXITCODE -ne 0 -or -not $pmd) {
            Write-Host ('ERROR: built runtime failed the pymobiledevice3 check: ' + ($pmd -join ' '))
            exit 1
        }

        if (Test-Path $PYDIR) { Remove-Item $PYDIR -Recurse -Force -ErrorAction SilentlyContinue }
        Move-Item $stage $PYDIR -ErrorAction Stop
    }
    finally {
        if ($stage -and (Test-Path $stage)) { Remove-Item $stage -Recurse -Force -ErrorAction SilentlyContinue }
    }

    $ver = & $PY --version 2>&1
    Write-Host ("Minimal runtime built: " + $ver + ", pymobiledevice3 " + ($pmd -join ''))

    Write-Host 'Syncing the offline DDI into the local cache...'
    & $PY -u $DDISCRIPT sync 2>&1 | ForEach-Object { $_.ToString() }

    $mb = [math]::Round((Get-ChildItem $PYDIR -Recurse -File | Measure-Object Length -Sum).Sum/1MB,1)
    Write-Host ("Runtime size: {0} MB." -f $mb)
}

# make (no args): build/refresh the minimal runtime.
function Invoke-Make {
    Write-Host '=== flc make ==='
    if (Test-Path $PY) {
        $chk = & $PY -m pymobiledevice3 version 2>&1
        if ($LASTEXITCODE -eq 0 -and $chk) {
            Write-Host ("Minimal runtime is already built: " + ($chk -join ''))
            Write-Host 'Run "flc make clean" first if you want to rebuild it from scratch.'
            if (-not (Test-DdiComplete)) {
                Write-Host 'DDI incomplete; running configure to complete it...'
                Invoke-Configure
            }
            Log 'make (already built)'
            return
        }
        Write-Host 'Existing python runtime is broken; rebuilding...'
        Remove-Item $PYDIR -Recurse -Force -ErrorAction SilentlyContinue
    }
    Build-Runtime
    Write-Host ''
    Write-Host 'Done. Next: flc server status, then (administrator) flc drivers install,'
    Write-Host 'and flc devices connect (tap Trust on the iPhone).'
    Log 'make'
}

# make clean: remove assets\ entirely (sources only).
function Invoke-MakeClean($opts) {
    $opts = @($opts)
    $assumeYes = ($opts | Where-Object { $_ -match '^(-y|--yes)$' }).Count -gt 0
    Write-Host '=== flc make clean ==='
    if (-not (Test-Path $ASSETS)) {
        Write-Host 'Nothing to clean: assets\ does not exist (already source-only).'
        return
    }
    $mb = Get-FolderSizeMB $ASSETS
    Write-Host ("This deletes the whole assets\ folder (~{0:N1} MB): built python, driver, DDI and" -f $mb)
    Write-Host 'downloaded materials. Only the program sources remain.'
    Write-Host 'Rebuild later with: flc configure   then   flc make'
    if (-not $assumeYes) {
        Write-Host ''
        $ans = (Read-Host 'Type YES to proceed').Trim()
        if ($ans -ne 'YES') { Write-Host 'Cancelled. Nothing was removed.'; return }
    }
    Remove-Item $ASSETS -Recurse -Force -ErrorAction SilentlyContinue
    if (Test-Path $LOGDIR) { Remove-Item $LOGDIR -Recurse -Force -ErrorAction SilentlyContinue }
    Write-Host ("Done. Freed ~{0:N1} MB. The folder is now source-only." -f $mb)
    Write-Host 'Your generated routes in data\ were kept.'
}

# make install [--prefix=PATH]: copy (optional) + add to user PATH.
function Invoke-MakeInstall($opts) {
    $opts = @($opts)
    $prefix = $null
    for ($i = 0; $i -lt $opts.Count; $i++) {
        if ($opts[$i] -match '^--(prefix|p)=(.+)$') { $prefix = $Matches[2] }
        elseif (($opts[$i] -eq '--prefix' -or $opts[$i] -eq '--p') -and ($i+1) -lt $opts.Count) { $prefix = $opts[$i+1] }
    }
    if (-not $prefix) {
        $target = $ROOT
    } else {
        $target = [Environment]::ExpandEnvironmentVariables($prefix.Trim('"').Trim("'"))
        if (-not [IO.Path]::IsPathRooted($target)) { $target = Join-Path (Get-Location).Path $target }
        $target = [IO.Path]::GetFullPath($target).TrimEnd('\')
    }

    if (-not (Test-Path $PY)) {
        Write-Host 'ERROR: the minimal runtime is not built yet. Run "flc configure" then "flc make" first.'
        exit 1
    }

    if ($target -ieq $ROOT.TrimEnd('\')) {
        Write-Host "Installing in place (current folder): $ROOT"
    } else {
        if ($target.TrimEnd('\').StartsWith($ROOT.TrimEnd('\'), [StringComparison]::OrdinalIgnoreCase)) {
            Write-Host 'ERROR: --prefix must not be inside the current program folder.'
            exit 1
        }
        New-Item -ItemType Directory -Force -Path $target | Out-Null
        Write-Host "Copying the program (including assets\) to: $target ..."
        $null = robocopy $ROOT $target /E /XD $DATADIR $LOGDIR /NFL /NDL /NJH /NJS /NP
        if ($LASTEXITCODE -ge 8) {
            Write-Host ("ERROR: copy failed (robocopy code {0})." -f $LASTEXITCODE)
            exit 1
        }
        Write-Host 'Copy complete.'
    }

    $entries = Normalize-PathEntries ([Environment]::GetEnvironmentVariable('Path','User'))
    $inPath = ($entries | Where-Object { $_.TrimEnd('\') -ieq $target.TrimEnd('\') }).Count -gt 0
    if ($inPath) {
        Write-Host "Already in user PATH: $target"
    } else {
        [Environment]::SetEnvironmentVariable('Path', ((@($entries) + $target) -join ';'), 'User')
        $env:Path = ((Normalize-PathEntries $env:Path) + $target) -join ';'
        Write-Host "Added to user PATH: $target"
        Write-Host 'Open a NEW command window, then type: flc help'
    }

    $script:InstallTarget = $target
    Invoke-PostInstallSetup
    Show-Status
    Log ("make install " + $target)
}

# make uninstall: remove from PATH, then optionally delete the whole folder.
function Invoke-MakeUninstall($opts) {
    $opts = @($opts)
    $assumeYes = ($opts | Where-Object { $_ -match '^(-y|--yes)$' }).Count -gt 0
    Write-Host '=== flc make uninstall ==='
    $entries = Normalize-PathEntries ([Environment]::GetEnvironmentVariable('Path','User'))
    $inPath = ($entries | Where-Object { $_.TrimEnd('\') -ieq $ROOT.TrimEnd('\') }).Count -gt 0
    if ($inPath) {
        $kept = @($entries | Where-Object { $_.TrimEnd('\') -ine $ROOT.TrimEnd('\') })
        [Environment]::SetEnvironmentVariable('Path', ($kept -join ';'), 'User')
        $env:Path = ((Normalize-PathEntries $env:Path) | Where-Object { $_.TrimEnd('\') -ine $ROOT.TrimEnd('\') }) -join ';'
        Write-Host "Removed from user PATH: $ROOT"
    } else {
        Write-Host "Not in user PATH: $ROOT"
    }

    $removeDriver = $false
    if (-not $assumeYes) {
        Write-Host ''
        Write-Host 'Also remove the Apple USB driver? This uninstalls the Apple Mobile'
        Write-Host 'Device Service and the Apple Mobile Device USB Driver, and clears'
        Write-Host 'all pairing records in C:\ProgramData\Apple\Lockdown.'
        $ansD = (Read-Host "Remove the driver and pairing records? [y/N]").Trim()
        if ($ansD -match '^(y|yes)$') { $removeDriver = $true }
    }
    if ($removeDriver) {
        if (Test-Admin) {
            Uninstall-Drivers -ClearAll
        } else {
            Write-Host 'Driver removal needs administrator rights. Approve the UAC prompt (click Yes)...'
            $null = Invoke-ElevatedWait 'drivers uninstall --clear'
            Write-Host 'Driver removal finished.'
        }
    }

    $del = $false
    if ($assumeYes) { $del = $true }
    else {
        Write-Host ''
        Write-Host 'Also permanently delete the entire tool folder and all its contents?'
        Write-Host ("  " + $ROOT)
        $ans = (Read-Host "Delete the folder? [y/N]").Trim()
        if ($ans -match '^(y|yes)$') { $del = $true }
    }

    if ($del) {
        Log 'make uninstall (delete)'
        # Spawn a detached, independent process via WMI (its parent is the WMI
        # service, so it survives this window closing and is not killed by the
        # parent job object). PowerShell waits for the files to be released, then
        # removes the whole tool folder.
        $inner = 'Start-Sleep -Seconds 2; Remove-Item -LiteralPath ''' + $ROOT + ''' -Recurse -Force -ErrorAction SilentlyContinue'
        $cmdLine = 'powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -Command "' + $inner + '"'
        try {
            $r = ([wmiclass]'\\.\root\cimv2:Win32_Process').Create($cmdLine)
            if ($r.ReturnValue -eq 0) {
                Write-Host 'The folder will be deleted a few seconds after this window closes.'
            } else {
                Write-Host ('Could not schedule the auto-delete (code ' + $r.ReturnValue + '). Delete it manually after closing:')
                Write-Host ('  ' + $ROOT)
            }
        } catch {
            Write-Host ('Could not schedule the auto-delete: ' + $_.Exception.Message)
            Write-Host ('Delete it manually after closing: ' + $ROOT)
        }
    } else {
        Write-Host 'Folder kept. It still works by running flc.cmd directly from this folder.'
    }
}

# make update [gitee|github]: update the program sources to the latest version.
# Git clones are fast-forwarded with git pull; source-archive installs (no .git)
# download the latest source archive and overwrite sources in place, keeping
# assets\, data\ and logs\. Default source is Gitee (works without a proxy).
function Invoke-MakeUpdate($opts) {
    $opts = @($opts)
    $source = 'gitee'
    foreach ($o in $opts) {
        if ($o -match '(?i)^(--)?github$' -or $o -match '(?i)^--gh$') { $source = 'github' }
        elseif ($o -match '(?i)^(--)?gitee$') { $source = 'gitee' }
    }
    Write-Host ("=== flc make update (source: " + $source + ") ===")

    $gitUrls = @{
        gitee  = 'https://gitee.com/DavidDengHui/fake-location-cli.git'
        github = 'https://github.com/DavidDengHui/fake-location-cli.git'
    }
    $archives = @{
        gitee  = 'https://gitee.com/DavidDengHui/fake-location-cli/repository/archive/master.tar.gz'
        github = 'https://github.com/DavidDengHui/fake-location-cli/archive/refs/heads/master.tar.gz'
    }

    $gitCmd = Get-Command git -ErrorAction SilentlyContinue
    $isRepo = Test-Path (Join-Path $ROOT '.git')

    if ($isRepo -and $gitCmd) {
        Write-Host 'Git repository detected - fast-forwarding to the latest sources...'
        $remotes = @(& git -C $ROOT remote 2>$null)
        if ($remotes -contains 'origin') {
            $cur = (& git -C $ROOT remote get-url origin)
            if ($source -eq 'github' -and $cur -notmatch 'github') {
                & git -C $ROOT remote set-url origin $gitUrls.github
                Write-Host 'origin switched to GitHub.'
            }
            elseif ($source -eq 'gitee' -and $cur -notmatch 'gitee') {
                & git -C $ROOT remote set-url origin $gitUrls.gitee
                Write-Host 'origin switched to Gitee.'
            }
        }
        else {
            & git -C $ROOT remote add origin $gitUrls[$source]
        }
        & git -C $ROOT pull --ff-only origin master
        if ($LASTEXITCODE -ne 0) {
            Write-Host 'Fast-forward pull failed (local modifications or network). Current files kept.'
            Write-Host 'Stash or commit your changes, then run this command again.'
            exit 1
        }
    }
    else {
        Write-Host ("Downloading the latest source archive from " + $source + '...')
        $tag = [guid]::NewGuid().ToString('N').Substring(0,8)
        $tmpGz  = Join-Path $env:TEMP ("flc-update-$tag.tar.gz")
        $tmpDir = Join-Path $env:TEMP ("flc-update-$tag")
        if ($source -eq 'github') {
            $curlArgs = @('-L','--fail','--ssl-no-revoke','--proxy','http://127.0.0.1:26561',
                          '--connect-timeout','20','-s','-o',$tmpGz,$archives[$source])
        }
        else {
            $curlArgs = @('-L','--fail','--connect-timeout','20','-s','-o',$tmpGz,$archives[$source])
        }
        & curl.exe @curlArgs
        if ($LASTEXITCODE -ne 0 -or -not (Test-Path $tmpGz)) {
            Write-Host "Download from $source failed (network or proxy)."
            Write-Host 'Try the other source:  flc make update gitee   (or github)'
            exit 1
        }
        New-Item -ItemType Directory -Force -Path $tmpDir | Out-Null
        tar -xzf $tmpGz -C $tmpDir
        if ($LASTEXITCODE -ne 0) { Write-Host 'Could not extract the source archive.'; exit 1 }
        $inner = Get-ChildItem $tmpDir -Directory | Select-Object -First 1
        if (-not $inner) { Write-Host 'Unexpected archive layout.'; exit 1 }
        # Overwrite sources only; without /MIR, robocopy never deletes assets\, data\, logs\.
        robocopy $inner.FullName $ROOT /E /NFL /NDL /NJH /NJS /NP /XD __pycache__ | Out-Null
        if ($LASTEXITCODE -ge 8) {
            Write-Host "Copying updated sources failed (robocopy code $LASTEXITCODE)."
            exit 1
        }
        Remove-Item $tmpGz -Force -ErrorAction SilentlyContinue
        Remove-Item $tmpDir -Recurse -Force -ErrorAction SilentlyContinue
    }

    Write-Host ''
    Write-Host 'Sources updated. Your assets\, data\ and logs\ were kept.'
    Write-Host 'A runtime rebuild is only needed if the dependencies change: flc make'

    Write-Host ''
    Write-Host 'Clearing old pairing records so the updated code re-pairs cleanly...'
    [void](Clear-LockdownPlist)
    $lockdown = Join-Path $env:ProgramData 'Apple\Lockdown'
    $stillHas = $false
    if (Test-Path $lockdown) {
        $stillHas = @(Get-ChildItem $lockdown -Filter '*.plist' -Force -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -ne 'SystemConfiguration.plist' }).Count -gt 0
    }
    if ($stillHas -and -not (Test-Admin)) {
        Write-Host 'Clearing pairing records needs administrator rights. Approve the UAC prompt (click Yes)...'
        $null = Invoke-ElevatedWait 'server kill --pair'
    }
    Write-Host 'Pairing records handled. Reconnect and trust the iPhone again if prompted.'
    Log "make update ($source)"
}

function Do-Make($rest) {
    $action = if ($rest -and $rest.Count -gt 0) { $rest[0] } else { '' }
    $opts   = if ($rest -and $rest.Count -gt 1) { @($rest[1..($rest.Count-1)]) } else { @() }
    switch -Regex ($action) {
        '^$|^(build|all)$'    { Invoke-Make }
        '^(clean|-c)$'        { Invoke-MakeClean $opts }
        '^(update|--update)$' { Invoke-MakeUpdate $opts }
        '^(install|-i)$'      { Invoke-MakeInstall $opts }
        '^(uninstall|-u)$'    { Invoke-MakeUninstall $opts }
        default { Write-Host 'Unknown make action. Use: flc make [update|clean|install|uninstall]'; exit 1 }
    }
}

# ---------------- server (status / kill only) ----------------

function Do-Server($srvArgs) {
    $action = $srvArgs[0]
    $opts = @()
    if ($srvArgs.Count -gt 1) { $opts = $srvArgs[1..($srvArgs.Count-1)] }
    $resetPair = ($opts | Where-Object { $_ -match '^(--pair|-p)$' }).Count -gt 0
    switch -Regex ($action) {
        '^(status|-s)$' { Show-Status }
        '^(kill|-k)$'   { Do-ServerKill $resetPair }
        default { Write-Host 'Unknown server action. Use: flc server status|kill [--pair]'; exit 1 }
    }
}

function Show-Status {
    Write-Host '================ flc status ================'
    $userPath = [Environment]::GetEnvironmentVariable('Path','User')
    $checkPath = if ($script:InstallTarget) { $script:InstallTarget } else { $ROOT }
    $inPath = ($userPath -split ';' | Where-Object { $_ -and $_.TrimEnd('\') -ieq $checkPath.TrimEnd('\') }).Count -gt 0
    Write-Host ('CLI installed in PATH : ' + $(if ($inPath) {'YES'} else {'no'}) + '  (' + $checkPath + ')')
    if (Test-Path $PY) {
        $ver = & $PY --version 2>&1
        Write-Host ('Portable Python       : OK  (' + $ver + ')')
        $pmd = & $PY -m pymobiledevice3 version 2>&1
        Write-Host ('pymobiledevice3       : ' + ($pmd -join ''))
    } else {
        Write-Host 'Portable Python       : MISSING (assets\python\python.exe)'
    }
    $svc = Get-Service -Name $AMDS_SERVICE -ErrorAction SilentlyContinue
    if ($svc) {
        Write-Host ('Apple Mobile Device   : ' + $svc.Status + ' (start type: ' + $svc.StartType + ')')
    } else {
        Write-Host 'Apple Mobile Device   : NOT INSTALLED'
    }
    $listener = Get-NetTCPConnection -LocalPort $TUNNELD_PORT -State Listen -ErrorAction SilentlyContinue
    if ($listener) {
        $proc = Get-Process -Id $listener.OwningProcess -ErrorAction SilentlyContinue
        Write-Host ('tunneld port 49151    : IN USE by ' + $proc.ProcessName + ' (PID ' + $listener.OwningProcess + ')')
    } else {
        Write-Host 'tunneld port 49151    : free'
    }
    if (Test-Path $DRIVERMSI) {
        $mb = [math]::Round((Get-Item $DRIVERMSI).Length/1MB,1)
        Write-Host ("Offline driver MSI    : present ($mb MB)")
    } else {
        Write-Host 'Offline driver MSI    : absent (run "flc configure")'
    }
    if (Test-DdiComplete) {
        $dmb = [math]::Round(((Get-ChildItem $DDIDIR -Recurse -File | Measure-Object Length -Sum).Sum)/1MB,1)
        Write-Host ("Offline DDI image     : present ($dmb MB) - first 'set' needs no big download")
    } else {
        Write-Host 'Offline DDI image     : absent (run "flc configure")'
    }
    Write-Host '--------------------------------------------'
    Show-Devices
    Write-Host '============================================'
}

function Do-ServerKill($resetPair = $false) {
    if (Invoke-Elevated @($CliArgs)) { return }
    Write-Host 'Stopping conflicting processes...'
    $killed = 0
    $listener = Get-NetTCPConnection -LocalPort $TUNNELD_PORT -State Listen -ErrorAction SilentlyContinue
    if ($listener) {
        foreach ($procId in ($listener.OwningProcess | Sort-Object -Unique)) {
            try {
                $p = Get-Process -Id $procId -ErrorAction Stop
                Write-Host ("  stopping {0} (PID {1}) on port {2}" -f $p.ProcessName, $procId, $TUNNELD_PORT)
                Stop-Process -Id $procId -Force -ErrorAction Stop
                $killed++
            } catch {
                Write-Host ("  could not stop PID {0}: {1}" -f $procId, $_.Exception.Message)
            }
        }
    }
    $procs = Get-CimInstance Win32_Process -Filter "Name='python.exe' OR Name='pythonw.exe'" -ErrorAction SilentlyContinue |
        Where-Object { $_.CommandLine -match 'pymobiledevice3' -and ($_.CommandLine -match 'tunneld|simulate-location') }
    foreach ($p in $procs) {
        try {
            Write-Host ("  stopping PID {0}: {1}" -f $p.ProcessId, ($p.CommandLine.Substring(0,[Math]::Min(90,$p.CommandLine.Length))))
            Stop-Process -Id $p.ProcessId -Force -ErrorAction Stop
            $killed++
        } catch {
            Write-Host ("  could not stop PID {0}: {1}" -f $p.ProcessId, $_.Exception.Message)
        }
    }
    if ($resetPair) { Reset-PairRecords }
    if ($killed -eq 0) { Write-Host 'No conflicting processes found.' }
    else { Write-Host "Done. Stopped $killed process(es)." }
    Log "server kill (procs=$killed pair=$resetPair)"
}

# Remove pairing plists from the AMDS Lockdown folder. By default the
# SystemConfiguration.plist (SystemBUID) is kept so other pairings survive;
# use -All for a full driver uninstall. Returns the number of files removed.
function Clear-LockdownPlist([switch]$All) {
    $lockdown = Join-Path $env:ProgramData 'Apple\Lockdown'
    if (-not (Test-Path $lockdown)) {
        Write-Host ('  no Lockdown folder at ' + $lockdown)
        return 0
    }
    $plists = @(Get-ChildItem $lockdown -Filter '*.plist' -Force -ErrorAction SilentlyContinue)
    if (-not $All) {
        $plists = @($plists | Where-Object { $_.Name -ne 'SystemConfiguration.plist' })
    }
    $n = 0
    foreach ($fi in $plists) {
        try {
            Remove-Item $fi.FullName -Force -ErrorAction Stop
            $n++
        } catch {
            Write-Host ('  could not delete ' + $fi.Name + ': ' + $_.Exception.Message)
        }
    }
    Write-Host ('  cleared ' + $n + ' pair-record file(s) from ' + $lockdown)
    return $n
}

function Reset-PairRecords {
    # Fix usbmux error 183 (Windows ERROR_ALREADY_EXISTS): a stale/corrupt pair
    # record makes AMDS refuse SavePairRecord. Restart the service and clear
    # device plists (keep SystemConfiguration.plist / SystemBUID). Elevated.
    if (-not (Get-Service -Name $AMDS_SERVICE -ErrorAction SilentlyContinue)) {
        Write-Host '  Apple Mobile Device Service is not installed - nothing to reset.'
        return
    }
    Write-Host 'Resetting pairing records (fixes usbmux error 183)...'
    try {
        Stop-Service -Name $AMDS_SERVICE -Force -ErrorAction Stop
        Write-Host ('  stopped ' + $AMDS_SERVICE)
    } catch {
        Write-Host ('  could not stop service: ' + $_.Exception.Message)
    }
    Start-Sleep -Milliseconds 800
    [void](Clear-LockdownPlist)
    try {
        Start-Service -Name $AMDS_SERVICE -ErrorAction Stop
        Write-Host ('  started ' + $AMDS_SERVICE)
    } catch {
        Write-Host ('  could not start service: ' + $_.Exception.Message)
    }
    Write-Host '  Next: unlock the iPhone, replug it, tap Trust, then run: flc ddi install'
}
function Get-DdiState {
    $code = "import sys,json;sys.path.insert(0,r'$ROOT');import flc_ddi;print(json.dumps({'bundled':flc_ddi.bundled_id(),'cache':flc_ddi.cache_ids()}))"
    $line = (& $PY -c $code 2>$null | Select-Object -Last 1)
    try { return ($line | ConvertFrom-Json) } catch { return $null }
}

function Get-FolderSizeMB($path) {
    if (-not (Test-Path $path)) { return 0 }
    $sum = (Get-ChildItem $path -Recurse -File -Force -ErrorAction SilentlyContinue | Measure-Object Length -Sum).Sum
    return [math]::Round(($sum)/1MB,1)
}

# ---------------- drivers ----------------

function Do-Drivers($drvArgs) {
    $action = $drvArgs[0]
    $opts = @()
    if ($drvArgs.Count -gt 1) { $opts = $drvArgs[1..($drvArgs.Count-1)] }
    $clearAll = ($opts | Where-Object { $_ -match '^--clear$' }).Count -gt 0
    switch -Regex ($action) {
        '^(list|-l)$' {
            Write-Host 'Required drivers for iPhone USB connectivity:'
            Write-Host ''
            Write-Host '1) Apple Mobile Device Support (64-bit)'
            Write-Host '   Provides the usbmuxd service (Apple Mobile Device Service) and the USB driver.'
            if (Test-Path $DRIVERMSI) {
                $mb = [math]::Round((Get-Item $DRIVERMSI).Length/1MB,1)
                Write-Host "   Offline installer: YES  assets\drivers\AppleMobileDeviceSupport64.msi ($mb MB)"
            } else {
                Write-Host '   Offline installer: NO   (run "flc configure" to download it)'
            }
            Write-Host ''
            Write-Host 'Note: the wintun tunnel driver is bundled inside pymobiledevice3 and needs no separate install.'
        }
        '^(status|-s)$' {
            $svc = Get-Service -Name $AMDS_SERVICE -ErrorAction SilentlyContinue
            $reg = Get-ItemProperty 'HKLM:\SOFTWARE\Apple Inc.\Apple Mobile Device Support' -ErrorAction SilentlyContinue
            if ($reg) {
                Write-Host ('Apple Mobile Device Support: INSTALLED (version ' + $reg.Version + ')')
            } else {
                Write-Host 'Apple Mobile Device Support: NOT INSTALLED'
            }
            if ($svc) {
                Write-Host ('Apple Mobile Device Service : ' + $svc.Status + ', start type ' + $svc.StartType)
            } else {
                Write-Host 'Apple Mobile Device Service : absent'
            }
            $usb = Get-PnpDevice -PresentOnly -ErrorAction SilentlyContinue | Where-Object { $_.FriendlyName -match 'Apple Mobile Device|Apple iPhone' }
            if ($usb) {
                Write-Host 'Apple USB device nodes:'
                $usb | ForEach-Object { Write-Host ('   [' + $_.Status + '] ' + $_.FriendlyName) }
            } else {
                Write-Host 'Apple USB device nodes: none present (connect an iPhone to see them).'
            }
        }
        '^(install|-i)$' {
            if (Invoke-Elevated @($CliArgs)) { return }
            Install-Drivers
        }
        '^(uninstall|-u)$' {
            if (Invoke-Elevated @($CliArgs)) { return }
            Uninstall-Drivers -ClearAll:$clearAll
        }
        default { Write-Host 'Unknown drivers action. Use: flc drivers list|status|install|uninstall'; exit 1 }
    }
}

function Install-Drivers {
    Write-Host '=== Installing Apple Mobile Device Support ==='
    if (-not (Test-Path $DRIVERMSI)) {
        Write-Host 'Offline installer not found. Downloading from apple.com...'
        if (-not (Get-DriverMSI)) {
            Write-Host 'ERROR: installer unavailable. Check network or run "flc configure".'
            Read-Host 'Press Enter to exit'; exit 1
        }
    }
    Write-Host 'Running silent install (this may take a minute)...'
    if (-not (Test-Path $LOGDIR)) { New-Item -ItemType Directory -Force -Path $LOGDIR | Out-Null }
    $p = Start-Process -FilePath 'msiexec.exe' -ArgumentList @('/i',$DRIVERMSI,'/qn','/norestart','/L*v',(Join-Path $LOGDIR 'amds-install.log')) -Wait -PassThru
    Write-Host ('msiexec exit code: ' + $p.ExitCode)
    Start-Sleep -Seconds 2
    try { Start-Service -Name $AMDS_SERVICE -ErrorAction SilentlyContinue } catch {}
    $svc = Get-Service -Name $AMDS_SERVICE -ErrorAction SilentlyContinue
    if ($svc) {
        Write-Host ('Apple Mobile Device Service: ' + $svc.Status)
        Write-Host 'Driver installation complete.'
    } else {
        Write-Host 'Install finished but the service is not registered. Check logs\amds-install.log'
    }
    Log 'drivers install'
}

function Uninstall-Drivers([switch]$ClearAll) {
    Write-Host '=== Uninstalling Apple Mobile Device Support ==='
    $reg = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*' -ErrorAction SilentlyContinue |
        Where-Object { $_.DisplayName -eq 'Apple Mobile Device Support' }
    if ($reg) {
        Write-Host ('Found product: ' + $reg.DisplayName + ' ' + $reg.DisplayVersion)
        $p = Start-Process -FilePath 'msiexec.exe' -ArgumentList @('/x',$reg.PSChildName,'/qn','/norestart') -Wait -PassThru
        Write-Host ('msiexec exit code: ' + $p.ExitCode)
        Start-Sleep -Seconds 2
    } else {
        Write-Host 'Apple Mobile Device Support is not installed.'
    }
    if ($ClearAll) {
        Write-Host 'Clearing all pairing records (including SystemConfiguration)...'
        [void](Clear-LockdownPlist -All)
    }
    Log ('drivers uninstall (clear=' + $ClearAll + ')')
}

# ---------------- devices ----------------

function Show-Devices {
    Write-Host 'Connected Apple devices:'
    $raw = & $PY -m pymobiledevice3 --no-color usbmux list 2>$null
    $json = ($raw -join "`n").Trim()
    try {
        $list = $json | ConvertFrom-Json
    } catch {
        Write-Host '  (could not read device list; is Apple Mobile Device Service running?)'
        return
    }
    if (-not $list -or $list.Count -eq 0) {
        Write-Host '  none. Connect an iPhone via USB, unlock it and tap Trust.'
        return
    }
    $i = 0
    foreach ($d in $list) {
        $i++
        if ($d -is [string]) {
            Write-Host ("  [{0}] UDID: {1}  (use 'devices connect' to pair for name/details)" -f $i, $d)
            continue
        }
        $name = $d.DeviceName
        $udid = $d.UniqueDeviceID
        if (-not $udid) { $udid = $d.Identifier }
        $prod = $d.ProductType
        $ios  = $d.ProductVersion
        $conn = $d.ConnectionType
        if (-not $name) { $name = '(unknown name)' }
        if (-not $prod) { $prod = '' }
        $ver = if ($ios) { ' iOS ' + $ios } else { '' }
        Write-Host ("  [{0}] {1}  {2}{3}  UDID: {4}  ({5})" -f $i, $name, $prod, $ver, $udid, $conn)
    }
}

function Do-Devices($action) {
    switch -Regex ($action) {
        '^(list|-l)$' {
            Show-Devices
        }
        '^(connect|-c)$' {
            if (Invoke-Elevated @($CliArgs)) { return }
            Write-Host 'Starting Apple Mobile Device Service...'
            try {
                $svc = Get-Service -Name $AMDS_SERVICE -ErrorAction Stop
                if ($svc.Status -ne 'Running') { Start-Service -Name $AMDS_SERVICE }
                Start-Sleep -Seconds 2
            } catch {
                Write-Host 'ERROR: service not found. Run: flc drivers install'
                Read-Host 'Press Enter to exit'; exit 1
            }
            Write-Host 'Sending pairing request. On the iPhone, tap "Trust" and enter the passcode...'
            Invoke-Py -NoColor @('lockdown','pair')
            Log 'devices connect'
        }
        '^(disconnect|-d)$' {
            if (Invoke-Elevated @($CliArgs)) { return }
            Write-Host 'Stopping Apple Mobile Device Service (releases all iPhone connections)...'
            try { Stop-Service -Name $AMDS_SERVICE -Force; Write-Host 'Disconnected.' }
            catch { Write-Host ('ERROR: ' + $_.Exception.Message) }
            Log 'devices disconnect'
        }
        '^(reconnect|-r)$' {
            if (Invoke-Elevated @($CliArgs)) { return }
            Write-Host 'Restarting Apple Mobile Device Service...'
            try {
                Restart-Service -Name $AMDS_SERVICE -Force
                Start-Sleep -Seconds 3
                $svc = Get-Service -Name $AMDS_SERVICE
                Write-Host ('Service status: ' + $svc.Status)
                Start-Sleep -Seconds 2
                Show-Devices
            } catch {
                Write-Host ('ERROR: ' + $_.Exception.Message)
            }
            Log 'devices reconnect'
        }
        default { Write-Host 'Unknown devices action. Use: flc devices list|connect|disconnect|reconnect'; exit 1 }
    }
}

# ---------------- ddi ----------------

function Do-Ddi($action) {
    switch -Regex ($action) {
        '^(sync)$' {
            & $PY -u $DDISCRIPT sync
            Log 'ddi sync'
        }
        '^(status|-s)$' {
            Ensure-AmdsRunning
            & $PY -u $DDISCRIPT status
        }
        '^(install|-i)$' {
            Ensure-AmdsRunning
            Write-Host 'Installing the offline Developer Disk Image onto the connected iPhone...'
            Write-Host '(A brand-new device needs a one-time Apple personalization handshake; small & automatic.)'
            & $PY -u $DDISCRIPT install
            Log 'ddi install'
        }
        default { Write-Host 'Unknown ddi action. Use: flc ddi status|sync|install'; exit 1 }
    }
}

# ---------------- set / own ----------------

function Convert-RouteFile($src) {
    if (-not [System.IO.Path]::IsPathRooted($src)) { $src = Join-Path (Get-Location).Path $src }
    if (-not (Test-Path -LiteralPath $src -PathType Leaf)) {
        Write-Host "Route file not found: $src"; return $null
    }
    $ext = [System.IO.Path]::GetExtension($src).ToLower()
    if ($ext -eq '.gpx') { return $src }
    if ($ext -in '.txt','.csv') {
        if (-not (Test-Path $DATADIR)) { New-Item -ItemType Directory -Force -Path $DATADIR | Out-Null }
        $out = Join-Path $DATADIR (([System.IO.Path]::GetFileNameWithoutExtension($src)) + '.gpx')
        Write-Host "Converting $ext route to GPX..."
        & $PY (Join-Path $ROOT 'flc_route.py') convert $src $out 2>&1 | Out-Host
        if ($LASTEXITCODE -eq 0 -and (Test-Path -LiteralPath $out)) { return $out }
        Write-Host 'Could not convert the route file.'; return $null
    }
    Write-Host "Unsupported route file type: $ext (use .gpx, .txt or .csv)"; return $null
}

function New-RoutePath {
    if (-not (Test-Path $DATADIR)) { New-Item -ItemType Directory -Force -Path $DATADIR | Out-Null }
    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    return (Join-Path $DATADIR ("route-$stamp.gpx"))
}

function Do-Set($rest) {
    if (-not $rest) { $rest = @() }
    if ($rest.Count -gt 0 -and ($rest[0] -eq 'own' -or $rest[0] -eq '-o' -or $rest[0] -eq '--own')) {
        Write-Host 'Restoring real GPS location (clearing simulated location)...'
        Ensure-AmdsRunning
        Invoke-Py -NoColor @('developer','dvt','simulate-location','clear','--userspace')
        Write-Host 'Done. Real location restored.'
        Log 'set own'
        return
    }
    $setScript = Join-Path $ROOT 'flc_set.py'

    # Optional hold interval: --keep <sec> / -k <sec>. Strip it before
    # parsing coordinates so its value is never mistaken for a latitude/longitude.
    $interval = $null
    $clean = @()
    for ($i = 0; $i -lt $rest.Count; $i++) {
        if ($rest[$i] -eq '--keep' -or $rest[$i] -eq '-k') {
            if ($i + 1 -ge $rest.Count) {
                Write-Host 'Missing value for --keep. Example: flc set 23.137106 113.331353 --keep 5'; exit 1
            }
            $interval = $rest[$i + 1]; $i++
        }
        else { $clean += $rest[$i] }
    }
    $rest = $clean
    $intervalSec = $null
    if ($interval) {
        $iv = 0.0
        if (-not [double]::TryParse($interval, [ref]$iv) -or $iv -lt 1 -or $iv -gt 3600) {
            Write-Host 'Keep interval must be a number between 1 and 3600 seconds.'; exit 1
        }
        $intervalSec = [int][math]::Round($iv)
        if ($iv -lt 3) { Write-Host ("Warning: an interval below 3s adds no benefit and may cause message backlog on the tunnel (using {0}s)." -f $intervalSec) }
    }

    if ($rest.Count -gt 0 -and ($rest[0] -eq 'gpx' -or $rest[0] -eq '--gpx')) {
        $arg = $null
        if ($rest.Count -ge 2) { $arg = $rest[1] }
        $gpx = $null

        if ($arg -eq 'new' -or $arg -eq '-n' -or $arg -eq '--new') {
            $gpx = New-RoutePath
            Write-Host "The new route will be saved to: $gpx"
            & $PY -u (Join-Path $ROOT 'flc_route.py') interactive $gpx
            if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $gpx)) { Write-Host 'No route was created.'; exit 1 }
        }
        elseif ($arg) {
            $gpx = Convert-RouteFile $arg
        }
        else {
            Write-Host 'Replay a route file (.gpx/.txt/.csv), or build one line by line.'
            $ans = (Read-Host "Enter the route file path, or 'new' to create one").Trim()
            if ($ans -eq 'new' -or $ans -eq '') {
                $gpx = New-RoutePath
                Write-Host "The new route will be saved to: $gpx"
                & $PY -u (Join-Path $ROOT 'flc_route.py') interactive $gpx
                if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $gpx)) { Write-Host 'No route was created.'; exit 1 }
            }
            else { $gpx = Convert-RouteFile $ans }
        }

        if (-not $gpx) { exit 1 }
        Ensure-AmdsRunning
        Write-Host ("Replaying GPX route: {0}" -f $gpx)
        Log "set gpx $gpx"
        $pyArgs = @('gpx', $gpx)
        if ($intervalSec) { $pyArgs += @('--keep', $intervalSec) }
        & $PY -u $setScript @pyArgs
        return
    }

    $lat = $null; $lng = $null
    for ($i = 0; $i -lt $rest.Count; $i++) {
        if ($rest[$i] -match '^-?(Lat|lat)$') { $lat = $rest[$i+1] }
        if ($rest[$i] -match '^-?(Lng|lng|Lon|lon)$') { $lng = $rest[$i+1] }
    }
    if (-not $lat -or -not $lng) {
        $nums = @($rest | Where-Object { $_ -match '^-?\d+(\.\d+)?$' })
        if ($nums.Count -ge 2) { $lat = $nums[0]; $lng = $nums[1] }
    }
    if (-not $lat) {
        Write-Host 'Set a simulated location. Coordinates are decimal latitude then longitude.'
        Write-Host 'Example: 23.137106 113.331353'
        $lat = Read-Host 'Enter latitude '
    }
    if (-not $lng) {
        $lng = Read-Host 'Enter longitude'
    }
    $latV = 0.0; $lngV = 0.0
    if (-not [double]::TryParse($lat.Replace(',','.'), [ref]$latV) -or
        -not [double]::TryParse($lng.Replace(',','.'), [ref]$lngV)) {
        Write-Host 'Invalid coordinates. Use decimal numbers, e.g. 23.137106 113.331353'; exit 1
    }
    if ($latV -lt -90 -or $latV -gt 90 -or $lngV -lt -180 -or $lngV -gt 180) {
        Write-Host 'Coordinates out of range.'; exit 1
    }
    Ensure-AmdsRunning
    Write-Host ("Setting simulated location: {0}, {1}" -f $latV, $lngV)
    Log "set $latV $lngV"
    $pyArgs = @([string]$latV, [string]$lngV)
    if ($intervalSec) { $pyArgs += @('--keep', $intervalSec) }
    & $PY -u $setScript @pyArgs
}

function Ensure-AmdsRunning {
    $svc = Get-Service -Name $AMDS_SERVICE -ErrorAction SilentlyContinue
    if (-not $svc) {
        Write-Host 'Apple Mobile Device Service is not installed. Run: flc drivers install'; exit 1
    }
    if ($svc.Status -ne 'Running') {
        Write-Host 'Starting Apple Mobile Device Service...'
        try { Start-Service -Name $AMDS_SERVICE -ErrorAction Stop; Start-Sleep -Seconds 2 }
        catch {
            Write-Host 'Could not start the service without administrator rights.'
            Write-Host 'Run once as administrator:  flc devices connect'
            exit 1
        }
    }
}

# ---------------- help / router ----------------

function Show-Help {
    Write-Host ''
    Write-Host 'flc - Fake Location CLI for iPhone (portable, powered by pymobiledevice3)'
    Write-Host ''
    Write-Host 'Setup (download -> build -> install):'
    Write-Host '  flc configure|-c               Download all official dependencies into assets\ (idempotent)'
    Write-Host '  flc make                       Build the minimal runtime from the downloaded materials'
    Write-Host '  flc make update [gitee|github] Update sources (Gitee default), then clear pairing records'
    Write-Host '  flc make clean|-c              Remove assets\ (keep sources only)'
    Write-Host '  flc make install|-i [--prefix=PATH | --p=PATH]  Copy/add to PATH, auto-install USB driver + DDI'
    Write-Host '  flc make uninstall|-u          Remove from PATH; optionally remove driver+pair records, delete folder'
    Write-Host ''
    Write-Host '  flc server status|-s           Show components, service, port and devices'
    Write-Host '  flc server kill|-k             Stop conflicting tunneld/location processes'
    Write-Host '  flc server kill|-k --pair|-p   Also clear pair records & restart AMDS (fixes error 183)'
    Write-Host ''
    Write-Host '  flc drivers list|-l            List required drivers and whether they are present'
    Write-Host '  flc drivers status|-s          Show whether the drivers are installed'
    Write-Host '  flc drivers install|-i         Install drivers (offline MSI if present, else download)'
    Write-Host '  flc drivers uninstall|-u [--clear]  Uninstall driver; --clear also wipes Lockdown plists'
    Write-Host ''
    Write-Host '  flc devices list|-l            List connected Apple devices'
    Write-Host '  flc devices connect|-c         Start service and request pairing (tap Trust on iPhone)'
    Write-Host '  flc devices disconnect|-d      Release connections (stop the service)'
    Write-Host '  flc devices reconnect|-r       Restart the service and re-list devices'
    Write-Host ''
    Write-Host '  flc ddi status|-s             Show offline Developer Disk Image and device state'
    Write-Host '  flc ddi sync                  Copy the offline DDI into the local cache'
    Write-Host '  flc ddi install|-i            Install the DDI on the iPhone (one-time per device/iOS)'
    Write-Host ''
    Write-Host '  flc set <lat> <lng>            Set and HOLD a location (two numbers, e.g. 23.137106 113.331353)'
    Write-Host '  flc set <lat> <lng> --keep <sec>  Custom hold/re-apply interval (1-3600s, default 15s)'
    Write-Host '  flc set                        Prompt for latitude and longitude one by one'
    Write-Host '  flc set gpx <file>            Replay a route (.gpx, or .txt/.csv auto-converted), hold end'
    Write-Host '  flc set gpx <file> --keep <sec>  Replay a route and hold its end with a custom interval'
    Write-Host '  flc set gpx new               Build a route line by line (time + lat + lng), then replay'
    Write-Host '  flc set own|-o                 Clear simulation and restore the real location'
    Write-Host '  (  named form still works: flc set -Lat 23.137106 -Lng 113.331353 )'
    Write-Host '  (  short form of --keep: -k <sec> )'
    Write-Host ''
    Write-Host '  flc help|-h                    Show this help'
    Write-Host ''
    Write-Host 'Typical first-time use:'
    Write-Host '  flc configure'
    Write-Host '  flc make'
    Write-Host '  flc drivers install     (administrator)'
    Write-Host '  flc devices connect     (then tap Trust on the iPhone)'
    Write-Host '  flc set 23.137106 113.331353'
    Write-Host '  flc set gpx route.gpx'
    Write-Host '  flc set own'
    Write-Host ''
}

# ---- main router ----
if (-not $CliArgs -or $CliArgs.Count -eq 0) { Show-Help; exit 0 }
$group = $CliArgs[0]
$rest  = @()
if ($CliArgs.Count -gt 1) { $rest = $CliArgs[1..($CliArgs.Count-1)] }

# help, configure, make and the server lifecycle commands do not need python yet.
# Everything else requires assets\python\python.exe.
$needsPy = $group -notmatch '^(help|-h|--help|configure|-c|make|server)$'
if ($needsPy -and -not (Test-Path $PY)) {
    Write-Host 'ERROR: the minimal runtime is missing (assets\python\python.exe).'
    Write-Host 'Set it up with:  flc configure   then   flc make'
    exit 1
}

switch -Regex ($group) {
    '^(configure|-c)$'   { Invoke-Configure }
    '^(make)$'           { Do-Make $rest }
    '^(server)$'         { Do-Server $rest }
    '^(drivers)$'        { Do-Drivers $rest }
    '^(devices)$'        { Do-Devices $rest[0] }
    '^(ddi)$'            { Do-Ddi $rest[0] }
    '^(set)$'            { Do-Set $rest }
    '^(help|-h|--help)$' { Show-Help }
    default { Write-Host ("Unknown command: " + $group); Write-Host 'Run: flc help'; exit 1 }
}

# Normalize the exit code so captured stderr from native tools does not leak a
# non-zero status for an otherwise successful command.
exit 0
