# Launcher for the Autopilot enrollment script.
#
# In OOBE press SHIFT + F10 and type:
#     powershell -c "irm https://raw.githubusercontent.com/LeaseQuery/autopilot-enroll/main/go.ps1 | iex"
#
# This downloads the current enrollment script from GitHub, checks that it
# is exactly the reviewed version pinned below, and runs it from memory,
# so nothing can swap the file between the check and the run. Neither
# file holds any secrets.
#
# CHANGING Enroll-Autopilot-Internal.ps1? Update $ExpectedSha256 in the
# same pull request - see "Changing the script" in README.md.

$ErrorActionPreference = 'Stop'
$ProgressPreference    = 'SilentlyContinue'   # the progress bar slows downloads in Windows PowerShell
[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12

$source         = 'https://raw.githubusercontent.com/LeaseQuery/autopilot-enroll/main/Enroll-Autopilot-Internal.ps1'
$ExpectedSha256 = '34209eb77fe3c294a6fe02ce4e941277d09527d8ba4410ff825a707fb53488c2'

Write-Host 'Downloading the enrollment script...' -ForegroundColor Cyan
$bytes  = (Invoke-WebRequest -Uri $source -UseBasicParsing).RawContentStream.ToArray()
$sha256 = [Security.Cryptography.SHA256]::Create()
$actual = -join ($sha256.ComputeHash($bytes) | ForEach-Object { $_.ToString('x2') })

if ($actual -ne $ExpectedSha256) {
    Write-Host ''
    Write-Host '[X] The downloaded script is not the approved version. It has NOT been run.' -ForegroundColor Red
    Write-Host '    If the script was updated in the last few minutes, wait 5 minutes and'
    Write-Host '    try again - GitHub can serve the old and new files for a short time.'
    Write-Host '    Otherwise, stop and contact IT.'
    Write-Host "    Expected SHA256: $ExpectedSha256" -ForegroundColor DarkGray
    Write-Host "    Got SHA256     : $actual" -ForegroundColor DarkGray
    return
}

Write-Host '[OK] Script verified.' -ForegroundColor Green
$script = [Text.Encoding]::UTF8.GetString($bytes).TrimStart([char]0xFEFF)   # a UTF-8 BOM would break the first line
& ([scriptblock]::Create($script))
