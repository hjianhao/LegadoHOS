# LegadoHOS — Agent 指南

> 鸿蒙原生开源阅读 App，基于 ArkTS（ArkUI）开发。
> 详细设计文档见 `doc/` 目录。

## HarmonyOS 构建环境（macOS）

### 工具链路径
- **Node.js**: `/Applications/DevEco-Studio.app/Contents/tools/node/bin/node` (v24.14.1)
- **Hvigor**: `/Applications/DevEco-Studio.app/Contents/tools/hvigor/bin/hvigorw` (v6.26.1)
- **HDC**: `/Applications/DevEco-Studio.app/Contents/sdk/default/openharmony/toolchains/hdc` (v3.2.0e)
- **Ohpm**: `/Applications/DevEco-Studio.app/Contents/tools/ohpm/bin/ohpm`
- **SDK**: `/Applications/DevEco-Studio.app/Contents/sdk` (HarmonyOS 26.0.0 Beta1)

### 环境变量（构建前设置）
```bash
export PATH="/Applications/DevEco-Studio.app/Contents/tools/node/bin:$PATH"
export DEVECO_SDK_HOME="/Applications/DevEco-Studio.app/Contents/sdk"
export NODE_HOME="/Applications/DevEco-Studio.app/Contents/tools/node"
```

### 构建命令
```bash
cd /Users/hjianhao/Code/ai/LegadoHOS && ./scripts/build.sh [debug|release]
```

### 签名证书
位于 `~/.ohos/config/`，已配置好 debug 签名（cert/key/profile/store 齐全）。

## 项目结构要点
- **ArkTS 源码**: `entry/src/main/ets/`
- **QuickJS C++ 桥接**: `libraries/quickjs/src/napi_bridge.cpp`
- **CMakeLists.txt**: `entry/src/main/cpp/CMakeLists.txt`
- **数据库**: 12 张 RDB 表（`ets/data/database/`）
- **书源引擎**: `ets/engine/source/`

## 参考项目
- **Android 版 Legado（参考实现）**: `/Users/hjianhao/code/ai/legado-with-MD3`

## CodeGraph 优先

本仓库已索引 CodeGraph（`.codegraph/` 目录存在），开发时应优先使用：

- **查询代码**：先用 `codegraph explore`（一次调用获取相关符号源码 + 调用链），替代 `grep` + `cat` 循环
- **读文件**：用 `codegraph node <file>` 替代 `cat`，附带依赖关系
- **查调用者**：改代码前用 `codegraph callers` 了解影响范围
- **搜索符号**：用 `codegraph search` 快速定位

### 开发工作流

1. 用 CodeGraph 理解现有代码
2. 修改代码（ArkTS / C++ / 配置文件）
3. 运行 `./scripts/build.sh` 编译
4. 编译通过后运行 `codegraph sync` 更新符号数据库

## deveco-cli MCP 服务

已安装 `@deveco/deveco-cli`（v1.0.0）并注册为 MCP 服务 `deveco-mcp`。

### 提供的工具
- **check** — 对 .ets 和 C/C++ 文件做静态语法检查
- **build** — 编译构建（调用底层 hvigor）
- **device** — 查看和管理设备
- **log** — 实时获取设备日志
- **docs** — 搜索和阅读鸿蒙官方文档

### 使用场景
- 修改代码后先 `check` 再 `build`，减少编译失败次数
- 接入真机/模拟器后通过 `log` 抓取应用日志调试
- 遇到鸿蒙 API 问题时用 `docs search` 查询本地文档

### 开发工作流（完整版）

1. **CodeGraph** 查询理解现有代码
2. 修改代码
3. **devecocli check** 语法检查
4. **devecocli build** 编译构建
5. **codegraph sync** 更新符号索引
6. **devecocli device** + **devecocli log** 真机调试

## arkts-lsp-proxy MCP 服务

已配置，提供 ArkTS 语言智能支持（桥接 DevEco ace-server）。

### 提供的工具
- **arkts_project_info** — 获取项目 ace-server 初始化元数据
- **arkts_document_symbols** — 解析 .ets 文件的符号结构
- **arkts_workspace_symbols** — 搜索整个项目的 ArkTS 符号
- **arkts_hover** — 获取某个位置的类型/悬停信息
- **arkts_definition** — 跳转到符号定义
- **arkts_references** — 查找符号的所有引用
- **arkts_signature_help** — 函数签名提示
- **arkts_diagnostics** — 获取文件的诊断错误信息

### 使用场景
- 写代码时用 `arkts_hover` 确认 API 签名
- 改代码后先 `arkts_diagnostics` 检查错误，再编译
- `arkts_references` 替代 grep 查找符号引用（比 CodeGraph 更精确的 AST 级别）
- `arkts_definition` 跳转到 ArkTS SDK 内部定义

## harmonyos-ai-workspace 规则包

已安装（包含 skill、lint 钩子、OHPM 黑白名单）。

### 关键能力
- **状态管理校验**：post-edit 钩子实时拦截 `this.list.push()` 等不触发 UI 刷新的写法
- **OHPM 包名校验**：内置黑白名单，防止写出假包名
- **Skill 包**：`.claude/skills/` 下包含 arkts-rules、state-management、build-debug 等 8 个领域 skill
- **harmony-dev-cycle**：一键 build→install→run→抓日志闭环（`bash tools/harmony-dev-cycle.sh cycle-once`）

### 配套：mcp-harmonyos 服务（设备管理）
- **harmonyos_list_devices** — 列出设备
- **harmonyos_get_device_info** — 设备详情
- **harmonyos_get_project_info** — 项目信息
- **harmonyos_install_app** — 安装 HAP 到设备
- **harmonyos_launch_app** — 启动应用
- **harmonyos_tail_hilog** — 抓取设备日志
- **harmonyos_screenshot** — 截屏

## 完整开发工作流（总览）

```
1. CodeGraph / arkts-lsp / harmonyos-ai-workspace   ← 查代码/查规范
2. 修改代码（.ets / .ts / .cpp / 配置文件）
3. arkts_lsp.diagnostics / devecocli check             ← 语法检查
4. devecocli build / ./scripts/build.sh               ← 编译
5. codegraph sync                                      ← 更新符号索引
6. mcp-harmonyos (install / launch / hilog)             ← 真机调试
```
