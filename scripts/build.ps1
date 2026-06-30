param(
  [ValidateSet("debug", "release")]
  [string]$BuildMode = "debug"
)

$ErrorActionPreference = "Stop"

$ProjectRoot = Resolve-Path (Join-Path $PSScriptRoot "..")
Set-Location $ProjectRoot

function Find-DevEcoHome {
  if ($env:DEVECO_HOME) {
    return $env:DEVECO_HOME
  }

  function Join-OptionalPath([string]$BasePath, [string]$ChildPath) {
    if ([string]::IsNullOrWhiteSpace($BasePath)) {
      return $null
    }
    return Join-Path $BasePath $ChildPath
  }

  $candidates = @(
    (Join-OptionalPath $env:ProgramFiles "Huawei\DevEco Studio"),
    (Join-OptionalPath $env:ProgramFiles "DevEco Studio"),
    (Join-OptionalPath ${env:ProgramFiles(x86)} "Huawei\DevEco Studio"),
    (Join-OptionalPath $env:LOCALAPPDATA "Huawei\DevEco Studio"),
    (Join-OptionalPath $env:USERPROFILE "DevEco Studio")
  )

  foreach ($candidate in $candidates) {
    if (-not $candidate) {
      continue
    }

    $hvigor = Join-Path $candidate "tools\hvigor\bin\hvigorw.bat"
    if (Test-Path $hvigor) {
      return $candidate
    }
  }

  throw @"
DEVECO_HOME is not set and DevEco Studio was not auto-detected.
Set DEVECO_HOME to the DevEco Studio install root, for example:
  `$env:DEVECO_HOME = "C:\Program Files\Huawei\DevEco Studio"
"@
}

function Test-SigningMaterial {
  $buildProfile = Join-Path $ProjectRoot "build-profile.json5"
  if (-not (Test-Path $buildProfile)) {
    return
  }

  $content = Get-Content -Raw $buildProfile
  $matches = [regex]::Matches($content, '"(certpath|profile|storeFile)"\s*:\s*"([^"]+)"')
  $missing = @()

  foreach ($match in $matches) {
    $materialPath = [regex]::Unescape($match.Groups[2].Value)
    if (-not (Test-Path $materialPath)) {
      $missing += $materialPath
    }
  }

  if ($missing.Count -gt 0) {
    $paths = ($missing | ForEach-Object { "  $_" }) -join [Environment]::NewLine
    throw @"
Signing material in build-profile.json5 was not found on this machine:
$paths
Open the project in DevEco Studio and run Auto Sign for this machine, then rebuild.
"@
  }
}

$DevEcoHome = Find-DevEcoHome
$env:DEVECO_HOME = $DevEcoHome

if (-not $env:DEVECO_SDK_HOME) {
  $env:DEVECO_SDK_HOME = Join-Path $DevEcoHome "sdk"
}
if (-not $env:NODE_HOME) {
  $env:NODE_HOME = Join-Path $DevEcoHome "tools\node"
}

$nodePath = $env:NODE_HOME
$ohpmPath = Join-Path $DevEcoHome "tools\ohpm\bin"
$hdcPath = Join-Path $env:DEVECO_SDK_HOME "default\openharmony\toolchains"
$env:Path = "$nodePath;$ohpmPath;$hdcPath;$env:Path"

$hvigorw = if ($env:HVIGORW) {
  $env:HVIGORW
} else {
  Join-Path $DevEcoHome "tools\hvigor\bin\hvigorw.bat"
}

Write-Host "🔨 构建模式: $BuildMode"
Test-SigningMaterial

$devecoCli = Get-Command devecocli -ErrorAction SilentlyContinue
if ($devecoCli) {
  & $devecoCli.Source build --build-mode $BuildMode
} else {
  if (-not (Test-Path $hvigorw)) {
    throw "hvigorw not found at $hvigorw"
  }

  & $hvigorw assembleHap `
    --mode module `
    -p product=default `
    -p buildMode=$BuildMode
}

$codegraph = Get-Command codegraph -ErrorAction SilentlyContinue
if ($codegraph) {
  Write-Host "🔄 同步 CodeGraph 符号索引..."
  & $codegraph.Source sync .
}

Write-Host "✅ 完成"
