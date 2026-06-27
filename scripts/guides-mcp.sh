#!/bin/bash
# harmonyos-guides-mcp wrapper — 设置正确的资料目录路径
DIR="$(cd "$(dirname "$0")/.." && pwd)"
export BP_DOCS_DIR="$DIR/node_modules/harmonyos-guides-mcp/data"
export BP_LOG="$DIR/node_modules/harmonyos-guides-mcp/data/index_log.txt"
exec node "$DIR/node_modules/.bin/harmonyos-guides-mcp" "$@"
