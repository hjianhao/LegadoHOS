#!/bin/bash
# ===========================================================================
# TTS 模型推送工具
# 用法:
#   ./scripts/push-tts-model.sh vits            # 下载+推送 VITS
#   ./scripts/push-tts-model.sh kokoro          # 下载+推送 Kokoro
#   ./scripts/push-tts-model.sh vits -t EMU01   # 推送到指定设备
#   ./scripts/push-tts-model.sh vits download   # 只下载到本地
# ===========================================================================

set -euo pipefail

MODEL_TYPE="${1:-vits}"
OPT="${2:-}"

# ---------- 模型配置 ----------
if [ "$MODEL_TYPE" = "kokoro" ]; then
  DIR_NAME="kokoro-int8-multi-lang-v1_1"
  URL="https://huggingface.co/csukuangfj/kokoro-int8-multi-lang-v1_1/resolve/main/kokoro-int8-multi-lang-v1_1.tar.bz2"
  SIZE_LABEL="215 MB"
elif [ "$MODEL_TYPE" = "vits" ]; then
  DIR_NAME="sherpa-onnx-vits-zh-ll"
  URL="https://github.com/k2-fsa/sherpa-onnx/releases/download/tts-models/sherpa-onnx-vits-zh-ll.tar.bz2"
  SIZE_LABEL="118 MB"
else
  echo "Usage: $0 {vits|kokoro} [download]"
  echo "  download: 只下载不解压，后续手动推送"
  exit 1
fi

echo "=== 模型: $DIR_NAME ($SIZE_LABEL) ==="

# ---------- 查找 hdc ----------
find_hdc() {
  for p in \
    "/Applications/DevEco-Studio.app/Contents/sdk/default/openharmony/toolchains/hdc" \
    "$DEVECO_SDK_HOME/default/openharmony/toolchains/hdc" \
    "$(which hdc 2>/dev/null)"; do
    if [ -x "$p" ]; then echo "$p"; return; fi
  done
  echo ""
}

HDC=$(find_hdc)
BUNDLE="io.legado.hos"

    if [ -n "$HDC" ] && [ "$OPT" != "download" ]; then
      # ---------- 查找设备 ----------
      DEVICES=$($HDC list targets 2>/dev/null | grep -v '^$' || true)
      DEVICE_COUNT=$(echo "$DEVICES" | grep -c . || true)

      if [ "$DEVICE_COUNT" -gt 0 ]; then
        if [ "$DEVICE_COUNT" -gt 1 ]; then
          echo "检测到多台设备:"
          echo "$DEVICES" | awk '{print NR") "$0}'
          echo -n "选择设备编号 [1-$DEVICE_COUNT]: "
          read -r N
          TARGET=$(echo "$DEVICES" | sed -n "${N}p" | awk '{print $1}')
          HDC_CMD="$HDC -t $TARGET"
          echo "目标: $TARGET"
        else
          HDC_CMD="$HDC"
        fi

        # ---------- 查找 App 沙箱路径 ----------
        APP_DIR=""
        for try in \
          "/data/storage/el2/base/haps/entry/files" \
          "/data/storage/el2/base/files"; do
          APP_DIR=$($HDC_CMD shell "ls -d $try 2>/dev/null" | head -1) || true
          [ -n "$APP_DIR" ] && break
        done
        if [ -z "$APP_DIR" ]; then
          # 通过 bundle 名搜索
          APP_DIR=$($HDC_CMD shell "find /data -maxdepth 8 -name 'files' -path '*egad*' -type d 2>/dev/null | head -1") || true
        fi
        if [ -z "$APP_DIR" ]; then
          # 直接列出可用的 el2 目录
          APP_DIR=$($HDC_CMD shell "ls -d /data/storage/el2/base/*/entry/files 2>/dev/null | head -1") || true
        fi

    if [ -n "$APP_DIR" ]; then
      TTS_DIR="$APP_DIR/tts/$DIR_NAME"
      EXIST_FILES=$($HDC shell "ls '$TTS_DIR/' 2>/dev/null | head -3" || true)
      if [ -n "$EXIST_FILES" ]; then
        EXIST_SIZE=$($HDC shell "du -sh '$TTS_DIR' 2>/dev/null" | cut -f1 || echo "?")
        echo "📱 设备上已有模型: $TTS_DIR ($EXIST_SIZE)"
        echo -n "是否重新推送? [y/N] "
        read -r RE_PUSH
        if [ "$RE_PUSH" != "y" ] && [ "$RE_PUSH" != "Y" ]; then
          echo "跳过。"
          exit 0
        fi
      fi
    fi
  fi
fi

# ---------- 下载 ----------
WORK_DIR="/tmp/tts-model-$$"
mkdir -p "$WORK_DIR"
ARCHIVE="$WORK_DIR/$DIR_NAME.tar.bz2"

if [ -f "${HOME}/Downloads/$DIR_NAME.tar.bz2" ]; then
  echo "📦 使用已有下载: ~/Downloads/$DIR_NAME.tar.bz2"
  cp "${HOME}/Downloads/$DIR_NAME.tar.bz2" "$ARCHIVE"
else
  echo "⬇️  下载 $URL ..."
  curl -L -o "$ARCHIVE" "$URL"
fi

echo "📂 解压..."
tar xjf "$ARCHIVE" -C "$WORK_DIR"
MODEL_DIR="$WORK_DIR/$DIR_NAME"
FILE_COUNT=$(find "$MODEL_DIR" -type f | wc -l)
MODEL_SIZE=$(du -sh "$MODEL_DIR" | cut -f1)
echo "   文件数: $FILE_COUNT, 大小: $MODEL_SIZE"

if [ "$OPT" = "download" ]; then
  echo ""
  echo "✅ 下载完成: $MODEL_DIR"
  echo "   稍后推送: $HDC file send $MODEL_DIR '$TTS_DIR'"
  exit 0
fi

# ---------- 推送 ----------
if [ -z "$HDC" ]; then
  echo "❌ 未找到 hdc，模型在: $MODEL_DIR"
  echo "   手动推送: hdc file send $MODEL_DIR '<设备上 App 沙箱>/tts/$DIR_NAME'"
  exit 1
fi

if [ -z "$APP_DIR" ]; then
  # 通过 /data/local/tmp 中转（hdc shell 无权限直接访问沙箱）
  APP_DIR="/data/local/tmp/io_legado_hos/tts_import"
  echo "⚠️  使用中转目录: $APP_DIR"
  echo "   推送后需在 App 中点击「导入模型」完成安装。"
fi

echo ""
echo "=== 推送至 $APP_DIR/$DIR_NAME ==="
$HDC_CMD shell "mkdir -p '$APP_DIR'"
$HDC_CMD file send "$MODEL_DIR" "$APP_DIR/"
$HDC_CMD shell "chmod -R 755 '$APP_DIR/$DIR_NAME' 2>/dev/null || true"

echo ""
echo "✅ 完成! 打开 App 并切换到'$([[ $MODEL_TYPE == 'vits' ]] && echo '自然语音（流畅）' || echo '自然语音（高品质）')'即可。"
