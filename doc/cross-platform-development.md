# Cross-platform Development

This project can be developed on macOS and Windows as long as DevEco Studio,
the HarmonyOS SDK, signing material, and local paths are kept machine-local.

## Required Tools

- DevEco Studio with the project SDK installed.
- DevEco bundled Node.js, Hvigor, Ohpm, and HDC.
- Project dependencies installed with `ohpm install` when OHPM files change.
- Optional: `codegraph` CLI for symbol index sync after successful builds.

## macOS Setup

```bash
export DEVECO_HOME="/Applications/DevEco-Studio.app/Contents"
export DEVECO_SDK_HOME="$DEVECO_HOME/sdk"
export NODE_HOME="$DEVECO_HOME/tools/node"
export PATH="$NODE_HOME/bin:$DEVECO_HOME/tools/ohpm/bin:$DEVECO_SDK_HOME/default/openharmony/toolchains:$PATH"
```

Build:

```bash
./scripts/build.sh debug
./scripts/build.sh release
```

## Windows Setup

PowerShell example:

```powershell
$env:DEVECO_HOME = "C:\Program Files\Huawei\DevEco Studio"
$env:DEVECO_SDK_HOME = "$env:DEVECO_HOME\sdk"
$env:NODE_HOME = "$env:DEVECO_HOME\tools\node"
$env:Path = "$env:NODE_HOME;$env:DEVECO_HOME\tools\ohpm\bin;$env:DEVECO_SDK_HOME\default\openharmony\toolchains;$env:Path"
```

Build:

```powershell
.\scripts\build.ps1 debug
.\scripts\build.ps1 release
```

If PowerShell script execution is blocked on the machine, run:

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\build.ps1 debug
```

## Local Properties

`local.properties` is ignored by git. Copy `local.properties.example` to
`local.properties` and adjust it for each machine.

macOS example:

```properties
arkui-x.dir=/Users/<user>/Library/ArkUI-X/Sdk
```

Windows example:

```properties
arkui-x.dir=C:\\Users\\<user>\\AppData\\Local\\Huawei\\ArkUI-X\\Sdk
```

## Signing

HarmonyOS signing material is machine-local. Do not commit personal `.p12`,
`.cer`, `.p7b`, keystore passwords, or profile files.

Recommended flow for a new machine:

1. Open the project in DevEco Studio.
2. Configure debug signing with Auto Sign.
3. Confirm the project builds once from DevEco Studio.
4. Use the command-line build scripts after that.

The current repository still keeps the project-level `build-profile.json5`
because Hvigor reads it directly. If a machine needs different signing
material, let DevEco update that file locally and avoid committing personal
signing changes.

## Git Settings

Use case-sensitive path tracking so ArkTS imports do not drift on
case-insensitive file systems:

```bash
git config core.ignorecase false
```
