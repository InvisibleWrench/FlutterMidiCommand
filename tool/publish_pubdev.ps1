param(
  [Parameter(Mandatory = $true, Position = 0)]
  [ValidateSet(
    'flutter_midi_command_platform_interface',
    'flutter_midi_command_android',
    'flutter_midi_command_darwin',
    'flutter_midi_command_linux',
    'flutter_midi_command_web',
    'flutter_midi_command_windows',
    'flutter_midi_command_ble',
    'flutter_midi_command'
  )]
  [string]$Package,

  [switch]$Publish
)

$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Parent $PSScriptRoot
$packageDirs = @{
  flutter_midi_command_platform_interface = 'packages/flutter_midi_command_platform_interface'
  flutter_midi_command_android = 'packages/flutter_midi_command_android'
  flutter_midi_command_darwin = 'packages/flutter_midi_command_darwin'
  flutter_midi_command_linux = 'packages/flutter_midi_command_linux'
  flutter_midi_command_web = 'packages/flutter_midi_command_web'
  flutter_midi_command_windows = 'packages/flutter_midi_command_windows'
  flutter_midi_command_ble = 'packages/flutter_midi_command_ble'
  flutter_midi_command = '.'
}

$packageDir = Join-Path $repoRoot $packageDirs[$Package]
$overridePath = Join-Path $packageDir 'pubspec_overrides.yaml'
$hiddenOverridePath = "$overridePath.codexrelease"
$dartArgs = @('pub', 'publish')

if (-not $Publish) {
  $dartArgs += '--dry-run'
}

$renamedOverride = $false
$pushedLocation = $false

try {
  if (Test-Path -LiteralPath $overridePath) {
    if (Test-Path -LiteralPath $hiddenOverridePath) {
      throw "Temporary override path already exists: $hiddenOverridePath"
    }

    Rename-Item -LiteralPath $overridePath -NewName (Split-Path -Leaf $hiddenOverridePath)
    $renamedOverride = $true
  }

  Push-Location $packageDir
  $pushedLocation = $true
  Write-Host "Running: dart $($dartArgs -join ' ')" -ForegroundColor Cyan
  Write-Host "Package: $Package" -ForegroundColor Cyan
  & dart @dartArgs
  $exitCode = $LASTEXITCODE
  if ($exitCode -ne 0) {
    exit $exitCode
  }
} finally {
  if ($pushedLocation) {
    Pop-Location
  }

  if ($renamedOverride -and (Test-Path -LiteralPath $hiddenOverridePath)) {
    Rename-Item -LiteralPath $hiddenOverridePath -NewName (Split-Path -Leaf $overridePath)
  }
}
