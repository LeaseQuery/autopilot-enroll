<#
=====================================================================
 Windows Autopilot Enrollment - INTERNAL (FinQuery IT)
=====================================================================
 WHAT THIS DOES
   1. Builds the group tag from two questions: what kind of device it
      is (regular employee, contractor, AlternIT One or test machine),
      then its country - or, for a test machine, the account type.
      Defaults to a regular US employee (US-FinQuery) and continues on
      its own if nobody touches the keyboard.
   2. Asks the technician to sign in: scan the QR code (or open the
      link) on a phone and enter the code shown. The script holds no
      credentials - what it can do comes from that sign-in.
   3. Checks whether the device is already an Autopilot device.
        - already registered -> updates the group tag in place
        - new device         -> reads the hardware hash and uploads
                                it with the chosen group tag
   4. Writes a log file - next to this script on a flash drive,
      otherwise in C:\ProgramData\AutopilotEnroll.
   5. Hands the device back to a clean OOBE:
        - still in OOBE  -> restarts (nothing to reset)
        - fully built PC -> resets ("remove everything"), then restarts
      A 30 second countdown allows you to cancel. Nothing is wiped
      unless the upload succeeded first.

 *** THE RESET ERASES ALL DATA ON THE DEVICE. Only run this on new or
 *** already-backed-up machines.

 BEFORE YOU START
   Connect the device to the internet - wired, or via the Wi-Fi screen
   in OOBE - BEFORE running this script. Have your phone ready to sign
   in with an account that can register Autopilot devices in Intune.

 HOW TO RUN
   - In OOBE: press SHIFT + F10, then type:
         powershell -c "irm https://raw.githubusercontent.com/LeaseQuery/autopilot-enroll/main/go.ps1 | iex"
   - From a flash drive: keep Enroll.cmd next to this script.
       In OOBE: press SHIFT + F10, then type:   D:\Enroll
       (replace D: with the flash drive's letter)
   - On a built device: right-click Enroll.cmd > Run as administrator.
=====================================================================
#>

#requires -Version 5.1

# ------------------------- CONFIGURATION ---------------------------
# Entra ID tenant, and the app registration technicians sign in through.
# Neither value is a secret. The app has no client secret: what the
# script can do comes from the technician's own sign-in and Intune role.
$TenantId = 'd47c5463-2ec6-4dab-9afc-2ce85a8568fa'
$AppId    = '06658403-c7c5-4588-800e-7929036f18e1'

# Seconds before each menu's default (regular employee, then US) is
# applied automatically. Pressing any key pauses the countdown so you
# can choose at your leisure. The test machine menu has no default.
$TagSelectTimeoutSeconds = 15

# Set to $true to make the script wait until the Autopilot profile is
# assigned before finishing. Accurate, but can add 10-15 minutes.
$WaitForProfileAssignment = $false

# What to do after a SUCCESSFUL upload:
#   'Auto'   - restart if the device is still in OOBE (nothing to reset),
#              otherwise reset it back to a clean OOBE  [default]
#   'Ask'    - ask whether the device needs resetting
#   'Wipe'   - always reset to a clean OOBE (destroys all data)
#   'Reboot' - always just restart, never reset
#   'None'   - do nothing, leave the device running
$PostEnrollAction = 'Auto'

# Seconds to cancel the reset/restart by pressing a key.
$CountdownSeconds = 30
# -------------------------------------------------------------------


# ===================================================================
#  Nothing below here needs editing.
# ===================================================================

$ScriptVersion = '2026-09-24.4-internal'   # bump when editing
$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12

$ScriptDir = if ($PSScriptRoot) { $PSScriptRoot } else { (Get-Location).Path }
# On a flash drive the log goes next to the script, as before. When the
# script was downloaded to this PC, it goes somewhere that outlasts OOBE.
$LogDir  = if ($ScriptDir -like "$env:SystemDrive*") { Join-Path $env:ProgramData 'AutopilotEnroll' } else { $ScriptDir }
$Stamp   = Get-Date -Format 'yyyyMMdd-HHmmss'
$LogPath = Join-Path $LogDir "AutopilotEnroll-$env:COMPUTERNAME-$Stamp.log"

try {
    New-Item -ItemType Directory -Path $LogDir -Force | Out-Null
    Start-Transcript -Path $LogPath -Force | Out-Null
} catch { }

function Write-Step { param($m) Write-Host "`n[*] $m" -ForegroundColor Cyan }
function Write-Ok   { param($m) Write-Host "[OK] $m"  -ForegroundColor Green }
function Write-Warn { param($m) Write-Host "[!] $m"   -ForegroundColor Yellow }
function Write-Fail { param($m) Write-Host "[X] $m"   -ForegroundColor Red }

function Write-Rule {
    param([string]$Colour = 'DarkGray')
    Write-Host '  ---------------------------------------------------------------' -ForegroundColor $Colour
}

function Show-Banner {
    Clear-Host
    Write-Host ''
    Write-Host '  ===============================================================' -ForegroundColor DarkCyan
    Write-Host '     A U T O P I L O T   E N R O L L M E N T   -   I N T E R N A L' -ForegroundColor White
    Write-Host '  ===============================================================' -ForegroundColor DarkCyan
    Write-Host ''
    Write-Host "   Script version : $ScriptVersion" -ForegroundColor DarkGray
    Write-Host "   Device serial  : $((Get-CimInstance -ClassName Win32_BIOS).SerialNumber)"
    Write-Host "   Model          : $((Get-CimInstance -ClassName Win32_ComputerSystem).Model)"
    Write-Host ''
}

function Read-YesNo {
    param([string]$Question)
    while ($true) {
        Write-Host ''
        Write-Host "  $Question" -ForegroundColor Yellow
        $answer = Read-Host '  Type Y for Yes or N for No, then press Enter'
        switch -Regex ($answer.Trim()) {
            '^(y|yes)$' { return $true }
            '^(n|no)$'  { return $false }
            default     { Write-Warn 'Please answer Y or N.' }
        }
    }
}


# --- Group tag menus ------------------------------------------------
# The group tag is built from two answers:
#   Regular employee -> US-FinQuery      or <CC>-FinQuery
#   Contractor       -> US-FinQuery-CTR  or <CC>-FinQuery-CTR
#   AlternIT One     -> UK-AlternITOne   (no second question)
#   Test machine     -> Test-Standard-FinQuery or Test-Admin-FinQuery

$DeviceTypeMenu = @(
    @{ Key = '1'; Id = 'Regular'; Title = 'Regular employee'; Default = $true
       Desc = @('Standard FinQuery employee, remote or in office') }

    @{ Key = '2'; Id = 'Contractor'; Title = 'Contractor'
       Desc = @('FinQuery contractor. The group tag ends in -CTR, e.g. US-FinQuery-CTR') }

    @{ Key = '3'; Id = 'AlternIT'; Title = 'AlternIT One'
       Desc = @('Standard UK-based employee device managed by AlternIT One',
                '(group tag UK-AlternITOne)') }

    @{ Key = '4'; Id = 'Test'; Title = 'Test machine'; Test = $true
       Desc = @('TEST DEVICES ONLY. Exempts the device from security policies',
                '(base security configuration, CrowdStrike and EDR still apply)') }
)

$TestAccountMenu = @(
    @{ Key = '1'; Id = 'Standard'; Title = 'Standard user'; Test = $true
       Desc = @('Creates a standard user account (group tag Test-Standard-FinQuery)') }

    @{ Key = '2'; Id = 'Admin'; Title = 'Administrator'; Test = $true
       Desc = @('Creates an administrator account (group tag Test-Admin-FinQuery)') }
)

function Read-MenuChoice {
    # Shows a numbered menu and returns the chosen item. If an item is marked
    # Default, a countdown applies it on its own: a valid number selects,
    # Enter takes the default, and any other key pauses the countdown.
    param([string]$Heading, [object[]]$Items)

    Write-Host "  $Heading" -ForegroundColor White
    Write-Rule
    foreach ($item in $Items) {
        $titleColour = if ($item.Test) { 'Red' } elseif ($item.Default) { 'Green' } else { 'Cyan' }
        $suffix = if ($item.Default) { '   (default)' } else { '' }

        Write-Host ''
        Write-Host ("   [{0}]  " -f $item.Key) -NoNewline -ForegroundColor White
        Write-Host $item.Title -NoNewline -ForegroundColor $titleColour
        Write-Host $suffix -ForegroundColor DarkGreen
        foreach ($line in $item.Desc) {
            Write-Host "        $line" -ForegroundColor DarkGray
        }
    }
    Write-Host ''
    Write-Rule

    $valid   = $Items.Key
    $default = $Items | Where-Object { $_.Default } | Select-Object -First 1
    $choice  = $null
    $paused  = -not $default

    try { $Host.UI.RawUI.FlushInputBuffer() } catch { }

    # Countdown - any key pauses, a valid number selects, Enter takes default.
    for ($i = $TagSelectTimeoutSeconds; $i -gt 0 -and -not $choice -and -not $paused; $i--) {
        Write-Host ("`r  Continuing with {0} in {1,2}s   (1-{2} to choose, any other key to pause)  " `
                    -f $default.Title, $i, $Items.Count) -NoNewline -ForegroundColor Yellow
        for ($t = 0; $t -lt 10; $t++) {
            try {
                if ($Host.UI.RawUI.KeyAvailable) {
                    $key = $Host.UI.RawUI.ReadKey('NoEcho,IncludeKeyDown')
                    $ch  = [string]$key.Character
                    if ($valid -contains $ch)      { $choice = $ch }
                    elseif ($key.VirtualKeyCode -eq 13) { $choice = $default.Key }
                    else                            { $paused = $true }
                    break
                }
            } catch { $paused = $true; break }
            Start-Sleep -Milliseconds 100
        }
    }

    if ($default) {
        Write-Host ''
        # Timer ran out with no key pressed - apply the default and carry on.
        if (-not $choice -and -not $paused) {
            $choice = $default.Key
            Write-Ok "No selection made - continuing with the default, $($default.Title)."
        }
        if ($paused) {
            Write-Host ''
            Write-Host '  Paused - the default will not be applied automatically.' -ForegroundColor Yellow
        }
    }

    while (-not $choice) {
        $prompt = if ($default) { "  Choose 1-{0} (or press Enter for {1})" -f $Items.Count, $default.Title } else { "  Choose 1-{0}" -f $Items.Count }
        $entry = (Read-Host $prompt).Trim()
        if (-not $entry -and $default) {
            $choice = $default.Key
        } elseif ($valid -contains $entry) {
            $choice = $entry
        } else {
            Write-Warn ("Please enter a number between 1 and {0}." -f $Items.Count)
        }
    }

    return ($Items | Where-Object { $_.Key -eq $choice })
}

function Read-CountryCode {
    while ($true) {
        Write-Host ''
        Write-Host '  Enter the 2-letter country code for this device.' -ForegroundColor Yellow
        Write-Host '  Examples: UK United Kingdom | ZA South Africa | AU Australia' -ForegroundColor DarkGray
        Write-Host '            IE Ireland | DE Germany | IN India | CA Canada' -ForegroundColor DarkGray
        Write-Host '  Use UK for the United Kingdom, not GB.' -ForegroundColor DarkGray
        $code = (Read-Host '  Country code').Trim().ToUpper()
        if ($code -match '^[A-Z]{2}$') { return $code }
        Write-Warn 'Please enter exactly two letters, for example UK.'
    }
}

function Select-GroupTag {
    $type = Read-MenuChoice -Heading 'WHAT KIND OF DEVICE IS THIS?' -Items $DeviceTypeMenu

    if ($type.Id -eq 'AlternIT') {
        $tag = 'UK-AlternITOne'
    } else {
        Show-Banner
        Write-Host '   Device type    : ' -NoNewline
        Write-Host $type.Title -ForegroundColor Green
        Write-Host ''
        if ($type.Id -eq 'Test') {
            $account = Read-MenuChoice -Heading 'WHICH ACCOUNT SHOULD THE TEST MACHINE HAVE?' -Items $TestAccountMenu
            $tag = "Test-$($account.Id)-FinQuery"
        } else {
            $suffix = if ($type.Id -eq 'Contractor') { '-CTR' } else { '' }
            $countryMenu = @(
                @{ Key = '1'; Id = 'US'; Title = 'United States'; Default = $true
                   Desc = @("Group tag US-FinQuery$suffix") }

                @{ Key = '2'; Id = 'Other'; Title = 'Other country'
                   Desc = @('You will be asked for a 2-letter country code, e.g. UK',
                            "(group tag <CC>-FinQuery$suffix)") }
            )
            $country = Read-MenuChoice -Heading 'WHICH COUNTRY IS THE DEVICE FOR?' -Items $countryMenu
            $code = if ($country.Id -eq 'US') { 'US' } else { Read-CountryCode }
            $tag = "$code-FinQuery$suffix"
        }
    }

    # Test tags are consequential - confirm them explicitly.
    if ($type.Test) {
        Write-Host ''
        Write-Host '  ***************************************************************' -ForegroundColor Red
        Write-Host "   '$tag' is for TEST DEVICES ONLY."                                -ForegroundColor Red
        Write-Host '   It exempts this device from security policies.'                  -ForegroundColor Red
        Write-Host '  ***************************************************************' -ForegroundColor Red
        if (-not (Read-YesNo "Are you sure you want to apply '$tag' to this device?")) {
            Write-Warn 'Selection cancelled - starting again.'
            Show-Banner
            return (Select-GroupTag)
        }
    }

    return $tag
}


# --- OOBE / reset helpers -------------------------------------------

function Test-InOobe {
    # True if Windows has not finished out-of-box setup yet.
    #
    # NOTE: do NOT use ImageState for this. It already reads
    # IMAGE_STATE_COMPLETE while the user-facing OOBE screens are still
    # showing, which makes a device in OOBE look like a fully built PC.
    # Nor 'msoobe' - the Windows 10/11 OOBE UI is not that process.

    foreach ($name in 'OOBEInProgress','SystemSetupInProgress') {
        try {
            $v = (Get-ItemProperty -Path 'HKLM:\SYSTEM\Setup' -Name $name -ErrorAction Stop).$name
            if ($v -ne 0) { return $true }
        } catch { }
    }
    if (Test-Path (Join-Path $env:SystemDrive 'Users\defaultuser0')) { return $true }
    if (Get-Process -Name msoobe,oobeldr -ErrorAction SilentlyContinue) { return $true }
    if (-not (Get-Process -Name explorer -ErrorAction SilentlyContinue)) { return $true }
    return $false
}

function Wait-WithCancel {
    param([int]$Seconds, [string]$ActionText)
    try { $Host.UI.RawUI.FlushInputBuffer() } catch { }
    for ($i = $Seconds; $i -gt 0; $i--) {
        Write-Host ("`r  {0} in {1,3} seconds...  (press any key to CANCEL)  " -f $ActionText, $i) `
            -NoNewline -ForegroundColor Yellow
        try {
            if ($Host.UI.RawUI.KeyAvailable) {
                $Host.UI.RawUI.ReadKey('NoEcho,IncludeKeyDown') | Out-Null
                Write-Host ''
                return $false
            }
        } catch { }
        Start-Sleep -Seconds 1
    }
    Write-Host ''
    return $true
}

function Invoke-DeviceWipe {
    # Scripted "Reset this PC / remove everything" via the MDM RemoteWipe CSP.
    # Uses the protected variant so an interrupted wipe resumes on next boot.
    $namespace = 'root\cimv2\mdm\dmmap'
    $class     = 'MDM_RemoteWipe'
    $filter    = "ParentID='./Vendor/MSFT' and InstanceID='RemoteWipe'"

    try {
        $instance = Get-CimInstance -Namespace $namespace -ClassName $class -Filter $filter -ErrorAction Stop
        $session  = New-CimSession -ErrorAction Stop
    } catch {
        Write-Warn "RemoteWipe CSP unavailable: $($_.Exception.Message)"
        $instance = $null
    }

    if ($instance) {
        foreach ($method in 'doWipeProtectedMethod','doWipeMethod') {
            try {
                $params = New-Object Microsoft.Management.Infrastructure.CimMethodParametersCollection
                $params.Add([Microsoft.Management.Infrastructure.CimMethodParameter]::Create('param','','String','In'))
                $session.InvokeMethod($namespace, $instance, $method, $params) | Out-Null
                Write-Ok "Wipe initiated ($method). The device will restart on its own."
                return $true
            } catch {
                Write-Warn "$method failed: $($_.Exception.Message)"
            }
        }
    }

    # Fallback 1: the built-in reset engine.
    $sysreset = Join-Path $env:SystemRoot 'System32\systemreset.exe'
    if (Test-Path $sysreset) {
        foreach ($resetArg in '--factoryreset','-factoryreset') {
            try {
                Write-Warn "Falling back to systemreset.exe $resetArg"
                Start-Process -FilePath $sysreset -ArgumentList $resetArg -ErrorAction Stop
                Start-Sleep -Seconds 10
                if (Get-Process -Name systemreset -ErrorAction SilentlyContinue) {
                    Write-Ok 'Reset launched via systemreset.exe.'
                    Write-Host ''
                    Write-Host '   If a screen appears, choose: Remove everything' -ForegroundColor Yellow
                    return $true
                }
                Write-Warn 'systemreset.exe exited immediately.'
            } catch {
                Write-Warn "systemreset.exe $resetArg failed: $($_.Exception.Message)"
            }
        }
    } else {
        Write-Warn "systemreset.exe is not present on this image ($sysreset)."
    }

    # Fallback 2: boot into the recovery environment.
    $eap = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        Write-Warn 'Falling back to the Windows recovery environment (WinRE).'

        $info = (& reagentc.exe /info) 2>&1 | Out-String
        if ($info -notmatch 'Enabled') {
            Write-Warn 'WinRE appears to be disabled. Attempting to enable it.'
            (& reagentc.exe /enable) 2>&1 | Out-Null
        }

        (& reagentc.exe /boottore) 2>&1 | Out-Null
        if ($LASTEXITCODE -ne 0) { throw "reagentc /boottore returned $LASTEXITCODE" }

        Write-Ok 'The device will start in the recovery environment.'
        Write-Host ''
        Write-Host '   *** ACTION REQUIRED AFTER THE RESTART ***'               -ForegroundColor Yellow
        Write-Host '   On the recovery screen, choose:'                         -ForegroundColor Yellow
        Write-Host '     Troubleshoot  >  Reset this PC  >  Remove everything'  -ForegroundColor Yellow
        Write-Host ''

        if (Wait-WithCancel -Seconds 20 -ActionText 'Restarting into recovery') {
            try { Stop-Transcript | Out-Null } catch { }
            Restart-Computer -Force
        }
        return $true
    } catch {
        Write-Warn "reagentc failed: $($_.Exception.Message)"
    } finally {
        $ErrorActionPreference = $eap
    }

    return $false
}


# --- QR code --------------------------------------------------------
# A small QR code encoder (ISO/IEC 18004) so the sign-in link can be
# scanned with a phone, with no modules to download. Byte mode, error
# correction level M, versions 1-6 (up to 106 bytes) - plenty for a URL.

function New-QrCode {
    # Returns @{ Size = <modules per side>; Dark = <bool[] indexed y * Size + x> }.
    # -Mask forces a mask pattern (0-7); by default the best-scoring one is used.
    param([Parameter(Mandatory = $true)][string]$Text, [int]$Mask = -1)

    # Level M block structure by version (index 1-6): total codewords,
    # error correction codewords per block, and number of blocks.
    $totalCodewords = @(0, 26, 44, 70, 100, 134, 172)
    $eccPerBlock    = @(0, 10, 16, 26, 18, 24, 16)
    $blockCount     = @(0,  1,  1,  1,  2,  2,  4)
    $alignCentre    = @(0,  0, 18, 22, 26, 30, 34)

    $bytes   = [Text.Encoding]::UTF8.GetBytes($Text)
    $version = 0
    for ($v = 1; $v -le 6; $v++) {
        $capacity = $totalCodewords[$v] - $eccPerBlock[$v] * $blockCount[$v]
        if (12 + 8 * $bytes.Length -le 8 * $capacity) { $version = $v; break }
    }
    if (-not $version) { throw "Text is too long for a QR code: $Text" }
    $dataCodewords = $totalCodewords[$version] - $eccPerBlock[$version] * $blockCount[$version]
    $ecc  = $eccPerBlock[$version]
    $size = 17 + 4 * $version

    # 1. Data bits: byte-mode indicator, length, data, terminator, padding.
    $bits = New-Object System.Collections.Generic.List[int]
    function Add-Bits([int]$Value, [int]$Count) {
        for ($i = $Count - 1; $i -ge 0; $i--) { $bits.Add(($Value -shr $i) -band 1) }
    }
    Add-Bits 4 4
    Add-Bits $bytes.Length 8
    foreach ($b in $bytes) { Add-Bits $b 8 }
    Add-Bits 0 ([Math]::Min(4, 8 * $dataCodewords - $bits.Count))
    while ($bits.Count % 8) { $bits.Add(0) }

    $data = New-Object System.Collections.Generic.List[int]
    for ($i = 0; $i -lt $bits.Count; $i += 8) {
        $byte = 0
        for ($j = 0; $j -lt 8; $j++) { $byte = ($byte -shl 1) -bor $bits[$i + $j] }
        $data.Add($byte)
    }
    for ($pad = 0xEC; $data.Count -lt $dataCodewords; $pad = $pad -bxor 0xFD) { $data.Add($pad) }   # 0xEC, 0x11, ...

    # 2. Reed-Solomon error correction over GF(256), polynomial 0x11D.
    $exp = New-Object int[] 512
    $log = New-Object int[] 256
    $x = 1
    for ($i = 0; $i -lt 255; $i++) {
        $exp[$i] = $x; $exp[$i + 255] = $x; $log[$x] = $i
        $x = $x -shl 1
        if ($x -band 0x100) { $x = $x -bxor 0x11D }
    }
    # Generator polynomial (x - a^0)(x - a^1)...(x - a^(ecc-1)), highest power first.
    $gen = New-Object int[] ($ecc + 1)
    $gen[0] = 1
    for ($i = 0; $i -lt $ecc; $i++) {
        for ($j = $i + 1; $j -ge 1; $j--) {
            if ($gen[$j - 1]) { $gen[$j] = $gen[$j] -bxor $exp[$log[$gen[$j - 1]] + $i] }
        }
    }

    # Level M splits the data evenly across blocks for versions 1-6.
    $perBlock   = [int]($dataCodewords / $blockCount[$version])
    $dataBlocks = @()
    $eccBlocks  = @()
    for ($b = 0; $b -lt $blockCount[$version]; $b++) {
        $chunk = $data.GetRange($b * $perBlock, $perBlock).ToArray()
        $rem   = New-Object int[] $ecc
        foreach ($d in $chunk) {
            $factor = $d -bxor $rem[0]
            for ($k = 0; $k -lt $ecc - 1; $k++) { $rem[$k] = $rem[$k + 1] }
            $rem[$ecc - 1] = 0
            if ($factor) {
                for ($k = 0; $k -lt $ecc; $k++) {
                    if ($gen[$k + 1]) { $rem[$k] = $rem[$k] -bxor $exp[$log[$gen[$k + 1]] + $log[$factor]] }
                }
            }
        }
        $dataBlocks += ,$chunk
        $eccBlocks  += ,$rem
    }
    $codewords = New-Object System.Collections.Generic.List[int]
    for ($i = 0; $i -lt $perBlock; $i++) { foreach ($blk in $dataBlocks) { $codewords.Add($blk[$i]) } }
    for ($i = 0; $i -lt $ecc; $i++)      { foreach ($blk in $eccBlocks)  { $codewords.Add($blk[$i]) } }

    # 3. Function patterns. $fixed marks modules that data and masks must skip.
    $dark  = New-Object bool[] ($size * $size)
    $fixed = New-Object bool[] ($size * $size)
    function Set-Fixed([int]$X, [int]$Y, [bool]$On) {
        $dark[$Y * $size + $X] = $On
        $fixed[$Y * $size + $X] = $true
    }
    function Set-FormatBits([int]$MaskId) {
        # Level M is 00, so the five data bits are just the mask number.
        $rem = $MaskId
        for ($i = 0; $i -lt 10; $i++) { $rem = ($rem -shl 1) -bxor (($rem -shr 9) * 0x537) }
        $fmt = (($MaskId -shl 10) -bor $rem) -bxor 0x5412
        for ($i = 0; $i -le 5; $i++)  { Set-Fixed 8 $i ((($fmt -shr $i) -band 1) -eq 1) }
        Set-Fixed 8 7 ((($fmt -shr 6) -band 1) -eq 1)
        Set-Fixed 8 8 ((($fmt -shr 7) -band 1) -eq 1)
        Set-Fixed 7 8 ((($fmt -shr 8) -band 1) -eq 1)
        for ($i = 9; $i -lt 15; $i++) { Set-Fixed (14 - $i) 8 ((($fmt -shr $i) -band 1) -eq 1) }
        for ($i = 0; $i -lt 8; $i++)  { Set-Fixed ($size - 1 - $i) 8 ((($fmt -shr $i) -band 1) -eq 1) }
        for ($i = 8; $i -lt 15; $i++) { Set-Fixed 8 ($size - 15 + $i) ((($fmt -shr $i) -band 1) -eq 1) }
        Set-Fixed 8 ($size - 8) $true   # the always-dark module
    }

    for ($i = 0; $i -lt $size; $i++) {
        Set-Fixed 6 $i ($i % 2 -eq 0)
        Set-Fixed $i 6 ($i % 2 -eq 0)
    }
    foreach ($centre in @(@(3, 3), @(($size - 4), 3), @(3, ($size - 4)))) {
        for ($dy = -4; $dy -le 4; $dy++) {
            for ($dx = -4; $dx -le 4; $dx++) {
                $x = $centre[0] + $dx; $y = $centre[1] + $dy
                if ($x -ge 0 -and $x -lt $size -and $y -ge 0 -and $y -lt $size) {
                    $dist = [Math]::Max([Math]::Abs($dx), [Math]::Abs($dy))
                    Set-Fixed $x $y ($dist -ne 2 -and $dist -ne 4)
                }
            }
        }
    }
    if ($version -ge 2) {
        $a = $alignCentre[$version]
        for ($dy = -2; $dy -le 2; $dy++) {
            for ($dx = -2; $dx -le 2; $dx++) {
                Set-Fixed ($a + $dx) ($a + $dy) ([Math]::Max([Math]::Abs($dx), [Math]::Abs($dy)) -ne 1)
            }
        }
    }
    Set-FormatBits 0   # reserves the format areas; redrawn for each mask below

    # 4. Data, in two-column strips zig-zagging up and down from the bottom right.
    $bitIndex  = 0
    $totalBits = $codewords.Count * 8
    for ($right = $size - 1; $right -ge 1; $right -= 2) {
        if ($right -eq 6) { $right = 5 }   # skip the vertical timing pattern
        $upward = (($right + 1) -band 2) -eq 0
        for ($vert = 0; $vert -lt $size; $vert++) {
            $y = if ($upward) { $size - 1 - $vert } else { $vert }
            for ($j = 0; $j -lt 2; $j++) {
                $idx = $y * $size + $right - $j
                if (-not $fixed[$idx] -and $bitIndex -lt $totalBits) {
                    $dark[$idx] = (($codewords[$bitIndex -shr 3] -shr (7 - ($bitIndex -band 7))) -band 1) -eq 1
                    $bitIndex++
                }
            }
        }
    }

    # 5. Masking: try each pattern and keep the one with the lowest penalty.
    $masks = if ($Mask -ge 0) { @($Mask) } else { 0..7 }
    $best = $null
    $bestPenalty = [int]::MaxValue
    foreach ($m in $masks) {
        Set-FormatBits $m
        $candidate = [bool[]]$dark.Clone()
        for ($y = 0; $y -lt $size; $y++) {
            for ($x = 0; $x -lt $size; $x++) {
                $idx = $y * $size + $x
                if ($fixed[$idx]) { continue }
                $flip = switch ($m) {
                    0 { ($x + $y) % 2 -eq 0 }
                    1 { $y % 2 -eq 0 }
                    2 { $x % 3 -eq 0 }
                    3 { ($x + $y) % 3 -eq 0 }
                    4 { ([Math]::Floor($x / 3) + [Math]::Floor($y / 2)) % 2 -eq 0 }
                    5 { ($x * $y) % 2 + ($x * $y) % 3 -eq 0 }
                    6 { (($x * $y) % 2 + ($x * $y) % 3) % 2 -eq 0 }
                    7 { (($x + $y) % 2 + ($x * $y) % 3) % 2 -eq 0 }
                }
                if ($flip) { $candidate[$idx] = -not $candidate[$idx] }
            }
        }
        $penalty = if ($masks.Count -gt 1) { Get-QrPenalty -Dark $candidate -Size $size } else { 0 }
        if ($penalty -lt $bestPenalty) { $best = $candidate; $bestPenalty = $penalty }
    }

    return @{ Size = $size; Dark = $best }
}

function Get-QrPenalty {
    # The standard mask penalty rules. Rows and columns become '0'/'1'
    # strings so the run and pattern rules can use fast string searches.
    param([bool[]]$Dark, [int]$Size)

    $lines = New-Object System.Collections.Generic.List[string]
    $chars = New-Object char[] $Size
    for ($y = 0; $y -lt $Size; $y++) {
        for ($x = 0; $x -lt $Size; $x++) { $chars[$x] = if ($Dark[$y * $Size + $x]) { '1' } else { '0' } }
        $lines.Add((-join $chars))
    }
    for ($x = 0; $x -lt $Size; $x++) {
        for ($y = 0; $y -lt $Size; $y++) { $chars[$y] = if ($Dark[$y * $Size + $x]) { '1' } else { '0' } }
        $lines.Add((-join $chars))
    }

    $penalty = 0
    foreach ($line in $lines) {
        # Runs of five or more modules of one colour: 3 points, +1 per extra module.
        foreach ($run in [regex]::Matches($line, '0{5,}|1{5,}')) { $penalty += $run.Length - 2 }
        # Finder-like 1:1:3:1:1 patterns with four light modules on one side.
        foreach ($pattern in '10111010000', '00001011101') {
            $at = $line.IndexOf($pattern)
            while ($at -ge 0) { $penalty += 40; $at = $line.IndexOf($pattern, $at + 1) }
        }
    }
    # 2x2 blocks of one colour.
    for ($y = 0; $y -lt $Size - 1; $y++) {
        for ($x = 0; $x -lt $Size - 1; $x++) {
            $i = $y * $Size + $x
            $c = $Dark[$i]
            if ($Dark[$i + 1] -eq $c -and $Dark[$i + $Size] -eq $c -and $Dark[$i + $Size + 1] -eq $c) { $penalty += 3 }
        }
    }
    # Balance of dark and light: 10 points per 5% away from half.
    $darkCount = 0
    foreach ($d in $Dark) { if ($d) { $darkCount++ } }
    $penalty += 10 * [Math]::Floor([Math]::Abs($darkCount * 100 / $Dark.Length - 50) / 5)
    return $penalty
}

function Get-QrLines {
    # Lays the code out two modules per text line using the upper half block
    # (U+2580): its foreground paints the top module and the background paints
    # the bottom one, so the code stays square and fits on screen. Dark modules
    # are black on a white quiet zone. Returns one array of colour runs per line.
    param($Qr, [int]$QuietZone = 4)

    $n     = $Qr.Size
    $cells = $Qr.Dark
    $full  = $n + 2 * $QuietZone
    $half  = [string][char]0x2580
    $lines = @()
    for ($y = 0; $y -lt $full; $y += 2) {
        $runs = New-Object System.Collections.Generic.List[object]
        for ($x = 0; $x -lt $full; $x++) {
            $mx = $x - $QuietZone
            $ty = $y - $QuietZone
            $by = $ty + 1
            $top = $mx -ge 0 -and $mx -lt $n -and $ty -ge 0 -and $ty -lt $n -and $cells[$ty * $n + $mx]
            $bot = $mx -ge 0 -and $mx -lt $n -and $by -ge 0 -and $by -lt $n -and $cells[$by * $n + $mx]
            $fg  = if ($top) { 'Black' } else { 'White' }
            $bg  = if ($bot) { 'Black' } else { 'White' }
            $ch  = if ($top -eq $bot) { ' ' } else { $half }
            $last = if ($runs.Count) { $runs[$runs.Count - 1] } else { $null }
            if ($last -and $last.Ch -eq $ch -and $last.Fg -eq $fg -and $last.Bg -eq $bg) {
                $last.Text += $ch
            } else {
                $runs.Add(@{ Ch = $ch; Text = $ch; Fg = $fg; Bg = $bg })
            }
        }
        $lines += ,$runs.ToArray()
    }
    return ,$lines
}

function Write-QrLine {
    param($Runs)
    foreach ($r in $Runs) { Write-Host $r.Text -NoNewline -ForegroundColor $r.Fg -BackgroundColor $r.Bg }
}


# --- Sign-in (device code flow) -------------------------------------
# The technician signs in on their phone. The token only ever exists in
# this PowerShell session's memory and is gone when the window closes.

$GraphScope = 'https://graph.microsoft.com/DeviceManagementServiceConfig.ReadWrite.All'

function Get-AadErrorText {
    # The readable part of an Entra ID error response.
    param($ErrorRecord)
    try {
        $e = $ErrorRecord.ErrorDetails.Message | ConvertFrom-Json
        if ($e.error_description) { return ($e.error_description -split "`r?`n")[0] }
    } catch { }
    return $ErrorRecord.Exception.Message
}

function Get-SignedInUser {
    # The ID token is issued to this app, so reading its claims is supported
    # (unlike the Graph access token). Used for the screen and the log only.
    param([string]$IdToken)
    try {
        $payload  = $IdToken.Split('.')[1].Replace('-', '+').Replace('_', '/')
        $payload += '=' * ((4 - $payload.Length % 4) % 4)
        $claims   = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($payload)) | ConvertFrom-Json
        if ($claims.preferred_username) { return $claims.preferred_username }
        if ($claims.name) { return $claims.name }
    } catch { }
    return 'an unknown account'
}

function Show-SignInPrompt {
    param([string]$Uri, [string]$Code, [string]$GroupTag)

    Clear-Host
    Write-Host ''
    Write-Host '  AUTOPILOT ENROLLMENT - SIGN IN' -NoNewline -ForegroundColor White
    Write-Host "      group tag: $GroupTag" -ForegroundColor DarkGray

    $qrLines = $null
    try { $qrLines = Get-QrLines (New-QrCode -Text $Uri) } catch { }

    $width = 0
    try { $width = $Host.UI.RawUI.WindowSize.Width } catch { }
    if ($width -le 0) { $width = 120 }
    $qrWidth = 0
    if ($qrLines) { foreach ($r in $qrLines[0]) { $qrWidth += $r.Text.Length } }
    if ($qrWidth + 4 -gt $width) { $qrLines = $null }

    $steps = @(
        @{ T = '1. Scan the QR code with your phone, or go to:'; F = 'Gray' }
        @{ T = $Uri; F = 'Cyan'; Pad = 6 }
        @{ T = '' }
        @{ T = '2. Enter this code:'; F = 'Gray' }
        @{ T = "  $Code  "; F = 'Black'; B = 'Yellow'; Pad = 5 }
        @{ T = '' }
        @{ T = '3. Sign in with your FinQuery account. It needs Intune'; F = 'Gray' }
        @{ T = '   permission to register Autopilot devices.'; F = 'Gray' }
    )

    Write-Host ''
    if ($qrLines -and $width -ge 2 + $qrWidth + 3 + 58) {
        # Instructions beside the code, starting a few lines down.
        $offset = [Math]::Max(0, [int](($qrLines.Count - $steps.Count) / 2))
        for ($i = 0; $i -lt $qrLines.Count; $i++) {
            Write-Host '  ' -NoNewline
            Write-QrLine $qrLines[$i]
            Write-Host '   ' -NoNewline
            $s = $i - $offset
            if ($s -ge 0 -and $s -lt $steps.Count) { Write-StepText $steps[$s] }
            Write-Host ''
        }
    } else {
        # Narrow window: instructions below the code (or on their own).
        foreach ($line in $qrLines) { Write-Host '  ' -NoNewline; Write-QrLine $line; Write-Host '' }
        Write-Host ''
        foreach ($step in $steps) { Write-Host '  ' -NoNewline; Write-StepText $step; Write-Host '' }
    }
    Write-Host ''
}

function Write-StepText {
    param($Step)
    if (-not $Step.T) { return }
    if ($Step.Pad) { Write-Host (' ' * $Step.Pad) -NoNewline }
    $p = @{ Object = $Step.T; NoNewline = $true }
    if ($Step.F) { $p.ForegroundColor = $Step.F }
    if ($Step.B) { $p.BackgroundColor = $Step.B }
    Write-Host @p
}

function Connect-Intune {
    # Returns @{ Token; User }, or throws with the reason sign-in failed.
    param([string]$GroupTag)

    $authority = "https://login.microsoftonline.com/$TenantId/oauth2/v2.0"
    try {
        $dc = Invoke-RestMethod -Method POST -Uri "$authority/devicecode" `
                -Body @{ client_id = $AppId; scope = "openid profile $GraphScope" }
    } catch {
        throw "Could not start sign-in: $(Get-AadErrorText $_)"
    }

    Show-SignInPrompt -Uri $dc.verification_uri -Code $dc.user_code -GroupTag $GroupTag

    $interval = [Math]::Max(1, [int]$dc.interval)
    $deadline = (Get-Date).AddSeconds([int]$dc.expires_in)
    while ((Get-Date) -lt $deadline) {
        Write-Host ("`r  Waiting for sign-in... the code expires in {0:mm\:ss}   " -f ($deadline - (Get-Date))) `
            -NoNewline -ForegroundColor DarkGray
        Start-Sleep -Seconds $interval
        try {
            $tok = Invoke-RestMethod -Method POST -Uri "$authority/token" -Body @{
                grant_type  = 'urn:ietf:params:oauth:grant-type:device_code'
                client_id   = $AppId
                device_code = $dc.device_code
            }
            Write-Host ''
            return @{ Token = $tok.access_token; User = (Get-SignedInUser $tok.id_token) }
        } catch {
            $err = $null
            try { $err = $_.ErrorDetails.Message | ConvertFrom-Json } catch { }
            if ($err.error -eq 'authorization_pending') { continue }
            if ($err.error -eq 'slow_down') { $interval += 5; continue }
            Write-Host ''
            throw "Sign-in failed: $(Get-AadErrorText $_)"
        }
    }
    Write-Host ''
    throw 'The code expired before anyone signed in.'
}


# --- Microsoft Graph helpers ----------------------------------------

function Get-GraphErrorText {
    param($ErrorRecord)
    $status = $null
    try { $status = [int]$ErrorRecord.Exception.Response.StatusCode } catch { }
    $text = $null
    try { $text = ($ErrorRecord.ErrorDetails.Message | ConvertFrom-Json).error.message } catch { }
    if (-not $text) { $text = $ErrorRecord.Exception.Message }
    if ($status -eq 401 -or $status -eq 403) {
        return "Access denied ($status). The signed-in account needs an Intune role that can manage Autopilot devices. $text"
    }
    return $text
}

function Get-AutopilotDeviceBySerial {
    param([string]$Token, [string]$Serial)

    # Single quotes inside an OData string literal are escaped by doubling.
    $literal = $Serial.Replace("'", "''")
    $filter  = [uri]::EscapeDataString("contains(serialNumber,'$literal')")
    $uri     = "https://graph.microsoft.com/v1.0/deviceManagement/windowsAutopilotDeviceIdentities?`$filter=$filter"

    $resp = Invoke-RestMethod -Uri $uri -Method GET -Headers @{ Authorization = "Bearer $Token" }
    return $resp.value | Where-Object { $_.serialNumber -eq $Serial } | Select-Object -First 1
}

function Set-AutopilotGroupTag {
    param([string]$Token, [string]$Id, [string]$GroupTag)

    $uri  = "https://graph.microsoft.com/v1.0/deviceManagement/windowsAutopilotDeviceIdentities/$Id/updateDeviceProperties"
    $body = @{ groupTag = $GroupTag } | ConvertTo-Json
    Invoke-RestMethod -Uri $uri -Method POST -Body $body `
        -Headers @{ Authorization = "Bearer $Token"; 'Content-Type' = 'application/json' } | Out-Null
}

function Invoke-AutopilotSync {
    param([string]$Token)
    # Best effort - the service throttles this to roughly once every 10 minutes.
    try {
        Invoke-RestMethod -Method POST -Headers @{ Authorization = "Bearer $Token" } `
            -Uri 'https://graph.microsoft.com/beta/deviceManagement/windowsAutopilotSettings/sync' | Out-Null
    } catch { }
}

function Get-HardwareHash {
    # Same MDM WMI bridge (root\cimv2\mdm\dmmap) that Invoke-DeviceWipe uses.
    # DeviceHardwareData is the base64 hardware hash from the DevDetail CSP.
    $detail = Get-CimInstance -Namespace 'root\cimv2\mdm\dmmap' -ClassName MDM_DevDetail_Ext01 `
                -Filter "InstanceID='Ext' AND ParentID='./DevDetail'"
    if (-not $detail -or -not $detail.DeviceHardwareData) {
        throw 'Windows did not return a hardware hash. Run elevated on Windows 10 1703 or later.'
    }
    return $detail.DeviceHardwareData
}

function Import-AutopilotDevice {
    # Uploads the hash and waits for the Autopilot service to accept or
    # reject it. Throws with the service's reason if it wasn't accepted.
    param([string]$Token, [string]$Serial, [string]$Hash, [string]$GroupTag)

    $base    = 'https://graph.microsoft.com/v1.0/deviceManagement/importedWindowsAutopilotDeviceIdentities'
    $headers = @{ Authorization = "Bearer $Token" }
    $body    = @{
        '@odata.type'      = '#microsoft.graph.importedWindowsAutopilotDeviceIdentity'
        serialNumber       = $Serial
        hardwareIdentifier = $Hash        # already base64, which is what Graph expects
        groupTag           = $GroupTag
    } | ConvertTo-Json

    $import = Invoke-RestMethod -Method POST -Uri $base -Headers $headers `
                -ContentType 'application/json; charset=utf-8' -Body $body

    # The import runs in the background. Poll until the service reports a result.
    $deadline = (Get-Date).AddMinutes(10)
    while ($import.state.deviceImportStatus -in 'unknown', 'pending' -and (Get-Date) -lt $deadline) {
        Write-Host '.' -NoNewline -ForegroundColor DarkGray
        Start-Sleep -Seconds 15
        $import = Invoke-RestMethod -Uri "$base/$($import.id)" -Headers $headers
    }
    Write-Host ''
    $state = $import.state

    if ($state.deviceImportStatus -in 'unknown', 'pending') {
        throw ('The Autopilot service is still processing the upload after 10 minutes. ' +
               'Check for the device in Intune before running this again.')
    }

    # The import record only tracks status. Clean it up whatever the result.
    try { Invoke-RestMethod -Method DELETE -Uri "$base/$($import.id)" -Headers $headers | Out-Null } catch { }

    if ($state.deviceImportStatus -ne 'complete') {
        throw ("The Autopilot service rejected the upload: $($state.deviceErrorName) " +
               "(status $($state.deviceImportStatus), code $($state.deviceErrorCode))")
    }
}

function Wait-AutopilotDevice {
    # After an import the device appears in Intune's Autopilot device list
    # once the service syncs. Returns the device, or $null on timeout.
    param([string]$Token, [string]$Serial, [int]$Minutes)

    Invoke-AutopilotSync -Token $Token
    $deadline = (Get-Date).AddMinutes($Minutes)
    do {
        $device = $null
        try { $device = Get-AutopilotDeviceBySerial -Token $Token -Serial $Serial } catch { }
        if ($device) { Write-Host ''; return $device }
        Write-Host '.' -NoNewline -ForegroundColor DarkGray
        Start-Sleep -Seconds 20
    } while ((Get-Date) -lt $deadline)
    Write-Host ''
    return $null
}

function Wait-ProfileAssignment {
    # deploymentProfileAssignmentStatus is only in the Graph beta endpoint.
    param([string]$Token, [string]$Id, [int]$Minutes)

    $uri = "https://graph.microsoft.com/beta/deviceManagement/windowsAutopilotDeviceIdentities/$Id"
    $deadline = (Get-Date).AddMinutes($Minutes)
    do {
        try {
            $device = Invoke-RestMethod -Uri $uri -Headers @{ Authorization = "Bearer $Token" }
            if ($device.deploymentProfileAssignmentStatus -like 'assigned*') { Write-Host ''; return $true }
        } catch { }
        Write-Host '.' -NoNewline -ForegroundColor DarkGray
        Start-Sleep -Seconds 30
    } while ((Get-Date) -lt $deadline)
    Write-Host ''
    return $false
}

function Exit-Script {
    param([int]$Code = 0, [string]$Message)
    if ($Message) { Write-Host "`n$Message" }
    Write-Host "`nLog saved to: $LogPath"
    try { Stop-Transcript | Out-Null } catch { }
    Write-Host ''
    Read-Host 'Press Enter to close'
    exit $Code
}


# --- Pre-flight -----------------------------------------------------
Show-Banner

if (-not [Environment]::Is64BitProcess) {
    Write-Fail 'This is running in 32-bit PowerShell.'
    Write-Host  'Please re-run using: C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe'
    Exit-Script -Code 1
}

$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
               [Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    Write-Fail 'This needs to run as administrator.'
    Write-Host  'In OOBE, SHIFT + F10 is already elevated. On a built device, right-click'
    Write-Host  'Enroll.cmd > Run as administrator, or use an elevated PowerShell window.'
    Exit-Script -Code 1
}

if ($TenantId -like 'REPLACE-*' -or $AppId -like 'REPLACE-*') {
    Write-Fail 'The script has not been configured with the tenant and app registration IDs.'
    Exit-Script -Code 1
}


# --- Group tag ------------------------------------------------------
$tagToApply = Select-GroupTag

Write-Host ''
Write-Rule
Write-Host '   Group tag  : ' -NoNewline
Write-Host $tagToApply -ForegroundColor Green
Write-Rule


# --- Connectivity ---------------------------------------------------
Write-Step 'Checking internet connectivity...'
$connected = $false
foreach ($i in 1..12) {
    try {
        $r = Invoke-WebRequest -Uri 'https://login.microsoftonline.com' -UseBasicParsing -TimeoutSec 10
        if ($r.StatusCode -ge 200) { $connected = $true; break }
    } catch {
        Write-Warn "No connection yet (attempt $i of 12). Retrying in 10s..."
        Start-Sleep -Seconds 10
    }
}
if (-not $connected) {
    Write-Fail 'Could not reach Microsoft online services.'
    Write-Host  'Connect the device to the internet - plug in an Ethernet cable, or'
    Write-Host  'use the Wi-Fi screen in OOBE - then run this again.'
    Exit-Script -Code 1
}
Write-Ok 'Internet connection confirmed.'


# --- Sign in --------------------------------------------------------
$graphToken = $null
while (-not $graphToken) {
    try {
        $signIn     = Connect-Intune -GroupTag $tagToApply
        $graphToken = $signIn.Token
    } catch {
        Write-Fail $_.Exception.Message
        if (-not (Read-YesNo 'Try signing in again?')) {
            Exit-Script -Code 1 -Message 'Not signed in. Nothing was changed on this device.'
        }
    }
}

Show-Banner
Write-Ok "Signed in as $($signIn.User)."
Write-Host ''
Write-Rule
Write-Host '   Group tag  : ' -NoNewline
Write-Host $tagToApply -ForegroundColor Green
Write-Rule
Write-Host ''
Write-Host '  Starting enrollment. This usually takes 2-5 minutes. Do not close' -ForegroundColor Gray
Write-Host '  this window or restart the device until it says COMPLETE.'          -ForegroundColor Gray


# --- Already registered? --------------------------------------------
# If this device is already an Autopilot device, re-importing it fails with
# ZtdDeviceAlreadyAssigned. Update the group tag in place instead.

$Serial   = (Get-CimInstance -ClassName Win32_BIOS).SerialNumber.Trim()
$uploadOk = $false
$existing = $null

Write-Step 'Checking whether this device is already registered...'
try {
    $existing = Get-AutopilotDeviceBySerial -Token $graphToken -Serial $Serial
} catch {
    Write-Warn "Could not query the Autopilot service: $(Get-GraphErrorText $_)"
    Write-Warn 'Continuing as if the device is new.'
}

if ($existing) {
    $currentTag = if ($existing.groupTag) { $existing.groupTag } else { '(none)' }
    Write-Ok "Device is already registered. Current group tag: $currentTag"

    if ($existing.groupTag -eq $tagToApply) {
        Write-Ok "Group tag is already '$tagToApply' - nothing to change."
        $uploadOk = $true
    } else {
        Write-Step "Changing group tag from '$currentTag' to '$tagToApply'..."
        try {
            Set-AutopilotGroupTag -Token $graphToken -Id $existing.id -GroupTag $tagToApply
            Invoke-AutopilotSync -Token $graphToken
            Write-Ok "Group tag updated to '$tagToApply'."
            $uploadOk = $true
        } catch {
            Write-Fail "Could not update the group tag: $(Get-GraphErrorText $_)"
        }
    }

    if ($uploadOk) {
        Write-Host ''
        Write-Warn 'Group tag changes take a few minutes to flow through to the'
        Write-Warn 'dynamic group and the assigned Autopilot profile. If this device'
        Write-Warn 'is already deployed, it needs a reset to pick up a new profile.'
    }
}


# --- New device: upload the hardware hash ---------------------------
if (-not $existing) {
    Write-Step "Registering the device with Autopilot as '$tagToApply'..."
    try {
        $hash = Get-HardwareHash
        Write-Ok 'Hardware hash collected. Uploading and waiting for the Autopilot service'
        Import-AutopilotDevice -Token $graphToken -Serial $Serial -Hash $hash -GroupTag $tagToApply
        Write-Ok 'The Autopilot service accepted the device.'
        $uploadOk = $true
    } catch {
        Write-Fail "Upload failed: $(Get-GraphErrorText $_)"
    }

    if ($uploadOk) {
        Write-Step 'Waiting for the device to appear in Intune'
        $registered = Wait-AutopilotDevice -Token $graphToken -Serial $Serial -Minutes 10
        if ($registered) {
            Write-Ok 'The device is listed in Intune.'
            if ($WaitForProfileAssignment) {
                Write-Step 'Waiting for the Autopilot profile to be assigned (can take 10-15 minutes)'
                if (Wait-ProfileAssignment -Token $graphToken -Id $registered.id -Minutes 30) {
                    Write-Ok 'Autopilot profile assigned.'
                } else {
                    Write-Warn 'No profile assigned yet. Until it is, the device will not show'
                    Write-Warn 'the Autopilot experience.'
                }
            }
        } else {
            Write-Warn 'The device is registered but not listed in Intune yet. It usually'
            Write-Warn 'appears within a few minutes.'
        }
    }
}


# --- Result ---------------------------------------------------------
Write-Host ''
if ($uploadOk) {
    Write-Host '  ===============================================================' -ForegroundColor Green
    Write-Host '                    E N R O L L M E N T   C O M P L E T E'         -ForegroundColor Green
    Write-Host '  ===============================================================' -ForegroundColor Green
    Write-Host ''
    Write-Host '   Group tag applied : ' -NoNewline
    Write-Host $tagToApply -ForegroundColor Green
    Write-Host ''

    switch ($PostEnrollAction) {
        'Wipe'   { $action = 'Wipe' }
        'Reboot' { $action = 'Reboot' }
        'None'   { $action = 'None' }
        'Ask'    {
            Write-Host '   A brand-new device that has never been set up does NOT need'
            Write-Host '   resetting - it just needs a restart.'
            $action = if (Read-YesNo 'Does this device need resetting back to a clean OOBE?') {
                          'Wipe'
                      } else {
                          'Reboot'
                      }
        }
        default  { $action = if (Test-InOobe) { 'Reboot' } else { 'Wipe' } }
    }

    if ($action -eq 'None') {
        Write-Host '   No restart requested. Restart the device manually before handing it over.'
        Exit-Script -Code 0
    }

    if ($action -eq 'Reboot') {
        Write-Host '   Device has not been set up yet, so there is nothing to reset.'
        if (Wait-WithCancel -Seconds $CountdownSeconds -ActionText 'Restarting') {
            Write-Ok 'Restarting now. Leave the device alone - it will land in Autopilot OOBE.'
            try { Stop-Transcript | Out-Null } catch { }
            Restart-Computer -Force
            exit 0
        }
        Exit-Script -Code 0 -Message 'Restart cancelled. Restart manually before handing the device over.'
    }

    # Reset path
    Write-Host '  ***************************************************************' -ForegroundColor Red
    Write-Host '   WARNING: this device will now be RESET back to a clean OOBE.'    -ForegroundColor Red
    Write-Host '   EVERYTHING on the internal drive will be permanently erased.'    -ForegroundColor Red
    Write-Host '   Cancel now if this machine holds data anyone still needs.'       -ForegroundColor Red
    Write-Host '  ***************************************************************' -ForegroundColor Red
    Write-Host ''

    if (-not (Wait-WithCancel -Seconds $CountdownSeconds -ActionText 'RESETTING')) {
        Exit-Script -Code 0 -Message ('Reset cancelled. The device IS registered with Autopilot - ' +
                                      'reset it manually before handing it over.')
    }

    Write-Step 'Resetting the device...'
    if (Invoke-DeviceWipe) {
        Write-Host ''
        Write-Host '   Do not power the device off. It will restart, reset, and come'
        Write-Host '   back at a fresh OOBE ready for the end user to sign in.'
        try { Stop-Transcript | Out-Null } catch { }
        Start-Sleep -Seconds 5
        exit 0
    } else {
        Write-Fail 'Automatic reset could not be started.'
        Write-Host  '   The device IS registered with Autopilot, so nothing is lost.'
        Write-Host  '   Please reset it manually: Settings > System > Recovery >'
        Write-Host  '   Reset this PC > Remove everything.'
        Exit-Script -Code 2
    }
} else {
    Write-Host '  ===============================================================' -ForegroundColor Red
    Write-Host '                  E N R O L L M E N T   F A I L E D'               -ForegroundColor Red
    Write-Host '  ===============================================================' -ForegroundColor Red
    Write-Host ''
    Write-Host '   This device was NOT registered with Autopilot, and it has NOT'
    Write-Host '   been reset - it is exactly as you found it.'
    Write-Host ''
    Write-Host "   Log: $LogPath" -ForegroundColor Yellow
    Exit-Script -Code 1
}
