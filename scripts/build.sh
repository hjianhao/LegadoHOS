#!/bin/bash
# LegadoHOS 构建脚本
# 用法: ./scripts/build.sh [debug|release]

set -e

cd "$(dirname "$0")/.."

export PATH="/Applications/DevEco-Studio.app/Contents/tools/node/bin:$PATH"
export DEVECO_SDK_HOME="/Applications/DevEco-Studio.app/Contents/sdk"
export NODE_HOME="/Applications/DevEco-Studio.app/Contents/tools/node"

BUILD_MODE="${1:-debug}"

echo "🔨 构建模式: $BUILD_MODE"

# 优先用 deveco-cli，fallback 到 hvigorw
if command -v devecocli &>/dev/null; then
  devecocli build --build-mode "$BUILD_MODE"
else
  /Applications/DevEco-Studio.app/Contents/tools/hvigor/bin/hvigorw assembleHap \
    --mode module \
    -p product=default \
    -p buildMode="$BUILD_MODE"
fi

echo "🔄 同步 CodeGraph 符号索引..."
codegraph sync .
echo "✅ 完成"
