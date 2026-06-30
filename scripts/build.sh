#!/usr/bin/env bash
# LegadoHOS 构建脚本
# 用法: ./scripts/build.sh [debug|release]

set -euo pipefail

cd "$(dirname "$0")/.."

find_deveco_home() {
  if [[ -n "${DEVECO_HOME:-}" ]]; then
    return 0
  fi

  local candidates=(
    "/Applications/DevEco-Studio.app/Contents"
    "$HOME/Applications/DevEco-Studio.app/Contents"
    "/opt/deveco-studio"
    "$HOME/deveco-studio"
  )

  local candidate
  for candidate in "${candidates[@]}"; do
    if [[ -d "$candidate/tools/hvigor/bin" ]]; then
      export DEVECO_HOME="$candidate"
      return 0
    fi
  done

  echo "ERROR: DEVECO_HOME is not set and DevEco Studio was not auto-detected." >&2
  echo "Set DEVECO_HOME to the DevEco Studio install root, for example:" >&2
  echo "  export DEVECO_HOME=/Applications/DevEco-Studio.app/Contents" >&2
  exit 1
}

check_signing_material() {
  local build_profile="build-profile.json5"
  [[ -f "$build_profile" ]] || return 0

  local missing=()
  local material_path
  while IFS= read -r material_path; do
    [[ -z "$material_path" ]] && continue
    material_path="${material_path/#\~/$HOME}"
    if [[ ! -f "$material_path" ]]; then
      missing+=("$material_path")
    fi
  done < <(sed -nE 's/.*"(certpath|profile|storeFile)"[[:space:]]*:[[:space:]]*"([^"]+)".*/\2/p' "$build_profile")

  if [[ "${#missing[@]}" -gt 0 ]]; then
    echo "ERROR: signing material in $build_profile was not found on this machine:" >&2
    printf '  %s\n' "${missing[@]}" >&2
    echo "Open the project in DevEco Studio and run Auto Sign for this machine, then rebuild." >&2
    exit 1
  fi
}

find_deveco_home

export DEVECO_SDK_HOME="${DEVECO_SDK_HOME:-$DEVECO_HOME/sdk}"
export NODE_HOME="${NODE_HOME:-$DEVECO_HOME/tools/node}"
export PATH="$NODE_HOME/bin:$DEVECO_HOME/tools/ohpm/bin:$DEVECO_SDK_HOME/default/openharmony/toolchains:$PATH"

BUILD_MODE="${1:-debug}"
HVIGORW="${HVIGORW:-$DEVECO_HOME/tools/hvigor/bin/hvigorw}"

if [[ "$BUILD_MODE" != "debug" && "$BUILD_MODE" != "release" ]]; then
  echo "ERROR: build mode must be 'debug' or 'release'." >&2
  exit 1
fi

echo "🔨 构建模式: $BUILD_MODE"
check_signing_material

# 优先用 deveco-cli，fallback 到 hvigorw
if command -v devecocli &>/dev/null; then
  devecocli build --build-mode "$BUILD_MODE"
else
  if [[ ! -x "$HVIGORW" ]]; then
    echo "ERROR: hvigorw not found at $HVIGORW" >&2
    exit 1
  fi

  "$HVIGORW" assembleHap \
    --mode module \
    -p product=default \
    -p buildMode="$BUILD_MODE"
fi

if command -v codegraph &>/dev/null; then
  echo "🔄 同步 CodeGraph 符号索引..."
  codegraph sync .
fi
echo "✅ 完成"
