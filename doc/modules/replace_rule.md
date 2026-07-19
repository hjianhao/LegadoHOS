# 替换净化（ReplaceRule）功能设计

> 对标 Android 版 Legado（`/Users/hjianhao/code/ai/legado-with-MD3`）。
> 结论先行：鸿蒙端表、模型、替换引擎、清洗管线均已存在，但 **阅读管线未接入、DAO 只有 getAllEnabled、无管理 UI**。本方案在既有基础上补全，而不是从零开发。

## 一、安卓版净化功能分析

### 1.1 数据模型（`data/entities/ReplaceRule.kt`）

| 字段 | 类型 | 默认 | 含义 |
|---|---|---|---|
| id | Long | currentTimeMillis | 主键（自增） |
| name | String | "" | 规则名称 |
| group | String? | null | 分组（可多个，`,`/`;` 分隔） |
| pattern | String | "" | 匹配内容（正则或普通文本） |
| replacement | String | "" | 替换为（空 = 删除；`@js:` 开头走 JS 求值） |
| scope | String? | null | 作用范围：书名或书源 URL 的子串，多个拼接；空 = 全部书 |
| scopeTitle | Bool | false | 作用于标题 |
| scopeContent | Bool | true | 作用于正文 |
| excludeScope | String? | null | 排除范围（书名/书源子串） |
| isEnabled | Bool | true | 启用开关 |
| isRegex | Bool | true | pattern 是否按正则解释 |
| timeoutMillisecond | Long | 3000 | 单条规则正则替换超时 |
| order(sortOrder) | Int | MIN_VALUE | 执行/列表顺序 |

表名 `replace_rules`，Room 建表（schema v70）。

### 1.2 规则语义

- **scope 匹配是 SQL 子串包含**：`scope LIKE '%书名%' OR scope LIKE '%书源URL%' OR scope IS NULL OR scope=''`，且 `excludeScope` 不包含书名/书源。命中且 `isEnabled=1`、`scopeContent=1` 的规则进入正文净化（标题用 `scopeTitle=1`）。
- **执行顺序**：按 `sortOrder` 升序逐条应用，上一条的输出是下一条的输入。
- **isRegex=false**：普通字符串替换；**isRegex=true**：正则替换，支持 `$1` 分组引用。
- **replacement 以 `@js:` 开头**：用 JS 引擎求值，绑定 `result`（匹配文本）、`chapter`、`book`。
- **两级开关**：全局 `replaceEnableDefault`（默认开）+ 每书 `Book.config.useReplaceRule`（图片书/EPUB 默认关）。

### 1.3 实施流程（两级净化）

```
① 书源级净化（下载时，固化进缓存）
   WebBook.getContent → BookContent.analyzeContent
     → HtmlFormatter.formatKeepImg（内置 HTML 清洗）
     → 书源 ruleContent.replaceRegex 全文替换
     → BookHelp.saveContent 写缓存文件

② 用户规则净化（展示时，实时、不进缓存）
   ReadBook.loadContent → BookHelp.getContent 读缓存原文
     → ContentProcessor.getContent(book, chapter, content)
        1. 去重复标题   2. 重新分段   3. 简繁转换
        4. 逐条应用 contentReplaceRules（scope 匹配 + isEnabled）
     → ChapterProvider 排版 → 阅读页渲染
```

关键设计：**用户规则净化发生在缓存读取之后、排版之前，净化结果不落缓存**。因此改规则无需清缓存，`replaceRuleChanged()` 只需刷新内存规则列表并重排版。`ContentProcessor` 按 `bookName+bookOrigin` 缓存（WeakReference 池），规则列表预加载（`CopyOnWriteArrayList`）。

### 1.4 正则超时保护

- 替换在 IO 协程执行，主线程 `postDelayed(timeout)` 看门狗：超时 → 抛 `RegexTimeoutException` 取消协程、toast、**该规则自动禁用并写库**（防止每章都卡死）。
- 兜底：超时 3 秒后协程仍未结束则重启 App（Java 正则不可中断的妥协）。
- 保存校验：`isValid()` 试编译 pattern，并拦截「以 `|` 结尾但非 `\|`」的易卡死 pattern。

### 1.5 管理功能（ReplaceRuleActivity）

- 列表：搜索（name/pattern/replacement/scope）、分组 Tab、四种排序、拖动排序、单条启停、置顶/置底/删除、多选批量操作。
- 编辑：名称/pattern/replacement/标题/内容/正则开关/scope/excludeScope/超时/分组，正则快捷输入条，剪贴板复制粘贴 JSON。
- 导入：本地文件 / URL / 剪贴板；新格式 JSON 数组；**兼容旧版格式**（`regex→pattern`、`replaceSummary→name`、`useTo→scope`、`enable→isEnabled`、`serialNumber→order`）；按 id 去重，标记 New/Update/Existing。
- 导出：JSON 数组写本地文件或上传取链接。
- App **不内置默认净化规则**。
- 阅读页入口：菜单「替换净化」开关、「替换净化设置」、长按文本「替换」快捷新建（自动带 `scope=书名;书源URL`）。

## 二、鸿蒙端现状

### 已有资产

- `model/ReplaceRule.ts`：实体接口（字段与安卓基本对齐，但 **scope 是枚举** `GLOBAL/SOURCE/BOOK` + `scopeValue`，与安卓的字符串子串语义不同）。
- `data/database/ReplaceRuleTable.ts`：`replace_rules` 表已建（`AppDatabase.doInit`），但 DAO **只有 `getAllEnabled()`**。
- `engine/book/ContentReplace.ts`：`ContentReplaceEngine`（loadRules + apply，按 scope 过滤，正则/纯文本替换，单条 try/catch）。
- `util/ContentCleaner.ts`：完整移植三层清洗，`processContent()`（去重标题→规则替换→分段）**已写好但无调用方**。
- 书源级 `ruleContent.replaceRegex`：已在 `SourceExecutor.getContent` 中处理（抓取时执行，固化进缓存）——与安卓①一致。
- 已应用处：书内搜索（`SearchContentPage.ets`）、导出（`BookExportService.ts`）。
- `BackupService.ts` 已把 `replace_rules` 纳入备份。

### 缺口

1. `ReadPage.ets` 阅读显示路径不接用户规则（`requirement.md` R-039h 标"完成"与实际不符）。
2. `ReplaceRuleTable` 缺 CRUD/启停/排序/scope 匹配查询。
3. 无管理 UI（页面、路由、入口均无）。
4. 数据模型与安卓不完全兼容（scope 枚举 vs 字符串；缺 group/scopeTitle/scopeContent/excludeScope/timeout），**影响安卓规则 JSON 导入兼容**。

## 三、需求清单

| 编号 | 需求 | 优先级 |
|---|---|---|
| RR-1 | 数据模型对齐安卓（scope 字符串语义、group、scopeTitle/scopeContent、excludeScope、timeoutMillisecond、order），支持 ALTER TABLE 迁移 | P0 |
| RR-2 | ReplaceRuleTable 补全 CRUD、批量启停、排序、scope 匹配查询（安卓同款 SQL） | P0 |
| RR-3 | 阅读管线接入：正文缓存读出后、排版前应用规则，净化结果不写缓存；标题净化同步接入 | P0 |
| RR-4 | 全局开关 + 每书开关；规则变更后当前书立即重排生效（不清缓存） | P0 |
| RR-5 | 管理页：列表（搜索/启停/删除/排序）+ 编辑页（全字段） | P0 |
| RR-6 | 导入（文件/URL/剪贴板，新旧两种格式，按 id 去重）+ 导出 JSON | P1 |
| RR-7 | 分组功能（Tab 过滤、编辑时选分组） | P1 |
| RR-8 | 阅读页菜单：净化开关 + 跳管理页 | P1 |
| RR-9 | 正则安全：保存时校验编译；替换单条 try/catch 跳过（超时保护受 ArkTS 限制，见风险） | P0 |
| RR-10 | 导出/搜索/离线缓存等已有应用点切换到新模型 | P1 |

不做（本期）：`@js:` replacement 求值（安卓走 Rhino，我们可对齐走 QuickJS，但使用率低，先跳过并在编辑页提示不支持）；拖动排序；API 服务控制器。

> **实施状态（2026-07，feat/replace-rule 分支）**：RR-1~RR-3、RR-5~RR-9 已完成；RR-4 完成全局开关，每书开关（RR-4b）未做；RR-10 完成（搜索/导出已切换）。导入无预览勾选列表（简化为直接落库+统计 toast）；阅读页长按文本快捷新建未做；`timeoutMillisecond` 仅数据兼容不强制中断。已完成编译验证与模拟器启动冒烟（书架正常渲染、无 Error 日志），管理页 UI 交互未做真机逐项验证。

## 四、详细实现方案

### 4.1 数据模型与迁移（RR-1）

`model/ReplaceRule.ts` 重写为安卓对齐结构：

```ts
export interface ReplaceRule {
  id: number;            // 自增主键
  name: string;
  group: string;         // '' = 未分组
  pattern: string;
  replacement: string;
  scope: string;         // '' = 全部；书名/书源URL 子串，可多个拼接
  scopeTitle: boolean;
  scopeContent: boolean;
  excludeScope: string;
  isEnabled: boolean;
  isRegex: boolean;
  timeoutMillisecond: number; // 保留数据兼容，暂不做强制中断
  order: number;
}
```

建表 SQL 改为安卓列名（snake_case），`AppDatabase.doInit` 中对已有旧表做迁移：旧表 scope 是 INTEGER 枚举，与字符串语义不兼容，直接 `DROP TABLE replace_rules` 重建（现网表必为空——没有 UI 能写入，无损）。旧表若需保留则加列迁移，但判断收益为零，选 DROP 重建。

### 4.2 DAO（RR-2）

`ReplaceRuleTable.ts` 照 `ChapterTable` 模式补全：

- `getAll(sortMode)`、`insert/update/delete`、`updateEnabled(id(s), enabled)`
- `findEnabledByContentScope(name, origin)` / `findEnabledByTitleScope(name, origin)`——用 `querySql` 直写安卓同款 SQL（RdbPredicates 表达不了这种 OR/NULL 组合）：

```sql
SELECT * FROM replace_rules WHERE isEnabled = 1 AND scopeContent = 1
AND (scope LIKE '%' || ? || '%' OR scope LIKE '%' || ? || '%' OR scope IS NULL OR scope = '')
AND (excludeScope IS NULL OR (excludeScope NOT LIKE '%' || ? || '%' AND excludeScope NOT LIKE '%' || ? || '%'))
ORDER BY sortOrder
```

注意 SQL 注入：name/origin 走 bindArgs 占位符，不拼接。

### 4.3 净化引擎与阅读管线接入（RR-3/RR-4/RR-9）

改造 `ContentReplace.ts` 的 `ContentReplaceEngine`（或直接在 `ContentCleaner.processContent` 内联）：

1. `apply(text, rules)`：逐条 `isRegex ? text.replace(new RegExp(pattern,'g'), replacement) : text.split(pattern).join(replacement)`，单条 try/catch 记日志跳过；`new RegExp` 编译失败即跳过该条。
2. **接入点**：`ReadPage.ets` `fetchChapterContent_` 返回后、`convertChinese` 之前（或之后，对齐安卓顺序：安卓是先简繁后替换，保持一致放其后）；标题净化在设置章节标题处应用 `titleRules`。
3. **只作用于展示**：`saveToDbCache_` 保存的是 `getContent` 原始返回（含书源级 replaceRegex，与安卓①一致），用户规则结果不落库。离线缓存 `BookCacheService` 同样存原文。
4. **每书规则缓存**：`ReadPage` 持有 `contentRules_/titleRules_`，`aboutToAppear` 时 `findEnabledByXxxScope(bookName, sourceUrl)` 加载一次；提供 `reloadReplaceRules_()` 供规则变更后调用并 `layoutText()` 重排。
5. **开关**：全局 `replaceEnabled` 存 `SettingsStore`（仿现有设置项）；每书开关存 `books` 表配置列（如无则先入全局设置，每书开关 RR-4b 放 P1）。阅读页菜单加「替换净化」开关项（RR-8）。

### 4.4 管理 UI（RR-5/RR-6/RR-7）

仿 `pages/BookSourcePage.ets` 结构新建两个页面，注册进 `main_pages.json`，入口加在 `MyPage.ets` 菜单数组：

- `ReplaceRulePage.ets`：标题栏（计数+新建+导入）→ 搜索框 → 分组 chips（RR-7）→ 规则 List（名称/pattern 摘要/`Toggle` 启停/⋮ 菜单：编辑、删除）→ 底部批量栏（全选/批量启停/删除/导出）。
- `ReplaceRuleEditPage.ets`：表单字段 = name/group/pattern/replacement/isRegex/scopeTitle/scopeContent/scope/excludeScope/timeoutMillisecond；保存前 `isValid()` 校验（pattern 非空、isRegex 时 `new RegExp` 试编译、拦截裸 `|` 结尾）。
- **导出**：`DocumentViewPicker` 写 JSON 数组（字段名与安卓一致，保证安卓可导入）。
- **导入**：文件/剪贴板/URL 三入口（复用 `ImportSourceDialog` 模式）；解析时兼容旧格式字段映射（`regex→pattern` 等）；按 `id` 去重，已存在且内容变化 → 更新，完全一致 → 跳过。
- 全程遵守深色/浅色规范（`ThemeColors` + `@StorageLink('isDark')`）。

### 4.5 既有调用点迁移（RR-10）

`SearchContentPage.ets`、`BookExportService.ts` 目前用旧 `ContentReplaceEngine.apply(text, sourceUrl, bookUrl)`，切换到「先查 `findEnabledByContentScope` 再 apply」的新接口，行为对齐阅读页。

### 4.6 风险与限制

- **正则超时无法强制中断**：ArkTS 的 JS RegExp 同步执行，没有协程取消 + 看门狗的对等机制。缓解：保存时严格校验 + 拦截高危 pattern（裸 `|` 结尾、`(.*)*` 类嵌套量词可做静态嗅探）；执行放非 UI 上下文。`timeoutMillisecond` 字段保留以兼容导入导出，UI 标注"暂不支持强制超时"。
- **`@js:` replacement 不支持**：导入含 `@js:` 的规则时提示并按普通文本处理。
- **改动顺序建议**：4.1 → 4.2 → 4.3（阅读接入，可先用 SQL 手插规则验证）→ 4.4（UI）→ 4.5，每步 `./scripts/build.sh` 验证后 commit。
