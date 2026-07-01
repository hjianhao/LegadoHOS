# 搜索模块设计

> 目标：沉淀 Android 版 Legado 搜索框/搜索页的产品规格，并对照当前 LegadoHOS 鸿蒙实现，明确已实现、部分实现和未实现范围。
> 更新日期：2026-07-01

---

## 1. 范围与术语

本文档覆盖“找书搜索”主流程，即从搜索入口输入关键词，经搜索建议、范围筛选、多书源并发搜索、结果展示、分页加载到进入书籍详情的完整搜索对话框/搜索页面体验。

Android 参考实现来自 `/Users/hjianhao/code/ai/legado-with-MD3`：

| 模块 | 文件 |
|------|------|
| 搜索 Activity | `app/src/main/java/io/legado/app/ui/book/search/SearchActivity.kt` |
| 搜索 UI | `app/src/main/java/io/legado/app/ui/book/search/SearchScreen.kt` |
| 搜索状态与意图 | `app/src/main/java/io/legado/app/ui/book/search/SearchContract.kt` |
| 搜索 ViewModel | `app/src/main/java/io/legado/app/ui/book/search/SearchViewModel.kt` |
| 搜索框组件 | `app/src/main/java/io/legado/app/ui/widget/components/SearchBar.kt` |
| 搜索范围弹层 | `app/src/main/java/io/legado/app/ui/book/search/ScopeSelectSheet.kt` |
| 书内搜索 | `app/src/main/java/io/legado/app/ui/book/searchContent/SearchContentScreen.kt` |

鸿蒙当前实现来自 LegadoHOS：

| 模块 | 文件 |
|------|------|
| 主搜索页 | `entry/src/main/ets/pages/SearchPage.ets` |
| 搜索引擎 | `entry/src/main/ets/engine/source/SourceExecutor.ts` |
| 搜索结果模型 | `entry/src/main/ets/model/SearchResult.ts` |
| 搜索历史表 | `entry/src/main/ets/data/database/SearchKeywordTable.ts` |
| 当前搜索历史存储 | `entry/src/main/ets/data/preferences/SettingsStore.ts` |
| 书源模型 | `entry/src/main/ets/model/BookSource.ts` |
| 书源切换面板 | `entry/src/main/ets/components/BookInfoSheets.ets` |

状态标注：

| 状态 | 含义 |
|------|------|
| 已实现 | 鸿蒙版已经具备可用功能，行为与 Android 基本对齐 |
| 部分实现 | 鸿蒙版已有主体能力，但交互、持久化、边界处理或排序策略与 Android 有差距 |
| 未实现 | 当前鸿蒙版没有对应能力 |

---

## 2. 产品目标

搜索框不是单一输入控件，而是阅读 App 的“找书控制台”。它需要同时承担：

1. 快速输入与提交关键词。
2. 提供搜索历史和书架命中建议。
3. 控制搜索范围、匹配模式和书源类型。
4. 展示多书源搜索进度与结果数量。
5. 支持停止搜索、继续搜索和分页搜索。
6. 帮助用户从合并结果进入具体书籍详情。
7. 在筛选过严导致无结果时提供放宽筛选路径。

---

## 3. 规格差距总表

| # | 规格 | Android 行为 | 鸿蒙当前状态 | 差距说明 |
|---|------|--------------|--------------|----------|
| S-001 | 顶部搜索框 | 自动聚焦、单行输入、左侧搜索图标、IME Search 提交、右侧清空按钮 | 部分实现 | 鸿蒙有单行输入、左侧搜索图标、提交、清空；未见自动聚焦/弹键盘 |
| S-002 | 搜索提交 | `trim()` 后非空提交，清空旧结果，从第 1 页搜索 | 已实现 | `doSearch()` 已处理关键词归一、清空旧状态、重置分页 |
| S-003 | 输入防抖 | 输入变化 200ms 防抖同步 ViewModel，不实时搜索 | 已实现 | 输入变化后 200ms 防抖加载书架建议，不实时发起网络搜索 |
| S-004 | 外部带关键词打开 | `SearchActivity.start(key)` 非空自动搜索 | 已实现 | 读取路由参数 `key` / `keyword`，非空时自动提交搜索 |
| S-005 | 外部临时搜索范围 | Android 支持 `searchScope` Intent 参数 | 已实现 | 支持读取 Android 兼容的 `searchScope` JSON / legacy 字符串 |
| S-006 | 搜索历史展示 | 建议面板展示历史，空历史有空态 | 已实现 | 鸿蒙展示历史，历史为空时展示“暂无搜索建议” |
| S-007 | 点击历史搜索 | 点击历史词直接填入并提交搜索 | 已实现 | `doSearch(h)` |
| S-008 | 删除单条历史 | 每条历史有删除按钮 | 已实现 | `removeHistory()` |
| S-009 | 清空全部历史 | 有确认弹窗 | 已实现 | `showClearHistoryDialog` |
| S-010 | 历史持久化 | Android 使用搜索关键词仓储/Room，含 usage、lastUseTime | 已实现 | 主搜索页已接入 `SearchKeywordTable`，并从旧 `SettingsStore.search_history` 迁移 |
| S-011 | 书架命中建议 | 输入时展示书架命中，可直接打开书籍详情 | 已实现 | `loadBookshelfHints()` + `goToShelfBook()` |
| S-012 | 搜索范围：全部书源 | 默认全部启用书源 | 已实现 | `selectAllScope()` |
| S-013 | 搜索范围：按分组 | Android 分组选择；变更后可自动重搜 | 已实现 | 支持分组选择，“完成”后对已提交关键词自动重搜 |
| S-014 | 搜索范围：按单书源 | Android 可多选具体书源；弹层内可搜索书源 | 已实现 | 支持书源多选、弹层内过滤，“完成”后自动重搜 |
| S-015 | 搜索范围持久化 | Android 持久化 `SEARCH_SCOPE` | 已实现 | 使用兼容 JSON 字符串持久化到 `search_scope` |
| S-016 | 匹配模式：普通/精确 | 顶部按钮切换，持久化 MATCH_MODE，变更后自动重搜 | 已实现 | 持久化 `search_match_mode`，已有提交关键词时切换会自动重搜 |
| S-017 | 精确搜索策略 | Android 匹配书名、作者、分类，精确模式会影响结果收集和分页 | 已实现 | 按书名/作者完全匹配、分类匹配、书名/作者包含匹配保留结果，过滤其他项 |
| S-018 | 空范围保护 | 无可用书源时报错提示 | 已实现 | Toast “当前范围没有可搜索书源” |
| S-019 | 空结果放宽筛选 | Android 弹窗引导关闭精确或切回全部范围 | 部分实现 | 鸿蒙空态提供“放宽筛选”按钮，一次性关闭精确、类型和范围筛选 |
| S-020 | 书源类型筛选 | Android 支持小说、漫画、音频 | 已实现 | 按 `sourceType` 动态展示并标注为小说/音频/漫画，变更后自动重搜 |
| S-021 | 设置弹层 | Android 支持布局模式和书源类型 | 已实现 | 鸿蒙 `buildSettingsSheet()` 支持布局、类型、匹配 |
| S-022 | 布局模式 | Android 支持列表/按源分组，持久化 | 已实现 | 鸿蒙支持 `layoutMode` 并持久化 `search_layout_mode` |
| S-023 | 多源并发搜索 | Android 按配置并发，多源进度事件增量刷新 | 已实现 | 鸿蒙 `SourceExecutor.search()` 并发池 + progress 回调 |
| S-024 | 并发配置 | Android 用 `OtherConfig.threadCount` | 已实现 | 鸿蒙用 `AppStorage.searchConcurrency`，默认 16 |
| S-025 | 单源超时隔离 | 单源失败/超时不影响整体 | 已实现 | 鸿蒙单源 20s 超时，catch 后继续 |
| S-026 | 搜索进度展示 | 展示结果数、已处理源/总源 | 已实现 | 鸿蒙 `buildFloatingSummary()` |
| S-027 | 停止搜索 | 搜索中 FAB/按钮停止；手动停止后不自动加载 | 已实现 | 鸿蒙 `stopSearch()` 通过 `searchRunId` 取消后续回调 |
| S-028 | 生命周期暂停恢复 | Android 页面暂停时暂停搜索引擎，恢复后可继续 | 未实现 | 鸿蒙当前没有等价生命周期暂停/恢复搜索控制 |
| S-029 | 分页/继续搜索 | Android `LoadMore` 下一页，滚动近底自动加载 | 已实现 | 支持底部按钮、FAB 和列表 `onReachEnd` 自动加载下一页 |
| S-030 | hasMore 判定 | Android 综合返回事件、新页是否有新增结果、精确模式阈值 | 已实现 | 下一页无新增合并结果会停止；精确模式第一页结果少于等于 3 条时停止继续加载 |
| S-031 | 结果合并 | 同名同作者合并，多书源数量排序/展示 | 已实现 | `SearchResult.mergeSearchResults()` 和 `SourceExecutor` 增量合并 |
| S-032 | 结果排序 | Android 按完全匹配、分类匹配、包含匹配、其他、多源数排序 | 已实现 | 展示层按 Android 优先级排序，同级多源数优先 |
| S-033 | 结果书架状态 | Android 解析书架状态；点击书架命中打开本地书 | 已实现 | 鸿蒙通过 URL 和书名作者键判断，展示 `✓` 或 `↔` |
| S-034 | 结果封面 | Android 搜索结果封面 + 共享元素；长按预览 | 部分实现 | 鸿蒙展示封面、后台补封面并支持长按预览；无共享元素动画 |
| S-035 | 结果长按预览 | Android 长按打开预览 Sheet，可加入书架 | 已实现 | 长按列表/分组网格结果打开预览浮层，支持加入书架和查看详情 |
| S-036 | 按源分组结果 | Android 分组显示，每源可展开更多 | 部分实现 | 鸿蒙支持按源分组、横向预览和展开；未实现 Android 的单源分页 Sheet |
| S-037 | 查看单源全部结果 | Android `ExpandedSourceSheet` 可对单源继续分页 | 部分实现 | 鸿蒙分组内“全部/收起”仅展开当前已合并结果，不再单独拉取该源下一页 |
| S-038 | 点击搜索结果 | 打开书籍详情，携带 name/author/bookUrl/origin/cover | 已实现 | 鸿蒙 `goToBookInfo()` |
| S-039 | 搜索结果缓存传递 | Android 返回详情后保留结果和滚动；详情可利用缓存换源 | 部分实现 | 鸿蒙进入详情传 `cachedSources`，但返回搜索页的滚动/搜索状态保持依赖页面实例，缺少显式保存恢复 |
| S-040 | 结果滚动位置恢复 | Android 离开/返回保存 LazyList 位置 | 未实现 | 鸿蒙当前没有保存搜索列表滚动位置 |
| S-041 | 搜索框视觉 | Android 使用 Material/Miuix SearchBar，图标按钮和 tooltip | 部分实现 | 搜索框已有搜索图标和清空按钮；设置/精确/筛选仍是文字按钮，Tooltip/无障碍仍弱于 Android |
| S-042 | WebView 兜底 | Android 书源可触发 WebView；鸿蒙搜索页内挂隐藏 WebViewEngine | 已实现 | 鸿蒙 `WebViewEngine` 隐藏挂载，`SourceExecutor` 可检测 403/Cloudflare 后 WebView 获取 |
| S-043 | 搜索历史数据表 | Android 使用 SearchKeyword 实体 | 已实现 | 主搜索页已使用 `SearchKeywordTable`，旧偏好历史仅用于迁移 |
| S-044 | 书内搜索 | Android 书内搜索支持实时搜索、替换、正则、历史范围、定位当前章节 | 部分实现 | 已新增 `SearchContentPage` 和阅读页入口，支持实时搜索、停止、替换、正则、历史范围、定位/回跳；结果高亮为摘要级，尚非富文本逐词高亮 |

---

## 4. 核心数据

### 4.1 搜索页状态

当前鸿蒙搜索页状态集中在 `SearchPage.ets`：

| 字段 | 类型 | 说明 |
|------|------|------|
| `keyword` | `string` | 输入框当前文本 |
| `committedKeyword` | `string` | 已提交搜索词 |
| `allResults` | `SearchResult[]` | 原始合并结果，精确模式过滤前 |
| `results` | `SearchResult[]` | 当前展示结果 |
| `isSearching` | `boolean` | 第 1 页搜索中 |
| `isLoadingMore` | `boolean` | 下一页加载中 |
| `hasSearched` | `boolean` | 是否完成过或发起过搜索 |
| `manualStop` | `boolean` | 用户是否手动停止当前搜索 |
| `hasMore` | `boolean` | 是否允许继续搜索下一页 |
| `currentPage` | `number` | 当前搜索页码 |
| `sources` | `BookSource[]` | 已启用书源 |
| `processedSources` / `totalSources` | `number` | 进度计数 |
| `history` | `string[]` | 搜索历史，当前存储在 `SettingsStore.search_history` |
| `bookshelfHints` | `Book[]` | 输入关键词命中的书架书籍 |
| `showSuggestions` | `boolean` | 是否展示建议面板 |
| `showScopeSheet` / `showSettingsSheet` | `boolean` | 筛选/设置弹层 |
| `matchModeExact` | `boolean` | 精确搜索开关 |
| `layoutMode` | `number` | `0` 列表，`1` 按源分组 |
| `selectedSourceTypes` | `number[]` | 书源类型筛选 |
| `selectedGroups` | `string[]` | 书源分组筛选 |
| `selectedSourceUrls` | `string[]` | 指定书源筛选 |
| `scopeBySource` | `boolean` | 当前范围弹层处于书源选择模式 |
| `expandedSourceUrl` | `string` | 按源分组模式下展开的分组 |
| `shelfBookUrls` / `shelfNameAuthorKeys` | `string[]` | 书架状态判断缓存 |

### 4.2 搜索结果模型

`SearchResult` 是搜索结果和换源缓存的共享模型：

| 字段 | 说明 |
|------|------|
| `key` | 搜索结果唯一键，通常由源和详情页组合 |
| `name` / `author` | 书名、作者 |
| `coverUrl` | 封面 URL |
| `noteUrl` | 详情页 URL |
| `origin` / `originUrl` | 首个命中书源名称和 URL |
| `kind` / `wordCount` / `lastUpdateTime` / `latestChapterTitle` | 分类、字数、更新时间、最新章节 |
| `introduce` | 简介 |
| `duration` / `searchTime` | 搜索耗时和时间 |
| `sourceCount` | 合并后的来源数量 |
| `sourceOrigins` | 所有来源名称 |
| `sourceOriginUrls` | 所有来源 URL |
| `sourceNoteUrls` | 所有来源详情页 URL |

合并键由 `getBookMergeKey(name, author)` 生成：归一化书名和作者，移除括号、常见版本后缀、空白和标点；作者为空时只用书名，避免缺作者导致过度拆分。

### 4.3 书源数据

搜索依赖 `BookSource` 的规则字段：

| 字段 | 用途 |
|------|------|
| `sourceName` / `sourceUrl` | 书源展示名和唯一 URL |
| `enabled` | 是否启用 |
| `sourceType` | 书源类型筛选 |
| `group` | 分组筛选 |
| `ruleSearchUrl` | 搜索 URL 模板，支持 `{{key}}`、`{{page}}` |
| `ruleSearchList` | 搜索结果列表规则 |
| `ruleSearchName` / `ruleSearchAuthor` | 书名、作者解析 |
| `ruleSearchCover` | 封面解析 |
| `ruleSearchNoteUrl` | 详情页 URL 解析 |
| `ruleSearchKind` / `ruleSearchWordCount` / `ruleSearchLastUpdateTime` | 元信息解析 |
| `ruleSearchIntroduce` | 简介解析 |

### 4.4 历史数据

鸿蒙当前有两套能力：

1. `SearchKeywordTable`：主搜索页实际使用，包含 `word`、`usage`、`last_use_time`，提供最近历史、模糊搜索、删除、清空和数量裁剪能力。
2. `SettingsStore.search_history`：旧版字符串数组，仅作为一次性迁移来源，迁移后清空。

---

## 5. 关键设计

### 5.1 状态机

```
Idle
  ├─ 输入/聚焦且有历史或书架提示 → Suggestions
  ├─ 提交有效关键词 → Searching(page=1)
  └─ 空输入 → Idle

Suggestions
  ├─ 点击历史 → Searching(page=1)
  ├─ 点击书架命中 → BookInfoPage
  ├─ 清空输入 → HistoryOnly / Idle
  └─ 提交关键词 → Searching(page=1)

Searching
  ├─ progress 回调 → Results(partial)
  ├─ 用户停止 → ResultsStopped
  ├─ 完成且有结果 → Results(hasMore=true)
  └─ 完成且无结果 → Empty

Results
  ├─ 继续搜索 → LoadingMore(page+1)
  ├─ 修改关键词 → Suggestions
  ├─ 点击结果 → BookInfoPage
  └─ 放宽筛选 → Searching(page=1)

LoadingMore
  ├─ progress 回调 → Results(merged)
  ├─ 完成且新增结果 → Results(hasMore=true)
  └─ 完成且无结果 → Results(hasMore=false)
```

### 5.2 搜索提交流程

```
doSearch(keyword)
  → trim + 空值校验
  → getActiveSources()
    → enabled
    → has ruleSearchUrl
    → sourceType filter
    → group/source scope filter
  → 重置页面状态
  → addToHistory(keyword)
  → globalSourceExecutor.search(keyword, activeSources, onProgress, page=1)
    → 并发池
    → 单源 searchWithTimeout()
    → parseResponse(JSON/CSS/Fallback)
    → incrementMerge()
    → onProgress(partial, processed, total)
  → filterResultsByMode()
  → refreshShelfStates()
  → fetchMissingCovers()
```

### 5.3 分页加载流程

```
loadMore()
  → guard: 非搜索中、有 committedKeyword、有 hasMore
  → nextPage = currentPage + 1
  → baseResults = allResults 或 results
  → globalSourceExecutor.search(committedKeyword, activeSources, progress, nextPage)
  → mergeSearchResults(baseResults + pageResults)
  → filterResultsByMode()
  → 更新 currentPage / hasMore
```

### 5.4 停止搜索

鸿蒙当前没有真正取消底层 HTTP 请求，而是通过 `searchRunId++` 和 `manualStop` 忽略过期回调：

```
stopSearch()
  → searchRunId++
  → manualStop = true
  → isSearching = false
  → isLoadingMore = false
  → hasMore = results.length > 0
```

这能保证 UI 不再接收旧结果，但底层已发出的请求会自然结束。后续如需更强控制，可在 `SourceExecutor.search()` 中引入取消令牌。

### 5.5 精确匹配

Android 精确搜索是搜索请求的一部分，影响结果收集、排序和分页。鸿蒙当前是展示层过滤：

```
normalize(item.name) === normalize(keyword)
```

影响：

1. 搜索时仍会请求全部范围。
2. 作者、分类、包含匹配不参与精确判断。
3. 切换精确模式只是过滤现有结果，不会补搜或改变引擎策略。

建议后续将匹配模式下沉为搜索请求参数，至少在结果排序阶段对齐 Android：

1. 书名或作者完全匹配。
2. 分类匹配。
3. 书名或作者包含关键词。
4. 普通模式下保留其他结果。
5. 同优先级多源数量多者优先。

### 5.6 结果合并

结果合并目标是“同一本书只展示一条”，并聚合来源：

```
SearchResult[]
  → getBookMergeKey(name, author)
  → Map<mergeKey, SearchResult>
  → 合并 sourceOrigins/sourceOriginUrls/sourceNoteUrls
  → 保留更完整封面、简介、最新章节
```

注意事项：

1. 作者缺失时只用书名合并，可能把同名不同作者书合并，需要后续用更稳健策略修正。
2. 书源分组展示依赖 `sourceOrigins/sourceOriginUrls/sourceNoteUrls` 展开，三个数组必须同序。
3. 进入详情页时传递 `cachedSources`，换源面板依赖该缓存逐源展示。

---

## 6. 界面布局

### 6.1 主搜索页层级

```
Stack
  Column
    TopArea
      Row: 返回 / 标题 / 设置 / 精确 / 筛选
      Row: TextInput / 搜索或停止按钮
    ScopeStrip
      Chip: 当前范围
      Chip: 普通匹配或精确匹配
      Chip: 已筛类型
      Text: N源
    Body
      Suggestions | Results | Idle
    Hidden WebViewEngine
  FloatingButton
    搜索中: 停止
    有更多: 继续搜索
  SettingsSheet
  ScopeSheet
  ClearHistoryDialog
```

### 6.2 顶部搜索区

| 区域 | 当前鸿蒙实现 | Android 对齐建议 |
|------|--------------|------------------|
| 返回 | 文本按钮 `<` | 使用统一图标按钮 |
| 标题 | `搜索` | 已对齐 |
| 设置 | 文本圆按钮 `设` | 使用设置图标和可访问描述 |
| 精确 | 文本圆按钮 `准` | 使用精确搜索图标，并显示选中态 |
| 筛选 | 文本圆按钮 `滤` | 使用筛选图标，并显示选中态 |
| 输入框 | `TextInput` + 文本 `x` 清空 | 增加搜索图标、自动聚焦、键盘 Search 行为明确化 |
| 操作按钮 | `搜索` / `停止` | 已可用；可与 FAB 停止按钮避免重复 |

### 6.3 建议面板

```
SuggestionPanel
  if bookshelfHints:
    Section "书架匹配"
      BookCover + name + author/latestChapter + "已在书架"
  if history:
    Section "搜索历史" + "清除全部"
      history word + delete
  else:
    Empty "暂无搜索建议"
```

交互：

1. 点击书架命中进入 `BookInfoPage`。
2. 点击历史词提交搜索。
3. 点击单条删除只删除当前词。
4. 点击清除全部弹确认框。

### 6.4 结果布局

列表模式：

```
FloatingSummary
List
  BookListItem
    Cover + shelf badge
    Name + sourceCount badge
    Author + latestChapter
    Introduce
    Kind chips + origin
  Footer
```

按源分组模式：

```
FloatingSummary
List
  SourceGroup
    Header: sourceName + count + 全部/收起
    Collapsed: horizontal grid preview, max 6
    Expanded: vertical full current items
  Footer
```

底部状态：

| 状态 | 展示 |
|------|------|
| 搜索中 | Loading + “正在搜索” |
| 加载更多 | Loading + “正在加载下一页” |
| 有更多 | “继续搜索”按钮 |
| 已结束 | “没有更多结果” |

### 6.5 设置弹层

当前高度 46%，包含：

1. 布局：列表 / 按源分组。
2. 书源类型：按当前 `sourceType` 动态生成 chip。
3. 匹配：精确搜索 / 普通搜索。

差距：

1. Android 书源类型语义为小说、漫画、音频；鸿蒙当前为出版、网络、类型N。
2. 切换类型后 Android 会自动重搜；鸿蒙只改变筛选条件，不自动触发 `doSearch()`。
3. 只持久化布局，类型和匹配没有真正恢复。

### 6.6 搜索范围弹层

当前高度 70%，包含：

1. 标题：搜索范围。
2. 顶部操作：全部、完成。
3. 弹层内过滤输入框：筛选分组或书源。
4. Segment：分组 / 书源。
5. 分组模式：全部书源 + 分组 chip。
6. 书源模式：书源列表，显示书源名、分组、类型。

差距：

1. 范围选择不持久化。
2. 范围变化后不自动重搜。
3. 分组和书源选择是即时修改页面状态，没有 Android 的 draft/apply 事务感。

---

## 7. 书内搜索差距

Android 还有独立的书内搜索框，功能包括：

| 规格 | Android 行为 | 鸿蒙当前状态 |
|------|--------------|--------------|
| 实时搜索章节内容 | 输入变化立即搜索，取消上一次任务 | 已实现 |
| 搜索历史 | 支持历史列表 | 已实现 |
| 历史范围 | 仅本书 / 全部书籍 | 已实现 |
| 替换开关 | 搜索时启用替换规则 | 已实现 |
| 正则开关 | 关键词按正则处理 | 已实现 |
| 停止搜索 | FAB 停止当前搜索 | 已实现 |
| 定位当前章节 | 搜索完成后 FAB 定位当前章节结果 | 已实现 |
| 结果高亮 | 标题/内容高亮关键词 | 部分实现 |
| 点击结果返回阅读页定位 | 传回结果集合和 index | 已实现 |

鸿蒙已新增独立 `SearchContentPage`，阅读页底部菜单提供入口。搜索时优先使用章节缓存，未缓存正文会按当前书源逐章拉取并回写缓存；点击结果通过 `ChapterCache.targetIndex` 返回阅读页定位章节。

---

## 8. 后续实现优先级

### P0：剩余体验缺口

| 项目 | 说明 |
|------|------|
| 滚动位置保存 | 进入详情返回后恢复列表位置 |
| 单源全部结果 Sheet | 按源分组后支持针对单源分页加载更多 |
| 图标化按钮 | 继续替换 `设/准/滤/<` 等文字按钮 |
| 自动聚焦与键盘 | 搜索页进入时可选自动聚焦并弹键盘 |
| Tooltip/无障碍描述 | 为设置、精确、筛选、清空、停止等按钮提供语义 |

### P1：书内搜索后续细化

| 项目 | 说明 |
|------|------|
| 富文本高亮 | 标题/正文摘要内逐词高亮 |
| 结果集合传递 | 回到阅读页后可继续在命中结果间跳转 |
| 搜索进度体验 | 长书籍联网逐章搜索时展示更细的失败/跳过状态 |

---

## 9. 验收清单

主搜索对话框补齐后至少满足：

1. 新进入搜索页时，能展示历史；输入关键词能展示书架建议。
2. 点击历史词能立即搜索；删除单条和清空全部历史可持久化。
3. 搜索过程中结果逐步出现，顶部显示结果数和书源进度。
4. 停止搜索后不会再更新 UI。
5. 设置普通/精确、布局、书源类型后，已有搜索能按规则刷新。
6. 范围选择支持全部、分组、具体书源，退出页面后能恢复。
7. 列表和按源分组模式均可进入书籍详情，并传递合并源缓存。
8. 无结果时能一键放宽筛选重新搜索。
9. 下一页搜索能合并去重，不重复显示同一本书。
10. 从详情返回搜索页后，搜索词、结果和滚动位置保持。
