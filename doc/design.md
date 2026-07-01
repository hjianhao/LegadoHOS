# LegadoHOS — 设计文档（v2.0）

> **目标读者**：AI Agent / LLM / 后续开发者
> **编写原则**：结构化的架构、模块划分、数据流描述，减少歧义，便于 AI 理解和维护
> **更新日期**：2026-07-01（全面审计：新增 RSS/AI/分组/朗读/WebViewFetcher 等模块）

---

## 目录

1. [项目结构](#1-项目结构)
2. [整体架构](#2-整体架构)
3. [数据层](#3-数据层)
4. [模型层](#4-模型层)
5. [引擎层](#5-引擎层)
6. [服务层](#6-服务层)
7. [UI 层](#7-ui-层)
8. [NAPI 桥接层](#8-napi-桥接层)
9. [主题系统](#9-主题系统)
10. [工具层](#10-工具层)
11. [关键数据流](#11-关键数据流)
12. [设计决策记录](#12-设计决策记录)
13. [依赖关系图](#13-依赖关系图)

---

## 1. 项目结构

```
LegadoHOS/
├── AppScope/                          # 应用级资源配置
│   ├── app.json5                      # 应用级配置（bundleName / versionCode 等）
│   └── resources/base/media/          # 应用图标（前景/背景/分层图标）
├── entry/                             # 主 entry module
│   ├── build-profile.json5            # 构建配置
│   ├── oh-package.json5               # 依赖声明
│   ├── src/main/
│   │   ├── module.json5               # module 配置（权限、Ability 声明）
│   │   ├── resources/                 # 资源文件（颜色、字符串、媒体、配置）
│   │   ├── cpp/
│   │   │   ├── CMakeLists.txt         # C++ 编译配置
│   │   │   └── types/libquickjs_bridge/  # NAPI 类型声明
│   │   └── ets/                       # ★ 核心 ArkTS 源码
│   │       ├── Application/           # 应用生命周期
│   │       │   └── MyApplication.ts
│   │       ├── MainAbility/           # UIAbility 入口
│   │       │   └── MainAbility.ts
│   │       ├── model/                 # 数据模型（15 个文件）
│   │       ├── data/                  # 数据层
│   │       │   ├── database/          # 数据库 Dao（14 个表类 / 17 张表）
│   │       │   ├── preferences/       # 偏好设置（SettingsStore / GlobalConfig）
│   │       │   └── repository/        # 仓储（组合 Dao 的高阶操作）
│   │       ├── engine/                # ★ 引擎层（核心逻辑）
│   │       │   ├── source/            # 书源引擎（12 个文件）
│   │       │   ├── search/            # 搜索引擎（降级方案）
│   │       │   ├── book/              # 书籍解析（8 个文件）
│   │       │   ├── audio/             # 音频 / TTS（4 个文件）
│   │       │   ├── cache/             # 缓存
│   │       │   ├── download/          # 下载
│   │       │   ├── web/               # Web 服务 + WebView 取内容
│   │       │   ├── rss/               # RSS 解析引擎（3 个文件）
│   │       │   ├── ai/                # AI 书源生成
│   │       │   └── translation/       # 翻译
│   │       ├── service/               # 后台服务（9 个）
│   │       ├── pages/                 # 页面（42 个 .ets/.ts 文件）
│   │       ├── components/            # 可复用组件
│   │       │   ├── reader/            # 阅读器组件（8 个文件）
│   │       │   ├── ui/                # 通用 UI 组件
│   │       │   └── common/            # 公共组件
│   │       ├── napi/                  # QuickJS NAPI 桥接
│   │       ├── theme/                 # 主题系统
│   │       ├── util/                  # 工具类（16 个文件）
│   │       ├── widget/                # 桌面小部件
│   │       └── workers/               # Worker 线程（JsEvalWorker）
│   └── src/mock/                      # Mock 数据
├── libraries/quickjs/                 # QuickJS C 源码
│   ├── BUILD.gn                       # 编译构建
│   └── src/
│       ├── quickjs.c/.h               # QuickJS 核心引擎
│       ├── napi_bridge.cpp            # ★ NAPI 桥接（ArkTS ↔ C++ ↔ JS）
│       └── ...                        # 其他 QuickJS 源码文件
├── oh-package.json5                   # 项目级依赖
├── hvigor/hvigor-config.json5         # 构建配置
└── build-profile.json5                # 顶层构建配置
```

### 1.1 ETS 源码核心目录说明

```
ets/
├── Application/MyApplication.ts       # 应用入口：初始化数据库、主题
├── MainAbility/MainAbility.ts         # UIAbility：生命周期管理，加载首页
├── model/                             # 纯数据模型（15 个文件，15 个 interface/enum/class）
├── data/
│   ├── database/                      # Dao 层：14 个表类，管理 17 张 SQL 表
│   │   ├── AppDatabase.ts             # 单例数据库管理器（建表 + 迁移）
│   │   ├── BookTable.ts               # 书籍表
│   │   ├── ChapterTable.ts            # 章节表
│   │   ├── BookSourceTable.ts         # 书源表
│   │   ├── BookSourcesCacheTable.ts   # 书源缓存表（NEW）
│   │   ├── BookmarkTable.ts           # 书签表
│   │   ├── ReadRecordTable.ts         # 阅读记录表（含详情子表）
│   │   ├── ReplaceRuleTable.ts        # 替换规则表
│   │   ├── RSSSourceTable.ts          # RSS 源表（含 articles/stars/read_records 3 子表）
│   │   ├── CacheTable.ts              # 缓存表（含 txt_toc_rules 子表）
│   │   ├── SearchResultTable.ts       # 搜索结果表
│   │   ├── BookGroupTable.ts          # 书架分组表（NEW）
│   │   └── SearchKeywordTable.ts      # 搜索关键词表（NEW）
│   ├── preferences/                   # KV 存储封装（@ohos.data.preferences）
│   │   ├── SettingsStore.ts           # 全局设置（AI 端点、WebDAV 配置等）
│   │   └── GlobalConfig.ts            # 书架配置开关
│   └── repository/                    # 仓储层：组合多个 Dao 的复杂操作
│       ├── BookRepository.ts          # 书籍仓储
│       └── BookSourceRepository.ts    # 书源仓储
├── engine/                            # 无状态逻辑层
│   ├── source/                        # 书源引擎（核心复杂度所在）
│   │   ├── SourceExecutor.ts          # ★ 核心协调者（2369 行）
│   │   ├── ScriptEngine.ts            # QuickJS 脚本引擎封装
│   │   ├── ScriptApi.ts               # JS polyfill（1073 行）
│   │   ├── RuleParser.ts              # 规则解析器（JSONPath/CSS/XPath/正则）
│   │   ├── RuleAnalyzer.ts            # 规则编排
│   │   ├── AnalyzeByRegex.ts          # 正则 AllInOne 分析
│   │   ├── ExploreEngine.ts           # 发现页引擎
│   │   ├── SourceSwitcher.ts          # 书源切换器
│   │   └── JsExpressionEvaluator.ts   # JS 表达式独立求值（NEW）
│   ├── search/                        # 搜索（降级方案）
│   │   └── SearchEngine.ts
│   ├── book/                          # 书籍格式解析
│   │   ├── TxtParser.ts
│   │   ├── EpubParser.ts
│   │   ├── MobiParser.ts
│   │   ├── PdfParser.ts               # 元数据提取（渲染未集成）
│   │   ├── ComicReader.ts             # 漫画阅读器模型
│   │   ├── ChapterManager.ts          # 章节管理器（预加载 + 排序）
│   │   ├── ContentReplace.ts          # 内容替换引擎
│   │   └── TextLayout.ts              # 文字排版（分页 + 分行，基于 MeasureText）
│   ├── audio/                         # 音频播放 + TTS
│   │   ├── TTSPlayer.ts               # 文字转语音朗读
│   │   ├── AudioPlayer.ts             # 有声书音频播放
│   │   ├── PlaylistManager.ts         # 播放列表与模式管理
│   │   └── ReadTimer.ts               # 定时关闭
│   ├── cache/                         # 缓存策略
│   │   └── CacheManager.ts
│   ├── download/                      # 下载管理
│   │   └── DownloadManager.ts
│   ├── web/                           # Web 服务
│   │   ├── WebServer.ts               # HTTP 服务器
│   │   └── WebViewFetcher.ts          # WebView 兜底取内容（NEW，414 行）
│   ├── rss/                           # RSS 解析（NEW）
│   │   ├── RssService.ets             # RSS 服务协调（270 行）
│   │   ├── RssParserByRule.ets        # 规则式 RSS 解析（399 行）
│   │   └── RssParserDefault.ts        # 标准 RSS/Atom feed 解析
│   ├── ai/                            # AI 书源生成（NEW）
│   │   └── AiSourceAgent.ts           # 6 步 LLM 分析引擎（382 行）
│   └── translation/                   # 翻译
│       └── TranslationEngine.ts
├── service/                           # 有状态后台服务（9 个）
│   ├── BackupService.ts               # 完整备份/恢复
│   ├── WebDavService.ts               # WebDAV 远程同步
│   ├── DownloadService.ts             # 下载任务管理
│   ├── ReadAloudService.ts            # 后台朗读（RemoteObject）
│   ├── ReadAloudEngine.ets            # 朗读引擎（NEW，352 行）
│   ├── WebService.ts                  # HTTP 服务管理
│   ├── ControllerService.ts           # 全局播放控制
│   ├── BookshelfTransferService.ts    # 书架导入导出传输（NEW，323 行）
│   └── SourceChecker.ts               # 书源校验服务（NEW，275 行）
├── pages/                             # ArkUI 页面组件（42 个文件）
├── components/                        # 可复用 UI 组件
│   ├── reader/                        # 阅读器组件（8 个）
│   │   ├── PageView.ets               # 分页视图（翻页动画）
│   │   ├── StylePanel.ets             # 样式面板
│   │   ├── ReadBottomMenu.ets         # 底部菜单
│   │   ├── ReadAloudPanel.ets         # 朗读面板（511 行）
│   │   ├── TtsControlPanel.ets        # TTS 控制面板
│   │   ├── ClickAction.ets            # 点击动作定义
│   │   ├── ClickActionConfig.ets      # 点击区域配置
│   │   ├── PageTouchHandler.ets       # 触摸事件处理
│   │   └── CacheDialog.ets            # 缓存管理对话框
│   ├── ui/                            # 通用 UI 组件
│   │   └── BookItem.ets
│   ├── BookCover.ets                  # 书籍封面
│   ├── BookInfoSheets.ets             # 书籍详情浮层（含 ChangeSourceSheet）
│   ├── WebViewEngine.ets              # 可复用 WebView 引擎组件
│   └── common/                        # 公共组件
│       └── LoadingView.ets
├── theme/                             # 主题/色彩管理
│   ├── AppTheme.ts                    # 主题管理器（单例）
│   ├── ColorScheme.ts                 # MD3 色彩方案
│   └── ThemeMode.ts                   # 主题模式枚举
├── util/                              # 工具类（16 个文件）
│   ├── HtmlParser.ts                  # ★ HTML 解析器（951 行，自研）
│   ├── HtmlUtil.ts                    # HTML 清理
│   ├── NetUtil.ts                     # 网络请求封装
│   ├── FileUtil.ts                    # 文件操作
│   ├── StrUtil.ts                     # 字符串处理
│   ├── CryptoUtil.ts                  # 加密（MD5/SHA/Base64）
│   ├── ZipReader.ts                   # ZIP 解压
│   ├── BookCoverUtil.ts               # 封面生成
│   ├── ChineseConverter.ts            # 繁简转换（NEW，260 行）
│   ├── ContentCache.ts                # 内容内存缓存（NEW）
│   ├── ContentCleaner.ts              # 内容清理（NEW，248 行）
│   ├── ChapterCache.ts                # 章节缓存助手（NEW）
│   ├── SourceSwitchStore.ts           # 源切换存储（NEW）
│   └── AppContext.ts                  # 应用上下文单例（NEW）
├── napi/                              # NAPI 桥接（ArkTS 侧）
│   └── quickjs_bridge.ts
├── widget/                            # 桌面小部件
│   └── pages/
│       ├── RecentReadWidget.ets
│       └── SearchWidget.ets
└── workers/                           # Worker 线程（NEW）
    └── JsEvalWorker.ts                # 独立线程 JS 执行（139 行）
```

---

## 2. 整体架构

### 2.1 分层架构

```
┌─────────────────────────────────────────────────────────┐
│          UI 层 (pages/ + components/)                    │
│  Bookshelf / Explore / Read / RSS / AI / Settings ...   │
│  reader/PageView, StylePanel, ReadAloudPanel ...        │
├─────────────────────────────────────────────────────────┤
│          服务层 (service/, 9 个服务)                      │
│  Backup / WebDav / Download / ReadAloud / Transfer      │
│  WebService / Controller / SourceChecker                │
├─────────────────────────────────────────────────────────┤
│             引擎层 (engine/, 8 个子包)                     │
│  Source │ Search │ Book │ Audio │ Cache                │
│  Download │ Web │ RSS │ AI │ Translation               │
│  ScriptApi(1073行) / WebViewFetcher(414行)              │
├─────────────────────────────────────────────────────────┤
│          仓储层 (data/repository/)                       │
│        BookRepository / BookSourceRepository            │
├─────────────────────────────────────────────────────────┤
│     数据访问层 (data/database/, 14 个表类 / 17 张表)        │
│  Book / Chapter / Source / Bookmark / ReadRecord / ...  │
├─────────────────────────────────────────────────────────┤
│  ┌──────────┐  ┌──────────┐  ┌──────────────────────┐  │
│  │ 模型层    │  │ NAPI桥接  │  │ 工具层 (16 个文件)     │  │
│  │model/    │  │napi/     │  │ HtmlParser/Net/...  │  │
│  └──────────┘  └──────────┘  └──────────────────────┘  │
├─────────────────────────────────────────────────────────┤
│             QuickJS C++ (libraries/)                     │
│         napi_bridge.cpp + quickjs.c                      │
└─────────────────────────────────────────────────────────┘
```

### 2.2 核心依赖方向

```
UI 层 (pages) ──→ 引擎层 (engine) ──→ 数据访问层 (database)
     │                   │                    │
     ├──→ 服务层          ├──→ 模型层           ├──→ 模型层
     ├──→ 组件层          ├──→ NAPI 桥接        ├──→ 工具层
     ├──→ 主题层          ├──→ 工具层
     └──→ 模型层          └──→ 数据访问层

※ 依赖方向单向，下层不依赖上层
※ 引擎层通过 import 直接调用 Dao，不经过 Repository
```

---

## 3. 数据层

### 3.1 数据库整体设计

- **技术方案**：`@ohos.data.relationalStore`（RDB，基于 SQLite）
- **数据库名**：`legado_hos.db`
- **版本**：1

#### 3.1.1 表结构总览（17 张表）

| 表名 | 对应模型 | 用途 | 关键字段 |
|------|---------|------|---------|
| `books` | Book | 书籍信息 | name, author, origin, isShelf, durChapterIndex, groupId |
| `chapters` | BookChapter | 章节列表 | bookId, title, url, index |
| `book_sources` | BookSource | 书源规则 | sourceName, sourceUrl, ruleSearchUrl, ... (40+ 字段) |
| `book_sources_cache` | — | 书源搜索结果缓存 | sourceUrl, bookName, author, data |
| `bookmarks` | Bookmark | 书签 | bookId, chapterIndex, position, content |
| `read_records` | ReadRecord | 阅读记录 | bookId, lastReadTime |
| `read_record_details` | ReadRecordDetail | 阅读详情 | recordId, chapterIndex, progress |
| `replace_rules` | ReplaceRule | 替换规则 | name, pattern, replacement, scope |
| `rss_sources` | RSSSource | RSS 源 | sourceName, url, sourceGroup, ruleArticles |
| `rss_articles` | RSSArticle | RSS 文章 | sourceId, title, link, pubDate, content, isStar |
| `rss_stars` | RSSArticle | RSS 收藏 | sourceId, guid, title, link |
| `rss_read_records` | RSSReadRecord | RSS 阅读记录 | sourceId, guid, readTime |
| `caches` | CacheEntry | 缓存 | key, data, expireTime |
| `txt_toc_rules` | TxtTocRule | TXT 目录规则 | pattern, level |
| `search_results` | SearchResult | 搜索结果缓存 | bookName, author, sourceUrl, data |
| `book_groups` | BookGroupItem | 书架分组 | groupName, sortOrder |
| `search_keywords` | SearchKeyword | 搜索历史 | keyword, searchTime |

#### 3.1.2 AppDatabase（`data/database/AppDatabase.ts`）

```typescript
class AppDatabase {
  // 单例模式
  static getInstance(): AppDatabase

  // 初始化（在 Application.onCreate 中调用）
  async init(context: Context): Promise<void>

  // 页面等待数据库就绪（在 aboutToAppear 中 await）
  async waitForInit(): Promise<void>

  // 对外暴露 RdbStore 实例
  get rdbStore(): relationalStore.RdbStore
}
```

**初始化流程**：
1. `getRdbStore(context, config)` — 打开/创建数据库
2. 按序执行 17 条 `CREATE TABLE IF NOT EXISTS` SQL
3. 执行 ALTER TABLE 迁移（try-catch 幂等）

#### 3.1.3 Dao 层约定

每个 Table 类遵循以下模式：

```typescript
class BookTable {
  constructor(private db: relationalStore.RdbStore) {}

  async insert(book: Book): Promise<number>
  async getAllShelfBooks(): Promise<Book[]>
  async getBookByName(name: string, author: string): Promise<Book | null>
  async update(book: Book): Promise<void>
  async delete(id: number): Promise<void>
}
```

---

## 4. 模型层

### 4.1 核心模型（15 个文件）

```
model/
├── Book.ts           # 书籍（BookType 枚举、BookGroup 枚举、Book interface）
├── BookChapter.ts    # 章节（bookId, title, url, index）
├── Chapter.ts        # 章节内容（chapterId, content）
├── BookSource.ts     # ★ 书源（40+ 规则字段 + BookSourceScript 接口）
├── BookGroup.ts      # ★ 书架分组（系统分组枚举 + BookGroupItem interface）
├── SearchResult.ts   # 搜索结果（含去重合并逻辑）
├── SearchKeyword.ts  # 搜索历史关键词
├── Bookmark.ts       # 书签
├── ReadConfig.ts     # 阅读配置（PageMode, TextSizeUnit）
├── ReadRecord.ts     # 阅读记录
├── ReplaceRule.ts    # 替换规则（ReplaceScope 枚举）
├── RSSSource.ts      # RSS 源和文章
├── RSSImport.ts      # RSS 导入数据模型（Legado 备份格式）
├── CacheEntry.ts     # 缓存条目
└── BookSource.ts     # 书源脚本接口（BookSourceScript）
```

### 4.2 BookGroup — 书架分组模型（新增）

```typescript
enum BookGroup {
  ALL = -1,           // 全部分组
  UNGROUPED = 0,      // 未分组
  LOCAL = -2,         // 本地书籍
  CUSTOM = 1000       // 自定义分组起始值
}

interface BookGroupItem {
  id: number;
  groupName: string;
  sortOrder: number;
}
```

### 4.3 BookSource 核心字段（40+ 规则字段）

书源模型是 LegadoHOS 的核心复杂度所在。每个书源包含完整的抓取规则链：

```
┌─ 搜索规则 ─────────────────────────────┐
│ ruleSearchUrl, ruleSearchList,          │
│ ruleSearchName, ruleSearchAuthor,       │
│ ruleSearchCover, ruleSearchNoteUrl, ... │
├─ 详情规则 ─────────────────────────────┤
│ ruleBookInfoInit, ruleBookInfoName,     │
│ ruleBookInfoAuthor, ruleBookInfoCover,  │
│ ruleBookInfoIntroduce, ...              │
├─ 目录规则 ─────────────────────────────┤
│ ruleTocUrl, ruleToc, ruleTocTitle,      │
│ ruleTocUrlItem                          │
├─ 正文规则 ─────────────────────────────┤
│ ruleBookContentUrl, ruleBookContent,    │
│ ruleBookContentNext                     │
├─ 发现规则 ─────────────────────────────┤
│ ruleExplores                            │
├─ JS 脚本 ──────────────────────────────┤
│ script (完整 JS 书源脚本，可替代规则式)  │
│ jsLib (JS 库 URL，复用函数库)            │
└─────────────────────────────────────────┘
```

**规则字段类型兼容性**（`toRuleString()`）：
- 字符串 → 直接存储
- JSON 对象 → `JSON.stringify` 后存储
- JSON 数组 → `JSON.stringify` 后存储

---

## 5. 引擎层

### 5.1 书源引擎（`engine/source/`）

这是整个应用最核心最复杂的模块（9 个文件）。

```
engine/source/
├── SourceExecutor.ts       # ★ 书源执行器（核心协调者，2369 行）
├── ScriptEngine.ts         # QuickJS 脚本引擎封装
├── ScriptApi.ts            # JS polyfill + 规则执行器脚本生成（1073 行）
├── RuleParser.ts           # 规则解析器（JSONPath / CSS / XPath / 正则）
├── RuleAnalyzer.ts         # 规则编排
├── AnalyzeByRegex.ts       # 正则 AllInOne 分析
├── ExploreEngine.ts        # 发现页引擎
├── SourceSwitcher.ts       # 书源切换器
└── JsExpressionEvaluator.ts # JS 表达式独立求值（NEW）
```

#### 5.1.1 SourceExecutor — 核心协调者

```
SourceExecutor 职责链：
┌──────────────────────────────────────────────────────────┐
│  1. search(keyword, sources, onResult?)                   │
│     → 并发池逐个搜索，每完一个触发回调                      │
│     → 返回合并结果                                        │
├──────────────────────────────────────────────────────────┤
│  2. getToc(source, tocUrl)                                │
│     → 解析目录页 URL                                      │
│     → 规则解析 / 兜底 HTML 提取                            │
│     → 返回章节列表                                        │
├──────────────────────────────────────────────────────────┤
│  3. getContent(source, contentUrl, bookUrl?)              │
│     → 解析正文页 URL                                      │
│     → JSON / 规则 / 兜底 stripHtml                        │
│     → 返回正文文本                                        │
├──────────────────────────────────────────────────────────┤
│  4. getBookInfo(source, bookUrl)                          │
│     → 解析书籍详情页                                      │
│     → 返回 BookInfo                                       │
└──────────────────────────────────────────────────────────┘

搜索并发模型：
┌─────┐  ┌─────┐  ┌─────┐  ┌─────┐
│ 源1 │  │ 源2 │  │ 源3 │  │ 源4 │  ...
└──┬──┘  └──┬──┘  └──┬──┘  └──┬──┘
   │        │        │        │
   ▼        ▼        ▼        ▼
┌─────────────────────────────────────┐
│       结果合并池 (mergeResults)      │
│     每完成一个源→merge+回调          │
└─────────────────────────────────────┘
```

### 5.2 书籍解析引擎（`engine/book/`）

```
engine/book/
├── TxtParser.ts           # TXT 解析（章节分割 + 编码检测）
├── EpubParser.ts          # EPUB 解析（OPF + NCX）
├── MobiParser.ts          # MOBI 解析（PDB 格式）
├── PdfParser.ts           # PDF 解析（元数据提取，渲染待集成）
├── ComicReader.ts         # 漫画阅读器（页面模式 + 缩放模式）
├── ChapterManager.ts      # 章节管理器（预加载 + 排序）
├── ContentReplace.ts      # 内容替换引擎（正则替换规则，作用域 + 排序）
└── TextLayout.ts          # 文字排版（分页 + 分行，基于 MeasureText API）
```

### 5.3 音频引擎（`engine/audio/`）

```
engine/audio/
├── TTSPlayer.ts            # 文字转语音朗读
├── AudioPlayer.ts          # 有声书音频播放
├── PlaylistManager.ts      # 播放列表与模式管理
└── ReadTimer.ts            # 定时关闭（15/30/45/60/90 分钟）
```

### 5.4 RSS 引擎（`engine/rss/`）— 新增

```
engine/rss/
├── RssService.ets          # RSS 服务协调（270 行）
│     └── 统一入口：fetchArticles() / fetchContent()
├── RssParserByRule.ets     # 规则式 RSS 解析（399 行）
│     └── 基于 Legado 规则的 RSS 文章提取
└── RssParserDefault.ts     # 标准 RSS/Atom feed 解析
      └── XML 解析 → RSS 2.0 / Atom → RSSArticle[]
```

**RSS 解析流程**：
```
sourceUrl → HTTP GET
  ├── ruleArticles 为空 → RssParserDefault (标准 RSS/Atom)
  └── ruleArticles 不为空 → RssParserByRule (规则式解析)
       ├── ruleTitle / ruleLink / ruleDescription
       ├── ruleContent (可选)
       └── ruleNextPage (可选)
```

### 5.5 AI 引擎（`engine/ai/`）— 新增

```
engine/ai/
└── AiSourceAgent.ts        # AI 书源生成引擎（382 行）

分析流程（6 步）：
  1. HOMEPAGE  → 获取首页 HTML，分析页面结构
  2. SEARCH    → 发送搜索请求，分析搜索结果页
  3. BOOK_INFO → 访问书籍详情页，分析信息提取规则
  4. TOC       → 分析目录页规则
  5. CONTENT   → 分析正文页规则
  6. COMPILE   → 汇总生成完整书源 JSON

依赖：
  - SettingsStore (AI 配置)
  - NetUtil (HTTP 请求)
  - HtmlUtil (HTML 清理)
  - WebViewFetcher (Cloudflare 兜底)
```

### 5.6 Web 引擎（`engine/web/`）

```
engine/web/
├── WebServer.ts           # HTTP 服务器（阅读内容远程访问）
└── WebViewFetcher.ts      # WebView 取内容（NEW，414 行）
      └── Cloudflare 保护站点 WebView 兜底，支持 cookie 注入
```

### 5.7 缓存引擎（`engine/cache/CacheManager.ts`）

```
CacheManager:
  get(key): CacheEntry | null      → 读取缓存（检查过期）
  set(key, data, ttl): void        → 写入缓存
  clear(): void                    → 清空所有缓存
  cleanExpired(): void             → 清理过期条目

缓存策略：
  - 章节内容缓存（默认 24h TTL）
  - 搜索结果缓存
  - 支持 TXT 目录规则缓存
```

### 5.8 翻译引擎（`engine/translation/TranslationEngine.ts`）

```
TranslationEngine:
  translate(text, from, to, provider?): Promise<string>
  detectLanguage(text): string

支持的翻译提供商（TranslationProvider）：
  GOOGLE, DEEPL, BAIDU, YOUDAO, MICROSOFT
```

---

## 6. 服务层

### 6.1 服务总览（9 个服务）

| 服务 | 文件 | 类型 | 说明 |
|------|------|------|------|
| BackupService | service/BackupService.ts | 工具类 | 完整备份/恢复（书架+书源+规则+RSS+设置） |
| WebDavService | service/WebDavService.ts | 工具类 | WebDAV 远程同步 |
| DownloadService | service/DownloadService.ts | 后台 | 下载任务管理（前台+后台） |
| ReadAloudService | service/ReadAloudService.ts | 后台+Remote | TTS 朗读服务（跨 Ability 通信） |
| ReadAloudEngine | service/ReadAloudEngine.ets | 引擎 | 朗读引擎（状态机：播放/暂停/停止/完成，352 行） |
| WebService | service/WebService.ts | 后台 | HTTP 服务管理 |
| ControllerService | service/ControllerService.ts | 后台 | 全局播放控制、通知 |
| BookshelfTransferService | service/BookshelfTransferService.ts | 工具类 | 书架导入导出（自动匹配书源、下载目录，323 行） |
| SourceChecker | service/SourceChecker.ts | 工具类 | 书源校验（搜索/发现/详情/目录/正文多步检查，275 行） |

### 6.2 ReadAloudEngine — 朗读引擎（新增）

```
class ReadAloudEngine {
  state: AloudState = 'idle' | 'playing' | 'paused' | 'stopped' | 'completed'

  config(options): void          → 设置语速、音色、音量
  start(text, startPos?): void   → 开始朗读
  pause(): void                  → 暂停
  resume(): void                 → 继续
  stop(): void                   → 停止
  setSpeed(speed): void          → 动态调整语速
  getCurrentPosition(): number   → 获取当前朗读位置
}
```

### 6.3 BookshelfTransferService — 书架传输服务（新增）

```
exportBookshelf(books?): string           → 导出书架为 JSON
importBookshelf(json): TransferResult     → 导入书架（批量）
  ├── 自动检测书籍 URL 对应的书源
  ├── 下载目录信息
  ├── upsert 书籍到数据库
  └── 返回 success/skipped/failed 统计
```

### 6.4 SourceChecker — 书源校验服务（新增）

```
check(source, config): CheckResult    → 执行多步校验
  ├── checkSearch (搜索关键词验证)
  ├── checkDiscovery (发现页验证)
  ├── checkInfo (详情页验证)
  ├── checkCategory (目录验证)
  └── checkContent (正文验证)
```

---

## 7. UI 层

### 7.1 页面导航结构

```
MainPage (Tabs)
├── Tab 0: BookshelfPage               (书架)
│   ├── 分组标签切换（全部/未分组/本地/自定义）
│   ├── 书架配置 (BookshelfConfigDialog)
│   ├── 分组管理 (BookGroupManageDialog)
│   ├── URL添加 (AddBookUrlDialog)
│   ├── 书架导入 (BookshelfImportDialog)
│   ├── 书架导出 (BookshelfExportDialog)
│   ├── 书架管理 (BookshelfManagePage)
│   │   └── 批量选择 / 分组筛选 / 导出导入 / 传输
│   └── click → ReadPage               (阅读)
├── Tab 1: ExplorePage                 (发现/搜索)
│   ├── ExploreBookPage                (发现书单)
│   ├── SearchPage                     (搜索历史)
│   ├── WebViewFetchDialog             (WebView 兜底)
│   └── click → BookInfoPage           (书籍详情)
│       ├── ChangeSourceSheet          (切换书源)
│       ├── "加入书架" → 数据库更新
│       └── "开始阅读" → ReadPage      (阅读)
├── Tab 2: RssMainPage                 (RSS 主页)
│   ├── RssArticlesPage                (文章列表)
│   │   └── RssReadPage                (文章阅读)
│   ├── RssFavoritesPage               (收藏文章)
│   ├── RssSortPage                    (排序规则)
│   ├── RssSourceManagePage            (RSS 源管理)
│   │   ├── RssSourceEditPage          (编辑 RSS 源)
│   │   └── RssImportDialog            (导入 RSS 源)
│   └── RSSPage                        (旧版，保留)
└── Tab 3: MyPage                      (我的)
    ├── BookSourcePage                 (书源管理)
    │   ├── ImportSourceDialog         (导入书源)
    │   ├── BookSourceEditPage         (编辑书源)
    │   └── RuleSubPage                (规则订阅)
    ├── SettingsPage                   (设置)
    ├── AiConfigPage                   (AI 配置)
    ├── AiSourceGeneratePage           (AI 生成书源)
    ├── BookmarkPage                   (书签)
    ├── AboutPage                      (关于)
    ├── WebServicePage                 (Web 服务)
    └── ReadRecordPage                 (阅读记录)

独立页面（通过 router.pushUrl 跳转）：
  ReadPage / BookInfoPage / BookSourcePage / SettingsPage
  ComicReadPage / SearchPage / ErrorPage / SimplePage
  WebFetchPage / WebViewFetchDialog / ChangeSourcePage
  ChapterListPage / ChangeSourcePage
```

### 7.2 页面文件总览（42 个）

| 分类 | 文件 | 行数 | 说明 |
|------|------|------|------|
| 书架 | BookshelfPage.ets | 789 | 书架主页（分组标签/配置/导入导出） |
| 书架 | BookshelfManagePage.ets | 320 | 批量管理（选择/筛选/导出导入/传输） |
| 书架 | BookshelfConfigDialog.ets | — | 书架显示配置 |
| 书架 | BookshelfExportDialog.ets | — | 导出书架 JSON |
| 书架 | BookshelfImportDialog.ets | — | 导入书架 JSON |
| 书架 | AddBookUrlDialog.ets | — | URL 添加书籍 |
| 书架 | BookGroupManageDialog.ets | — | 分组管理 |
| 书架 | GroupManageDialog.ets | — | 移动书籍到分组 |
| 发现 | ExplorePage.ets | 526 | 搜索 + 发现 |
| 发现 | ExploreBookPage.ets | — | 发现书单列表 |
| 发现 | SearchPage.ets | — | 搜索历史入口 |
| 阅读 | ReadPage.ets | 849 | 阅读主页面 |
| 阅读 | ComicReadPage.ets | 17 | 漫画阅读（占位） |
| 阅读 | SimplePage.ets | — | 简版阅读视图 |
| 阅读 | BookmarkPage.ets | — | 书签管理 |
| 阅读 | ChapterListPage.ets | — | 章节目录 |
| 阅读 | ChangeSourcePage.ets | — | 换源搜索 |
| 阅读 | ReadRecordPage.ets | — | 阅读记录 |
| 详情 | BookInfoPage.ets | — | 书籍详情 |
| RSS | RssMainPage.ets | 122 | RSS 订阅主页 |
| RSS | RssArticlesPage.ets | 148 | RSS 文章列表 |
| RSS | RssReadPage.ets | 309 | RSS 文章阅读 |
| RSS | RssFavoritesPage.ets | 285 | RSS 收藏 |
| RSS | RssSortPage.ets | 442 | RSS 排序规则 |
| RSS | RssSourceManagePage.ets | 228 | RSS 源管理 |
| RSS | RssSourceEditPage.ets | 229 | RSS 源编辑 |
| RSS | RssImportDialog.ets | 236 | RSS 源导入 |
| RSS | RSSPage.ets | — | 旧版 RSS（保留） |
| 书源 | BookSourcePage.ets | — | 书源列表 |
| 书源 | BookSourceEditPage.ets | — | 书源编辑 |
| 书源 | ImportSourceDialog.ets | — | 导入书源 |
| 书源 | RuleSubPage.ets | — | 规则订阅 |
| AI | AiConfigPage.ets | — | AI 配置 |
| AI | AiSourceGeneratePage.ets | 221 | AI 生成书源 |
| 设置 | SettingsPage.ets | — | 设置 |
| 设置 | AboutPage.ets | — | 关于 |
| Web | WebServicePage.ets | — | Web 服务 |
| Web | WebFetchPage.ets | — | WebView 取内容 |
| Web | WebViewFetchDialog.ets | — | WebView 兜底对话框 |
| 通用 | MainPage.ets | — | 4 Tab 主页 |
| 通用 | MyPage.ets | — | "我的"页面 |
| 通用 | ErrorPage.ets | — | 错误页面 |
| Worker | JsEvalWorker.ts | — | Worker 线程 JS 执行 |

### 7.3 阅读器组件（`components/reader/`）

| 组件 | 文件 | 行数 | 用途 |
|------|------|------|------|
| PageView | PageView.ets | 252 | 分页视图 + 翻页动画（滑动/覆盖/无） |
| StylePanel | StylePanel.ets | 236 | 阅读样式配置面板 |
| ReadBottomMenu | ReadBottomMenu.ets | 55 | 底部菜单栏 |
| ReadAloudPanel | ReadAloudPanel.ets | 511 | 朗读控制面板 |
| TtsControlPanel | TtsControlPanel.ets | 102 | TTS 语速/音色配置浮层 |
| ClickAction | ClickAction.ts | 81 | 点击动作定义（菜单/翻页前/翻页后/无） |
| ClickActionConfig | ClickActionConfig.ets | 182 | 点击区域配置面板 |
| PageTouchHandler | PageTouchHandler.ets | 81 | 触摸事件处理（单击/长按/滑动方向） |
| CacheDialog | CacheDialog.ets | 322 | 章节缓存管理对话框 |

### 7.4 Widget

| Widget | 文件 | 说明 |
|--------|------|------|
| RecentReadWidget | widget/pages/RecentReadWidget.ets | 桌面显示最近阅读书籍 |
| SearchWidget | widget/pages/SearchWidget.ets | 桌面快捷搜索入口 |

---

## 8. NAPI 桥接层

### 8.1 架构

```
┌───────── ArkTS 侧 ─────────┐
│ quickjs_bridge.ts          │
│   import('libquickjs_bridge.so') → NAPI 模块
│   requireNapi('quickjs_bridge')   → 兼容方式
│   Mock (createMockBridge)         → 降级方案
└──────────┬──────────────────┘
           │ NAPI 调用
┌──────────▼────── C++ 侧 ──┐
│ napi_bridge.cpp           │
│   napi_createEngine()     │ → quickjs_new_rt() / quickjs_new_context()
│   napi_destroyEngine()    │ → quickjs_free_context() / quickjs_free_rt()
│   napi_executeScript()    │ → quickjs_eval()
│   napi_callFunction()     │ → quickjs_call()
│   napi_onHttpResponse()   │ → 注入 JS Promise resolve
│   napi_registerHttpHandler│ → 设置 ArkTS 回调
└──────────┬──────────────────┘
           │ QuickJS API
┌──────────▼────────────────┐
│ quickjs.c / quickjs.h     │
│ 轻量 JS 引擎              │
└───────────────────────────┘
```

### 8.2 加载优先级

```
1. import('libquickjs_bridge.so')     → HarmonyOS NEXT (API 12+) 推荐方式
2. requireNapi('quickjs_bridge')      → 兼容方式（同步加载）
3. createMockBridge()                  → 无原生模块时降级
```

---

## 9. 主题系统

### 9.1 架构

```
theme/
├── AppTheme.ts        # 主题管理器（单例，亮/暗切换，持久化）
├── ColorScheme.ts     # MD3 色彩方案（光源/暗源色板，A11Y）
└── ThemeMode.ts       # 主题类型枚举 + 配置接口
```

---

## 10. 工具层（16 个文件）

| 工具 | 文件 | 行数 | 核心能力 |
|------|------|------|---------|
| HtmlParser | util/HtmlParser.ts | 951 | 自研 HTML/CSS 解析器，支持 Default 规则、位置索引、排除索引、属性选择器、CSS 伪类 |
| HtmlUtil | util/HtmlUtil.ts | — | HTML 标签剥离，实体解码，纯文本提取 |
| NetUtil | util/NetUtil.ts | — | HTTP GET/POST/PUT，UA/编码检测，超时控制 |
| FileUtil | util/FileUtil.ts | — | 文件读写，目录操作 |
| StrUtil | util/StrUtil.ts | — | 字符串相似度（Levenshtein/Cosine） |
| CryptoUtil | util/CryptoUtil.ts | — | MD5/SHA1/SHA256/Base64 |
| ZipReader | util/ZipReader.ts | — | Zip 解压（store/deflate），流式读取 |
| BookCoverUtil | util/BookCoverUtil.ts | — | 文字封面 Canvas 生成，颜色映射 |
| ChineseConverter | util/ChineseConverter.ts | 260 | 简繁双向转换（OpenCC 词表） |
| ContentCache | util/ContentCache.ts | 95 | 章节内容内存缓存 |
| ContentCleaner | util/ContentCleaner.ts | 248 | 广告/脚本/空行清理 |
| ChapterCache | util/ChapterCache.ts | 17 | 章节内容缓存助手 |
| SourceSwitchStore | util/SourceSwitchStore.ts | 13 | 换源结果持久化 |
| AppContext | util/AppContext.ts | 17 | 全局 Context 单例 |

---

## 11. 关键数据流

### 11.1 搜索数据流

```
用户输入关键词 → click "搜索"
  │
  ▼
ExplorePage.doSearch()
  │ 加载书源列表
  │ filter(ruleSearchUrl !== '')
  ▼
globalSourceExecutor.search(keyword, sources, onResult)
  │
  ├─ 初始化并发池 (workers)
  │    │
  │    ▼ (每个源执行)
  │  searchSingle(keyword, source)
  │    │ buildUrl(ruleSearchUrl, keyword, page, baseUrl)
  │    │ NetUtil.httpGet(url, headers)
  │    │
  │    ├─ JSON.parse 成功 → parseJsonResults()
  │    │
  │    ├─ ruleSearchList 存在
  │    │   └─ RuleParser.parse(html, listRule)
  │    │      └─ items.map → SearchResult[]
  │    │
  │    └─ 兜底 → extractBookNamesFromHtml()
  │    │
  │    └─ 合并 → mergeSearchResults(allResults)
  │         └─ onResult(merged) → 回调 UI
  │
  ▼ (全部完成)
mergeSearchResults(allResults) → 最终合并结果
  │
  ├─ 结果 > 0 → 展示到 List
  └─ 结果 = 0 → searchBooks() 降级搜索
       └─ 仍然无结果 + lastBlockedUrl → 提示 WebView 兜底
```

### 11.2 阅读数据流

```
点击书籍 → ReadPage.aboutToAppear()
  │
  ▼
ReadPage.loadContent()
  │
  ├─ 查找书源 (BookSourceTable.getSourceByUrl)
  │
  ├─ 有书源 → SourceExecutor.getToc(source, bookUrl)
  │    │
  │    ├─ ruleTocUrl 存在 → resolveUrl() 解析目录页 URL
  │    ├─ NetUtil.httpGet(url)
  │    ├─ ruleToc 存在 → RuleParser.parse() 解析目录列表
  │    ├─ 兜底 → extractTocFromHtml() (多层模式匹配)
  │    │
  │    ├─ 检测反转 → isReversedOrder() → reverse()
  │    ├─ 定位第一章 → isFirstChapter()
  │    │
  │    └─ SourceExecutor.getContent(source, chapterUrl, bookUrl)
  │         │
  │         ├─ ruleBookContentUrl → resolveUrl() 解析正文页 URL
  │         ├─ NetUtil.httpGet(url)
  │         ├─ JSON 解析 → 返回 content/data
  │         ├─ ruleBookContent → RuleParser.parse()
  │         └─ 兜底 → HtmlUtil.stripHtml()
  │
  ├─ TextLayout.layout(content, config) → 分页排版
  ├─ PageView 渲染分页内容
  ├─ ChineseConverter 繁简转换（可选）
  └─ ContentCleaner 内容清理（可选）
  │
  └─ 无书源 → NetUtil.httpGet 直连 → stripHtml
```

### 11.3 RSS 解析数据流

```
RSS 源 URL → RssService.fetchArticles(source)
  │
  ├─ ruleArticles 为空 → RssParserDefault.parse(xml)
  │    └─ 标准 RSS 2.0 / Atom → RSSArticle[]
  │
  └─ ruleArticles 不为空 → RssParserByRule.parse(html, rules)
       ├─ ruleArticles → 文章列表解析
       ├─ ruleTitle / ruleLink / rulePubDate
       ├─ ruleDescription / ruleContent
       └─ ruleNextPage → 翻页加载更多
```

### 11.4 AI 书源生成数据流

```
用户输入: 搜索关键词 + 目标网站 URL
  │
  ▼
AiSourceAgent.run(homepageUrl, keyword)
  │
  ├─ Step 1: HOMEPAGE → 获取首页 HTML
  │    └─ Cloudflare? → WebViewFetcher.fetch(url)
  │
  ├─ Step 2: SEARCH → 发送搜索请求 → 分析结果页 DOM
  │
  ├─ Step 3: BOOK_INFO → 访问详情页 → 提取书名/作者/封面
  │
  ├─ Step 4: TOC → 分析目录页 → 提取章节列表规则
  │
  ├─ Step 5: CONTENT → 分析正文页 → 提取内容规则
  │
  └─ Step 6: COMPILE → 汇总生成书源 JSON
       └─ 输出完整 BookSource 规则
```

### 11.5 书架导入传输数据流

```
BookshelfImportDialog → 选择 JSON 文件
  │
  ▼
BookshelfTransferService.importBookshelf(json)
  │
  ├─ 遍历每本书
  │   ├─ 检测书源 URL → BookSourceTable 查找匹配源
  │   ├─ 有匹配源 → SourceExecutor.getToc() 下载目录
  │   ├─ 无匹配源 → 作为无源书记录
  │   └─ BookTable.upsert() → 插入或更新
  │
  └─ 返回 { success, skipped, failed, messages }
```

---

## 12. 设计决策记录

### D-001: HTTP 请求委托（避免 NAPI 死锁）

**问题**：QuickJS NAPI 桥接 `http.get()` 可能导致死锁。
**决策**：所有 HTTP 请求在 ArkTS 侧完成（`NetUtil`），JS 侧通过 `registerHttpHandler` / `onHttpResponse` 异步获取结果。
**影响**：增加一层回调，但避免了死锁问题，且获得更好的超时控制。

### D-002: 并发搜索 + 增量回调

**问题**：多书源搜索如果等全部完成才展示，延迟过长。
**决策**：固定并发池（默认 16），每完成一个源就合并结果并通过 `onResult` 回调通知 UI（ExplorePage 用 `setInterval` 轮询更新）。
**影响**：用户体验提升（实时看到结果累积），但回调频率需要平衡（250ms 轮询间隔）。

### D-003: 不通过 QuickJS 做规则解析

**问题**：大数据量 HTML 传参给 QuickJS 会触发 NAPI 调用溢出。
**决策**：所有规则解析（CSS/XPath/JSONPath/正则）在 ArkTS 侧通过 `RuleParser` 纯文本解析完成。QuickJS 仅用于执行 JS 书源脚本。
**影响**：减少 NAPI 通信量，提高解析性能，但 RuleParser 的 CSS/XPath 实现是简化的。

### D-004: 17 张核心表（扩展版）

**问题**：原 Android Legado 有 28 张表，部分表用途重叠。初始设计精简为 12 张。
**决策**：随着功能增加，扩展至 17 张表（新增 book_groups、book_sources_cache、search_keywords、rss_stars、rss_read_records）。
**影响**：数据库体积略增，但保留了必要的功能完整性（分组、搜索历史、RSS 收藏）。

### D-005: 双模式书源加载 + AI 生成

**问题**：书源有规则式 JSON + JS 脚本式两种格式，手动编写门槛高。
**决策**：RuleParser 解析规则式，ScriptEngine 执行 JS 脚本式，SourceExecutor 统一入口。新增 AiSourceAgent（LLM 驱动 6 步分析）自动生成书源。
**影响**：兼容现有全部 Legado 书源，降低新书源创建门槛。

### D-006: 章节反转自动检测

**问题**：部分小说网站最新章在前，直接显示会导致阅读顺序错误。
**决策**：在 ReadPage 加载目录后自动检测反转（4 种条件），检测到则反转列表。
**影响**：用户无需手动调整，但检测算法可能对非标准网站误判。

### D-007: 引擎降级策略

**问题**：QuickJS NAPI 模块可能因平台版本或编译问题不可用。
**决策**：NAPI 桥接层设计为可降级（Mock 模式），当原生模块不可用时，所有解析走 RuleParser（纯 ArkTS）。JS 书源脚本无法执行，但规则式书源可正常使用。
**影响**：增强应用鲁棒性，但降级后失去 JS 脚本能力。

### D-008: 自研 HtmlParser 替代 Jsoup

**问题**：HarmonyOS 没有 Jsoup 等成熟 HTML 解析库。
**决策**：自研 HtmlParser（951 行），完整实现 Legado Default 规则语法（tag/class/id/text/children、位置索引、排除索引、@分隔符后代关系、属性提取、## 正则链替换），支持 CSS 选择器（属性选择器、伪类 :contains/:not/:has/:nth-child/:nth-of-type）。
**影响**：无需第三方依赖，支持所有 Legado 规则语法，且扩展了 Android 版没有的能力（:has()、位置索引等）。

### D-009: WebView 兜底策略

**问题**：部分网站（Cloudflare、JS 渲染站点）无法通过纯 HTTP 请求获取内容。
**决策**：WebViewFetcher（414 行）提供 WebView 兜底，支持 cookie 注入、JS 执行后内容提取。AI 生成和手动取内容均使用此策略。
**影响**：解决了 Cloudflare 保护站点的内容获取问题，但 WebView 初始化有性能开销。

### D-010: RSS 双模式解析

**问题**：Legado RSS 源有标准 RSS 和规则式两种格式。
**决策**：RssService 根据 ruleArticles 字段自动选择 RssParserDefault（标准 XML 解析）或 RssParserByRule（基于 Legado 规则提取）。
**影响**：完整兼容 Legado RSS 源生态。

---

## 13. 依赖关系图

### 13.1 模块间 import 依赖

```
                          ┌─────────────────────┐
                          │    UIAbility         │
                          │  (MainAbility.ts)    │
                          └──────────┬──────────┘
                                     │ onCreate
                          ┌──────────▼──────────┐
                          │   AppDatabase        │
                          │   AppTheme           │
                          └──────────┬──────────┘
                                     │ loadContent
            ┌────────────────────────┼────────────────────────────┐
            │                        │                            │
   ┌────────▼────────┐    ┌──────────▼──────────┐  ┌─────────────▼─────────┐
   │    Pages        │    │  SourceExecutor     │  │    Services           │
   │  (42 个页面)     │    │  (2369 行)          │  │  (9 个服务)            │
   └────────┬────────┘    └──────────┬──────────┘  └─────────────┬─────────┘
            │                        │                            │
            ├──→ Model               ├──→ ScriptEngine            ├──→ Database
            ├──→ Theme               │    └──→ quickjs_bridge     ├──→ Model
            ├──→ Util                ├──→ RuleParser               ├──→ Engine
            ├──→ Database            ├──→ RuleAnalyzer             └──→ Util
            ├──→ Engine              ├──→ JsExpressionEvaluator
            │   ├──→ source/         ├──→ NetUtil
            │   ├──→ rss/            ├──→ HtmlParser
            │   ├──→ ai/             ├──→ Model
            │   └──→ web/            └──→ HtmlUtil
            └──→ Components
                ├──→ reader/ (9 个)
                ├──→ ui/
                └──→ common/
```

### 13.2 关键单例

```
┌─────────────────────────────────────────────────────────┐
│  全局单例                                                │
│                                                         │
│  AppDatabase.getInstance()       → 数据库管理器           │
│  AppTheme.getInstance()          → 主题管理器             │
│  globalSourceExecutor            → 书源执行器             │
│  globalScriptEngine              → QuickJS 脚本引擎      │
│  SettingsStore.getInstance()     → 设置存储              │
│  AppContext.getInstance()        → 应用上下文（NEW）      │
│  ContentCache.getInstance()      → 内容缓存（NEW）        │
└─────────────────────────────────────────────────────────┘
```
