# LegadoHOS — Agent 指南

> 鸿蒙原生开源阅读 App，基于 ArkTS（ArkUI）开发。
> 详细设计文档见 `doc/` 目录。

## 角色选择与使用规则

项目中的专业角色定义统一存放在 `roles.md`。

### 默认角色

当用户没有明确指定角色时，默认使用 `roles.md` 中的：

* `harmonyos-senior-developer`：资深鸿蒙应用开发工程师

默认角色适用于本项目中的需求分析、架构设计、ArkTS/ArkUI 开发、代码修改、性能优化、问题排查、测试和工程构建等任务。

不需要向用户提示“正在使用默认角色”，除非角色选择本身会显著影响任务结果，或者需要解释不同角色之间的职责边界。

### 显式指定角色

当用户明确指定角色，例如：

* “你作为资深鸿蒙应用开发工程师……”
* “请以软件架构师的身份分析……”
* “让测试工程师检查这个功能……”

Agent 必须：

1. 读取 `roles.md`。
2. 查找与用户指定角色最匹配的角色定义。
3. 按该角色的职责、工作流程、输出要求和行为约束执行任务。
4. 同时遵守本文件中的全局规则。
5. 当角色规则与 `agents.md` 的全局规则冲突时，以 `agents.md` 为准。
6. 当角色规则与用户当前明确要求冲突时，优先满足用户当前要求，但不得违反安全、平台和项目硬性约束。

### 自动选择辅助角色

当用户没有明确指定角色，但任务明显需要其他专业能力时，可以从 `roles.md` 中选择辅助角色。

例如：

* 涉及整体模块划分时，可以增加软件架构师作为辅助角色。
* 涉及数据库结构时，可以增加数据库设计师作为辅助角色。
* 涉及性能数据和卡顿时，可以增加性能优化专家作为辅助角色。
* 涉及测试方案时，可以增加测试工程师作为辅助角色。

自动增加辅助角色时，不必向用户逐一报告角色名称，除非这有助于解释分析范围或不同方案之间的取舍。

### 多角色协作

当任务同时涉及多个领域时，应明确：

* 主角色
* 辅助角色
* 每个角色负责的分析范围

默认情况下：

* 主角色仍为 `harmonyos-senior-developer`。
* 其他角色仅补充其专业领域的分析。
* 最终输出应合并为统一方案，不得简单拼接多份重复结论。

### 角色缺失处理

当用户指定的角色在 `roles.md` 中不存在时：

1. 优先选择职责最接近的现有角色。
2. 基于用户描述临时补充该角色所需的专业视角。
3. 不得虚构 `roles.md` 中已经存在该角色。
4. 如果该角色会被长期重复使用，可以建议后续将其加入 `roles.md`。

### 角色使用原则

* 角色用于增强专业判断，不得覆盖用户的明确要求。
* 不得因为加载角色而忽略项目现有代码和实际约束。
* 不得机械套用角色模板。
* 必须结合当前项目的 SDK、API Version、目录结构和编码风格。
* 不得为简单任务加载大量无关角色。
* 默认角色无需每次重新声明。
* 角色只决定分析视角和工作方式，不代表可以虚构平台能力或项目事实。


## HarmonyOS 构建环境（macOS / Windows）

### 工具链路径策略
- **macOS 默认 DevEco Home**: `/Applications/DevEco-Studio.app/Contents`
- **Windows 默认 DevEco Home**: 通常为 `C:\Program Files\Huawei\DevEco Studio`
- **Node.js**: `$DEVECO_HOME/tools/node`
- **Hvigor**: `$DEVECO_HOME/tools/hvigor/bin/hvigorw` 或 `hvigorw.bat`
- **HDC**: `$DEVECO_SDK_HOME/default/openharmony/toolchains/hdc`
- **Ohpm**: `$DEVECO_HOME/tools/ohpm/bin/ohpm`
- **SDK**: `$DEVECO_HOME/sdk`，可用 `DEVECO_SDK_HOME` 覆盖

### macOS 环境变量（构建前设置）
```bash
export DEVECO_HOME="/Applications/DevEco-Studio.app/Contents"
export DEVECO_SDK_HOME="$DEVECO_HOME/sdk"
export NODE_HOME="$DEVECO_HOME/tools/node"
export PATH="$NODE_HOME/bin:$DEVECO_HOME/tools/ohpm/bin:$DEVECO_SDK_HOME/default/openharmony/toolchains:$PATH"
```

### Windows PowerShell 环境变量（构建前设置）
```powershell
$env:DEVECO_HOME = "C:\Program Files\Huawei\DevEco Studio"
$env:DEVECO_SDK_HOME = "$env:DEVECO_HOME\sdk"
$env:NODE_HOME = "$env:DEVECO_HOME\tools\node"
$env:Path = "$env:NODE_HOME;$env:DEVECO_HOME\tools\ohpm\bin;$env:DEVECO_SDK_HOME\default\openharmony\toolchains;$env:Path"
```

### 构建命令
```bash
cd /Users/hjianhao/Code/ai/LegadoHOS && ./scripts/build.sh [debug|release]
```
```powershell
cd <repo-root>
.\scripts\build.ps1 [debug|release]
```

### 签名证书
签名材料是每台机器本地配置。macOS 通常位于 `~/.ohos/config/`，Windows 通常位于用户目录下的 `.ohos/config/`。跨平台协作时不要提交个人证书或本机私钥。

## 项目结构要点
- **ArkTS 源码**: `entry/src/main/ets/`
- **QuickJS C++ 桥接**: `libraries/quickjs/src/napi_bridge.cpp`
- **CMakeLists.txt**: `entry/src/main/cpp/CMakeLists.txt`
- **数据库**: 12 张 RDB 表（`ets/data/database/`）
- **书源引擎**: `ets/engine/source/`

- **临时目录**: 所有中间过程生成的临时文件放到临时目录下。`tmp`
- **文档目录**: 所有文档放在 `doc`

### 文档说明
'doc/source.md' : 书源规则
'doc/verified_source.json' : 用于测试过的书源配置
'doc/ref' : 参考文档
'doc/modules' : 具体功能的设计

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
3. macOS 运行 `./scripts/build.sh` 编译，Windows 运行 `.\scripts\build.ps1`
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

## 书源兼容性规则

**核心原则：尽可能兼容 Android 版 Legado 的书源，优先修改我们的代码而非改源配置。**

当定位到书源功能异常时，首先判断是源规则写错了还是我们的代码没有按规则实现：

1. **代码问题（优先修代码）**：如果我们的代码没有按照 Android 版 Legado 的规则语义实现（如 `&&` 连接符应合并结果而非取第一个、`[class~=val]` 无引号属性选择器应支持、`coverDecodeJs` 字段应持久化到数据库等），**必须修改我们的代码**以满足规则标准，不得通过改源配置来绕过代码缺陷。

2. **源规则问题（改源）**：如果源规则本身不符合 CSS/Legado 规范（如 `[class="novel_list"]` 对多 class 元素做精确匹配），可以修改源配置。

3. **无法实现的情况（需确认）**：如果遇到 Android 版依赖但我们在鸿蒙端暂时无法实现的能力（如复杂的 Java 桥接函数 `java.createSymmetricCrypto` 需要完整的 JS 执行环境），**不要自行改源绕过**，应提出来进行方案确认，讨论是扩展 QuickJS 引擎能力还是用其他方式兼容。

判断依据：参考 Android 版 Legado（`/Users/hjianhao/code/ai/legado-with-MD3`）的对应实现，以它的行为为标准。

## 代码安全规则

**禁止使用 `git checkout` 回退文件！** 工作区中可能含有尚未 commit 的重要代码。
如需查看历史版本，使用 `git show <commit>:<path>` 输出到临时文件。
如需重置某个文件，仅当确认工作区改动全部不需要时才可执行 checkout。

## Git 工作流规范

### 做任何较大改动前
```bash
# 1. 先提交当前稳定状态
git add -A && git commit -m "描述当前状态"

# 2. 创建功能分支
git checkout -b feat/功能名

# 3. 在分支上开发，通过验证后再合回 main
```

### 基本原则
- **不要直接回退代码**——用 `git checkout` 前必须先征求确认。已提交的代码可通过 `git revert` 回退。
- **优先用 Edit 工具**——`sed` 易产生语法错误，应优先用 Edit 做精确替换。
- **每次改动后立刻编译验证**——`./scripts/build.sh` 通过才算完成。

### 提交时机
- 一个完整的功能点调通后立即 commit
- 不要在大量未验证改动上继续堆叠
- commit message 用中文描述改了什么

## 深色模式 / 浅色模式规范

**所有新增页面和组件必须同时支持深色和浅色模式。**

### 1. 引入 ThemeColors
```typescript
import { ThemeColors } from '../theme/ThemeColors';
```

### 2. 声明 isDark
```typescript
@StorageLink('isDark') isDark: boolean = false;
```

### 3. 使用语义化 Token（禁止硬编码颜色）

| 用途 | 正确写法 |
|------|----------|
| 页面背景 | `ThemeColors.background(this.isDark)` |
| 正文文字 | `ThemeColors.onBackground(this.isDark)` |
| 卡片/浮层背景 | `ThemeColors.surface(this.isDark)` |
| 卡片上文字 | `ThemeColors.onSurface(this.isDark)` |
| 分割线/边框 | `ThemeColors.outlineVariant(this.isDark)` |
| 次要说明文字 | `ThemeColors.secondaryText(this.isDark)` |
| 主色调/链接 | `ThemeColors.primary(this.isDark)` |
| 错误/删除色 | `ThemeColors.error(this.isDark)` |

### 4. 禁止写法
- ❌ `this.isDark ? '#E0E0E0' : '#1A1A2E'` — 硬编码文字色
- ❌ `this.isDark ? '#121212' : '#F5F5F5'` — 硬编码背景色
- ❌ `'#0078D7'` — 硬编码主色调
- ❌ `'#888'` / `'#999'` — 硬编码灰色
- ❌ Text 组件不设置 fontColor — 深色模式下默认黑色，不可见

### 5. 统一定义位置
所有颜色统一在 `entry/src/main/ets/theme/ThemeColors.ets` 中修改，全局生效。

#