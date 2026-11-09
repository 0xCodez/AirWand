<#
  Orbit mobile bootstrap for Windows developers (PowerShell 5.1+ or pwsh 7).

  Generates android/ and ios/ with `flutter create` when missing, then applies
  the same idempotent patches as tool/bootstrap.sh:
    - AndroidManifest.xml: permissions + app label "Orbit"
    - android/app/build.gradle(.kts): minSdk >= 23
    - ios/Runner/Info.plist: local network, Bonjour, motion, display name,
      status bar style, portrait only
    - iOS deployment target >= 13.0 (bonsoir uses NWBrowser)

  Usage:  powershell -ExecutionPolicy Bypass -File tool\bootstrap.ps1
#>
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0

$Root = Split-Path -Parent $PSScriptRoot
Set-Location $Root

function Say([string]$msg) { Write-Host "[orbit] $msg" -ForegroundColor Cyan }

if (-not (Get-Command flutter -ErrorAction SilentlyContinue)) {
  throw 'flutter is not on PATH (https://docs.flutter.dev/get-started/install)'
}

if (-not (Test-Path 'android') -or -not (Test-Path 'ios')) {
  Say 'Generating platform folders with flutter create...'
  & flutter create . --project-name orbit --org app.orbit --platforms android,ios
  if ($LASTEXITCODE -ne 0) { throw "flutter create failed ($LASTEXITCODE)" }
  $wt = Join-Path $Root 'test\widget_test.dart'
  if ((Test-Path $wt) -and (Select-String -Path $wt -Pattern 'MyApp' -Quiet)) {
    Remove-Item $wt -Force
    Say 'Removed template test/widget_test.dart'
  }
} else {
  Say 'android/ and ios/ already exist, only patching.'
}

$Utf8NoBom = New-Object System.Text.UTF8Encoding($false)
$Changed = New-Object System.Collections.Generic.List[string]

function Read-Text([string]$path) { [System.IO.File]::ReadAllText($path) }
function Write-Text([string]$path, [string]$text) {
  [System.IO.File]::WriteAllText($path, $text, $Utf8NoBom)
}

# ------------------------------------------------------------------ Android
$manifest = Join-Path $Root 'android\app\src\main\AndroidManifest.xml'
if (Test-Path $manifest) {
  $xml = Read-Text $manifest
  $orig = $xml
  $perms = @(
    'android.permission.INTERNET',
    'android.permission.ACCESS_NETWORK_STATE',
    'android.permission.ACCESS_WIFI_STATE',
    'android.permission.CHANGE_WIFI_MULTICAST_STATE',
    'android.permission.VIBRATE'
  )
  $lines = ''
  foreach ($p in $perms) {
    if (-not $xml.Contains("android:name=`"$p`"")) {
      $lines += "    <uses-permission android:name=`"$p`"/>`n"
    }
  }
  if ($lines.Length -gt 0) {
    $rx = [regex]'(<manifest\b[^>]*>\s*\r?\n)'
    if (-not $rx.IsMatch($xml)) { throw 'AndroidManifest.xml: <manifest> tag not found' }
    $xml = $rx.Replace($xml, { param($m) $m.Groups[1].Value + $lines }, 1)
  }
  $appRx = [regex]'<application\b[^>]*>'
  $xml = $appRx.Replace($xml, {
      param($m)
      $tag = $m.Value
      if ($tag -match 'android:label="[^"]*"') {
        return ([regex]'android:label="[^"]*"').Replace($tag, 'android:label="Orbit"', 1)
      }
      return $tag.Replace('<application', "<application`n        android:label=`"Orbit`"")
    }, 1)
  if ($xml -ne $orig) { Write-Text $manifest $xml; $Changed.Add($manifest) }
}

foreach ($name in @('build.gradle.kts', 'build.gradle')) {
  $gradle = Join-Path $Root "android\app\$name"
  if (-not (Test-Path $gradle)) { continue }
  $text = Read-Text $gradle
  $orig = $text
  $maxFn = if ($name.EndsWith('.kts')) { 'maxOf(23, flutter.minSdkVersion)' } else { 'Math.max(23, flutter.minSdkVersion)' }
  $text = ([regex]'(\bminSdk\s*=\s*)flutter\.minSdkVersion\b').Replace($text, { param($m) $m.Groups[1].Value + $maxFn })
  $text = ([regex]'(\bminSdkVersion\s+)flutter\.minSdkVersion\b').Replace($text, { param($m) $m.Groups[1].Value + 'Math.max(23, flutter.minSdkVersion)' })
  $text = ([regex]'(\bminSdk(?:Version)?\s*=?\s*)(\d+)\b').Replace($text, {
      param($m)
      $v = [int]$m.Groups[2].Value
      if ($v -lt 23) { $v = 23 }
      return $m.Groups[1].Value + $v
    })
  if ($text -ne $orig) { Write-Text $gradle $text; $Changed.Add($gradle) }
}

# ---------------------------------------------------------------- iOS plist
function Open-Plist([string]$path) {
  $doc = New-Object System.Xml.XmlDocument
  $doc.PreserveWhitespace = $false
  $doc.XmlResolver = $null # never fetch Apple's DTD
  $settings = New-Object System.Xml.XmlReaderSettings
  $settings.DtdProcessing = [System.Xml.DtdProcessing]::Ignore
  $settings.XmlResolver = $null
  $reader = [System.Xml.XmlReader]::Create($path, $settings)
  try { $doc.Load($reader) } finally { $reader.Close() }
  return $doc
}

function Save-Plist([System.Xml.XmlDocument]$doc, [string]$path) {
  $ws = New-Object System.Xml.XmlWriterSettings
  $ws.Indent = $true
  $ws.IndentChars = "`t"
  $ws.Encoding = $Utf8NoBom
  $sw = New-Object System.IO.StringWriter
  $w = [System.Xml.XmlWriter]::Create($sw, $ws)
  $doc.Save($w)
  $w.Close()
  # StringWriter reports utf-16; plist tooling expects UTF-8.
  $out = $sw.ToString().Replace('encoding="utf-16"', 'encoding="UTF-8"')
  if ($out -notmatch '<!DOCTYPE plist') {
    $out = $out.Replace('?>', "?>`n<!DOCTYPE plist PUBLIC `"-//Apple//DTD PLIST 1.0//EN`" `"http://www.apple.com/DTDs/PropertyList-1.0.dtd`">")
  }
  Write-Text $path ($out + "`n")
}

function Get-PlistValueNode([System.Xml.XmlElement]$dict, [string]$key) {
  $children = @($dict.ChildNodes | Where-Object { $_.NodeType -eq 'Element' })
  for ($i = 0; $i -lt $children.Count - 1; $i++) {
    if ($children[$i].Name -eq 'key' -and $children[$i].InnerText -eq $key) {
      return $children[$i + 1]
    }
  }
  return $null
}

function Set-PlistNode([System.Xml.XmlDocument]$doc, [System.Xml.XmlElement]$dict, [string]$key, [System.Xml.XmlElement]$value) {
  $existing = Get-PlistValueNode $dict $key
  if ($null -ne $existing) {
    if ($existing.OuterXml -eq $value.OuterXml) { return $false }
    [void]$dict.ReplaceChild($value, $existing)
    return $true
  }
  $k = $doc.CreateElement('key')
  $k.InnerText = $key
  [void]$dict.AppendChild($k)
  [void]$dict.AppendChild($value)
  return $true
}

function New-PlistString([System.Xml.XmlDocument]$doc, [string]$s) {
  $e = $doc.CreateElement('string'); $e.InnerText = $s; return $e
}

function New-PlistArray([System.Xml.XmlDocument]$doc, [string[]]$items) {
  $a = $doc.CreateElement('array')
  foreach ($it in $items) { [void]$a.AppendChild((New-PlistString $doc $it)) }
  return $a
}

$plistPath = Join-Path $Root 'ios\Runner\Info.plist'
if (Test-Path $plistPath) {
  $doc = Open-Plist $plistPath
  $dict = $doc.SelectSingleNode('/plist/dict')
  $dirty = $false

  $dirty = (Set-PlistNode $doc $dict 'CFBundleDisplayName' (New-PlistString $doc 'Orbit')) -or $dirty
  $dirty = (Set-PlistNode $doc $dict 'NSLocalNetworkUsageDescription' (New-PlistString $doc 'Orbit finds your computers on this Wi-Fi network and sends your trackpad, keyboard and media controls to them.')) -or $dirty

  $services = @()
  $svcNode = Get-PlistValueNode $dict 'NSBonjourServices'
  if ($null -ne $svcNode) {
    $services = @($svcNode.ChildNodes | Where-Object { $_.NodeType -eq 'Element' } | ForEach-Object { $_.InnerText })
  }
  if ($services -notcontains '_orbit._tcp') { $services += '_orbit._tcp' }
  $dirty = (Set-PlistNode $doc $dict 'NSBonjourServices' (New-PlistArray $doc $services)) -or $dirty

  $dirty = (Set-PlistNode $doc $dict 'NSMotionUsageDescription' (New-PlistString $doc 'Air mode uses motion sensors to turn your phone into a pointer.')) -or $dirty
  $dirty = (Set-PlistNode $doc $dict 'UIStatusBarStyle' (New-PlistString $doc 'UIStatusBarStyleLightContent')) -or $dirty
  $dirty = (Set-PlistNode $doc $dict 'UISupportedInterfaceOrientations' (New-PlistArray $doc @('UIInterfaceOrientationPortrait'))) -or $dirty
  $dirty = (Set-PlistNode $doc $dict 'UISupportedInterfaceOrientations~ipad' (New-PlistArray $doc @('UIInterfaceOrientationPortrait', 'UIInterfaceOrientationPortraitUpsideDown'))) -or $dirty
  $dirty = (Set-PlistNode $doc $dict 'UIRequiresFullScreen' ($doc.CreateElement('true'))) -or $dirty

  if ($dirty) { Save-Plist $doc $plistPath; $Changed.Add($plistPath) }
}

# ----------------------------------------------------- iOS deployment target
function Test-VersionLow([string]$v) {
  $parts = [regex]::Matches($v, '\d+') | ForEach-Object { [int]$_.Value }
  $parts = @($parts) + @(0, 0)
  return ($parts[0] -lt 13)
}

$pbx = Join-Path $Root 'ios\Runner.xcodeproj\project.pbxproj'
if (Test-Path $pbx) {
  $text = Read-Text $pbx
  $new = ([regex]'(IPHONEOS_DEPLOYMENT_TARGET = )([\d.]+);').Replace($text, {
      param($m)
      $v = $m.Groups[2].Value
      if (Test-VersionLow $v) { $v = '13.0' }
      return $m.Groups[1].Value + $v + ';'
    })
  if ($new -ne $text) { Write-Text $pbx $new; $Changed.Add($pbx) }
}

$appInfo = Join-Path $Root 'ios\Flutter\AppFrameworkInfo.plist'
if (Test-Path $appInfo) {
  $doc = Open-Plist $appInfo
  $dict = $doc.SelectSingleNode('/plist/dict')
  $node = Get-PlistValueNode $dict 'MinimumOSVersion'
  if ($null -ne $node -and (Test-VersionLow $node.InnerText)) {
    $node.InnerText = '13.0'
    Save-Plist $doc $appInfo
    $Changed.Add($appInfo)
  }
}

$podfile = Join-Path $Root 'ios\Podfile'
if (Test-Path $podfile) {
  $text = Read-Text $podfile
  $rx = New-Object System.Text.RegularExpressions.Regex("^#?\s*platform :ios, '([\d.]+)'", [System.Text.RegularExpressions.RegexOptions]::Multiline)
  $new = $rx.Replace($text, {
      param($m)
      $v = $m.Groups[1].Value
      if (Test-VersionLow $v) { $v = '13.0' }
      return "platform :ios, '$v'"
    }, 1)
  if ($new -ne $text) { Write-Text $podfile $new; $Changed.Add($podfile) }
}

if ($Changed.Count -gt 0) {
  Say 'patched:'
  foreach ($c in $Changed) { Write-Host "  - $($c.Substring($Root.Length + 1))" }
} else {
  Say 'platform files already up to date'
}

Say 'Fetching packages...'
& flutter pub get
if ($LASTEXITCODE -ne 0) { throw "flutter pub get failed ($LASTEXITCODE)" }
Say 'Done. Next: flutter run   (iOS builds need a Mac; see README.md)'
