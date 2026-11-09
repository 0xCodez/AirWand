<#
.SYNOPSIS
  Adds Windows Defender Firewall inbound rules for the Orbit host agent.

.DESCRIPTION
  Orbit listens on TCP 47821 (pairing) and UDP 47821 (control + broadcast discovery) and
  answers mDNS queries on UDP 5353. Run this once from an elevated PowerShell:

    powershell -ExecutionPolicy Bypass -File .\scripts\firewall-windows.ps1

  Alternatively, accept the "Windows Defender Firewall has blocked some features" prompt
  that Windows shows the first time orbit.exe opens its ports (tick "Private networks").

  The rules are idempotent: existing Orbit rules are replaced. Use -Remove to delete them.

.PARAMETER Profiles
  Firewall profiles to open. Default: Private (home / work Wi-Fi). Add Domain if needed.
  Public is deliberately not the default.

.PARAMETER Program
  Optional full path to orbit.exe to restrict the rules to that executable.

.PARAMETER Remove
  Remove the Orbit rules instead of adding them.
#>
[CmdletBinding()]
param(
  [string[]]$Profiles = @('Private'),
  [string]$Program = '',
  [switch]$Remove
)

$ErrorActionPreference = 'Stop'

$principal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
  Write-Error 'Run this script from an elevated PowerShell (Run as administrator).'
  exit 1
}

$group = 'Orbit'
$rules = @(
  @{ Name = 'Orbit-Pairing-TCP-In'; DisplayName = 'Orbit pairing (TCP 47821)';          Protocol = 'TCP'; Port = 47821 },
  @{ Name = 'Orbit-Control-UDP-In'; DisplayName = 'Orbit control + discovery (UDP 47821)'; Protocol = 'UDP'; Port = 47821 },
  @{ Name = 'Orbit-mDNS-UDP-In';    DisplayName = 'Orbit Bonjour / mDNS (UDP 5353)';     Protocol = 'UDP'; Port = 5353 }
)

foreach ($r in $rules) {
  Get-NetFirewallRule -Name $r.Name -ErrorAction SilentlyContinue | Remove-NetFirewallRule
}

if ($Remove) {
  Write-Host 'Orbit firewall rules removed.'
  exit 0
}

foreach ($r in $rules) {
  $params = @{
    Name        = $r.Name
    DisplayName = $r.DisplayName
    Group       = $group
    Direction   = 'Inbound'
    Action      = 'Allow'
    Protocol    = $r.Protocol
    LocalPort   = $r.Port
    Profile     = ($Profiles -join ',')
    Description = 'Lets paired phones discover and control this computer with Orbit.'
  }
  if ($Program -ne '') {
    $params.Program = $Program
  }
  New-NetFirewallRule @params | Out-Null
  Write-Host ("Added: {0} [{1}]" -f $r.DisplayName, ($Profiles -join ', '))
}

Write-Host ''
Write-Host 'Done. Make sure your Wi-Fi network is set to "Private" in Settings > Network & internet.'
