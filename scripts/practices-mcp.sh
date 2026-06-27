#!/bin/bash
# harmonyos-best-practices-mcp wrapper — 设置正确的资料目录路径
DIR="$(cd "$(dirname "$0")/.." && pwd)"
export BP_INDEX="$DIR/node_modules/harmonyos-best-practices-mcp/data/code_list.md"
export BP_LOG="$DIR/node_modules/harmonyos-best-practices-mcp/data/index_log.txt"
exec node "$DIR/node_modules/.bin/harmonyos-best-practices-mcp" "$@"
