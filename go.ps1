# Launcher for the Autopilot enrollment script.
#
# In OOBE press SHIFT + F10 and type:
#     powershell -c "irm https://raw.githubusercontent.com/LeaseQuery/autopilot-enroll/main/go.ps1 | iex"
#
# This downloads the current enrollment script from GitHub to a local
# file and runs it from there, so it behaves the same as running it from
# a flash drive. Neither file holds any secrets.

$ErrorActionPreference = 'Stop'
$ProgressPreference    = 'SilentlyContinue'   # the progress bar slows downloads in Windows PowerShell
[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12

$source = 'https://raw.githubusercontent.com/LeaseQuery/autopilot-enroll/main/Enroll-Autopilot-Internal.ps1'
$target = Join-Path $env:TEMP 'Enroll-Autopilot-Internal.ps1'

Write-Host 'Downloading the enrollment script...' -ForegroundColor Cyan
Invoke-WebRequest -Uri $source -OutFile $target -UseBasicParsing
Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass -Force
& $target
