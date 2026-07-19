# LegadoHOS — 设计文档（v2.0）

> **目标读者**：AI Agent / LLM / 后续开发者
> **编写原则**：结构化的架构、模块划分、数据流描述，减少歧义，便于 AI 理解和维护
> **更新日期**：2026-07-19（补充在线搜索/URL→WebView 确认→AI 单书导入→缓存/刷新的总体设计）

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
│   │       ├── model/                 # 数据模型（含 AiBookProfile 单书解析档案）
│   │       ├── data/                  # 数据层
│   │       │   ├── database/          # 数据库 Dao（18 张核心表）
│   │       │   ├── preferences/       # 偏好设置（SettingsStore / GlobalConfig）
│   │       │   └── repository/        # 仓储（组合 Dao 的高阶操作）
│   │       ├── engine/                # ★ 引擎层（核心逻辑）
│   │       │   ├── source/            # 书源引擎（9 个文件）
│   │       │   ├── search/            # 搜索引擎（降级方案）
│   │       │   ├── book/              # 书籍解析（14 个文件）
│   │       │   ├── audio/             # 音频 / TTS（4 个文件）
│   │       │   ├── cache/             # 缓存
│   │       │   ├── download/          # 下载
│   │       │   ├── web/               # Web 服务 + WebView 取内容
│   │       │   ├── rss/               # RSS 解析引擎（3 个文件）
│   │       │   ├── ai/                # AI 书源生成 + 在线单书导入
│   │       │   └── translation/       # 翻译
│   │       ├── service/               # 后台服务（9 个）
│   │       ├── pages/                 # 页面（49 个 .ets/.ts 文件）
│   │       ├── components/            # 可复用组件
│   │       │   ├── reader/            # 阅读器组件（8 个文件）
│   │       │   ├── ui/                # 通用 UI 组件
│   │       │   └── common/            # 公共组件
│   │       ├── napi/                  # QuickJS NAPI 桥接
│   │       ├── theme/                 # 主题系统（4 个文件）
│   │       ├── util/                  # 工具类（18 个文件）
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
├── model/                             # 纯数据模型（16 个文件）
├── data/
    │   ├── database/                      # Dao 层：Table 类 + RdbUtil + AppDatabase，管理 18 张核心表
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
│   │   ├── SearchKeywordTable.ts      # 搜索关键词表（NEW）
│   │   ├── AiBookProfileTable.ts      # AI 单书解析档案表
│   │   └── RdbUtil.ts                 # RDB 工具类（建表辅助）
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
    │   ├── book/                          # 书籍格式解析（14 个文件）
    │   │   ├── TxtParser.ts               # TXT 解析（章节分割 + 编码检测）
    │   │   ├── DirEpubParser.ts           # EPUB 目录解析（从 zlib 解压目录读取 OPF/NCX）
    │   │   ├── MobiParser.ts              # MOBI 解析（PDB 格式，foliate-js 集成）
    │   │   ├── MobiProbeParser.ts         # MOBI 探测（头部解析 + DRM 检查）
    │   │   ├── PdfParser.ts               # PDF 解析（元数据 + 目录结构）
    │   │   ├── ComicReader.ts             # 漫画阅读器模型
    │   │   ├── ChapterManager.ts          # 章节管理器（预加载 + 排序）
    │   │   ├── ContentReplace.ts          # 内容替换引擎
    │   │   ├── TextLayout.ts              # 文字排版（分页 + 分行，基于 MeasureText）
    │   │   ├── LocalBookEngine.ts         # 本地书籍导入引擎
    │   │   ├── LocalBookFileUtil.ts       # 本地书文件名工具
    │   │   ├── EpubJsParser.ts            # EPUB.js 解析器逻辑
    │   │   ├── EpubParserWebView.ets      # EPUB 隐藏 WebView 解析组件
    │   │   └── ZipExtractTask.ets         # TaskPool 并发解压任务
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
    │   ├── ai/                            # AI 书源生成 + 在线单书导入
    │   │   ├── AiSourceAgent.ts           # AI 书源生成引擎（6 步 LLM 分析，382 行）
    │   │   └── AiBookImporter.ts          # 元数据/完整目录/正文规则验证/原子落库
│   └── translation/                   # 翻译
│       └── TranslationEngine.ts
├── service/                           # 有状态后台服务（9 个根目录 + 7 个 tts/ 子模块）
│   ├── BackupService.ts               # 完整备份/恢复
│   ├── WebDavService.ts               # WebDAV 远程同步
│   ├── DownloadService.ts             # 下载任务管理
│   ├── ReadAloudService.ts            # 后台朗读（RemoteObject）
│   ├── ReadAloudEngine.ets            # 朗读引擎（双后端：系统 TTS + sherpa-onnx）
│   ├── WebService.ts                  # HTTP 服务管理
│   ├── ControllerService.ts           # 全局播放控制
│   ├── BookshelfTransferService.ts    # 书架导入导出传输（NEW，323 行）
│   ├── SourceChecker.ts               # 书源校验服务（NEW，275 行）
│   ├── BookSourceResolver.ts           # 正式书源与 AI 单书档案统一解析
│   ├── BookCacheService.ts             # 在线书籍后台正文缓存
│   └── tts/                           # ★ TTS 后端模块（NEW）
│       ├── ITtsBackend.ets            # TTS 后端接口抽象
│       ├── SherpaOnnxTtsBackend.ets   # sherpa-onnx 离线神经 TTS
│       ├── AzureTtsBackend.ets        # Azure 云端 TTS
│       ├── WorkerTtsBackend.ets       # Worker 线程 TTS
│       ├── TextNormalizer.ets         # 中文文本规范化
│       ├── TtsModelManager.ets        # TTS 模型下载/校验/解压管理
│       └── TtsWorkerMsg.ets           # TTS Worker 通信协议
├── pages/                             # ArkUI 页面组件（49 个文件）
├── components/                        # 可复用 UI 组件
│   ├── reader/                        # 阅读器组件（11 个）
    │   │   ├── PageView.ets               # 分页视图（翻页动画）
    │   │   ├── StylePanel.ets             # 样式面板
    │   │   ├── ReadBottomMenu.ets         # 底部菜单
    │   │   ├── ReadAloudPanel.ets         # 朗读面板（511 行）
    │   │   ├── TtsControlPanel.ets        # TTS 控制面板
    │   │   ├── ClickAction.ts             # 点击动作定义
    │   │   ├── ClickActionConfig.ets      # 点击区域配置
    │   │   ├── PageTouchHandler.ets       # 触摸事件处理
    │   │   ├── CacheDialog.ets            # 缓存管理对话框
    │   │   ├── CloudflareDialog.ets       # Cloudflare 检测对话框（NEW）
    │   │   └── LoginDialog.ets            # 书源登录对话框（NEW）
│   ├── ui/                            # 通用 UI 组件
│   │   └── BookItem.ets
│   ├── BookCover.ets                  # 书籍封面
│   ├── BookInfoSheets.ets             # 书籍详情浮层（含 ChangeSourceSheet）
│   ├── WebViewEngine.ets              # 可复用 WebView 引擎组件
│   └── common/                        # 公共组件
│       └── LoadingView.ets
├── theme/                             # 主题/色彩管理（4 个文件）
    │   ├── AppTheme.ts                    # 主题管理器（单例，亮/暗切换，色板持久化）
    │   ├── ColorScheme.ts                 # MD3 色彩方案（光源/暗源色板）
    │   ├── ThemeColors.ets                # 统一语义化 Token（background/onBackground/surface 等）
    │   └── ThemeMode.ts                   # 主题模式枚举 + 配置接口
├── util/                              # 工具类（18 个文件）
    │   ├── HtmlParser.ts                  # ★ HTML 解析器（951 行，自研）
    │   ├── HtmlUtil.ts                    # HTML 清理
    │   ├── NetUtil.ts                     # 网络请求封装
    │   ├── FileUtil.ts                    # 文件操作
    │   ├── StrUtil.ts                     # 字符串处理
    │   ├── CryptoUtil.ts                  # 加密（MD5/SHA/Base64）
    │   ├── BookCoverUtil.ts               # 封面生成
    │   ├── ChineseConverter.ts            # 繁简转换（260 行）
    │   ├── ContentCache.ts                # 内容内存缓存
    │   ├── ContentCleaner.ts              # 内容清理（248 行）
    │   ├── ChapterCache.ts                # 章节缓存助手
    │   ├── SourceSwitchStore.ts           # 源切换存储
    │   ├── AppContext.ts                  # 应用上下文单例
    │   ├── CookieStore.ts                 # Cookie 持久化存储（NEW）
    │   ├── LoginInfoStore.ts              # 登录信息存储（NEW）
    │   ├── MangaImageLoader.ts            # 漫画图片加载/缓存/解密（NEW）
    │   ├── CoverDecoder.ts                # 封面图片解码（NEW）
    │   └── UiUtil.ets                     # UI 工具函数（NEW）
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
│     数据访问层 (data/database/, 18 张核心表)                │
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

#### 3.1.1 表结构总览（18 张表）

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
| `ai_book_profiles` | AiBookProfile | AI 导入书的单书解析档案 | bookId, bookUrl, baseUrl, tocUrl, sourceJson, lastRefreshAt, ruleVersion |

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
2. 按序创建核心表（包括 `ai_book_profiles`，建表均使用 `IF NOT EXISTS`）
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

### 4.1 核心模型

```
model/
├── Book.ts           # 书籍（BookType 枚举、BookGroup 枚举、Book interface）
├── BookChapter.ts    # 章节（bookId, title, url, index）
├── Chapter.ts        # 章节内容（chapterId, content）
├── BookSource.ts     # ★ 书源（40+ 规则字段 + BookSourceScript 接口）
├── BookGroup.ts      # ★ 书架分组（系统分组枚举 + BookGroupItem interface）
├── SearchResult.ts   # 搜索结果（含去重合并逻辑）
├── SearchKeyword.ts  # 搜索历史关键词
├── AiBookProfile.ts  # AI 导入书的一对一解析档案
├── Bookmark.ts       # 书签
├── ReadConfig.ts     # 阅读配置（PageMode, TextSizeUnit）
├── ReadRecord.ts     # 阅读记录
├── ReplaceRule.ts    # 替换规则（ReplaceScope 枚举）
├── RSSSource.ts      # RSS 源和文章
├── RSSImport.ts      # RSS 导入数据模型（Legado 备份格式）
├── CacheEntry.ts     # 缓存条目
├── AudioSource.ts    # 有声书/音频源（NEW）
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
├── SourceExecutor.ts       # ★ 书源执行器（核心协调者）
├── ScriptEngine.ts         # QuickJS 脚本引擎封装
├── ScriptApi.ts            # JS polyfill + 规则执行器脚本生成
├── RuleParser.ts           # 规则解析器（JSONPath / CSS / XPath / 正则）
├── RuleAnalyzer.ts         # 规则编排
├── AnalyzeByRegex.ts       # 正则 AllInOne 分析
├── ExploreEngine.ts        # 发现页引擎
├── SourceSwitcher.ts       # 书源切换器
└── JsExpressionEvaluator.ts # JS 表达式独立求值
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
├── TxtParser.ts             # TXT 解析（章节分割 + 编码检测）
├── DirEpubParser.ts         # EPUB 目录解析（从 zlib 解压目录读取 OPF/NCX）
├── MobiParser.ts            # MOBI/AZW/AZW3 全文解析（foliate-js 集成）
├── MobiProbeParser.ts       # MOBI 头部探测 + DRM 检查（轻量）
├── PdfParser.ts             # PDF 解析（元数据 + 目录结构 + 页面渲染）
├── ComicReader.ts           # 漫画阅读器模型（ComicPageMode/ComicScaleMode）
├── ChapterManager.ts        # 章节管理器（预加载 + 排序）
├── ContentReplace.ts        # 内容替换引擎（正则替换规则，作用域 + 排序）
├── TextLayout.ts            # 文字排版（分页 + 分行，基于 MeasureText API）
├── LocalBookEngine.ts       # ★ 本地书籍导入引擎（TXT/EPUB/MOBI/PDF/漫画）
├── LocalBookFileUtil.ts     # 本地书文件名工具（路径→书名提取）
├── EpubJsParser.ts          # EPUB.js 解析器（通过隐藏 WebView 调用）
├── EpubParserWebView.ets    # EPUB 解析隐藏 WebView 组件
└── ZipExtractTask.ets       # TaskPool @Concurrent 解压任务
```

### 5.3 音频引擎（`engine/audio/`）

```
engine/audio/
├── TTSPlayer.ts            # 文字转语音朗读（旧版，已被 ReadAloudEngine 取代）
├── AudioPlayer.ts          # 有声书音频播放
├── PlaylistManager.ts      # 播放列表与模式管理
└── ReadTimer.ts            # 定时关闭（15/30/45/60/90 分钟）
```

> TTS 朗读已迁移至 `service/ReadAloudEngine.ets` + `service/tts/` 双后端架构，详见 6.2 节。

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
├── AiSourceAgent.ts        # AI 书源生成引擎（6 步 LLM 分析）
└── AiBookImporter.ts       # 在线单书导入（抓取→规则分析/实测→目录与档案落库）
```

**AiSourceAgent 分析流程（6 步）**：
  1. HOMEPAGE  → 获取首页 HTML，分析页面结构
  2. SEARCH    → 发送搜索请求，分析搜索结果页
  3. BOOK_INFO → 访问书籍详情页，分析信息提取规则
  4. TOC       → 分析目录页规则
  5. CONTENT   → 分析正文页规则
  6. COMPILE   → 汇总生成完整书源 JSON

**AiBookImporter 流程**：

1. 校验用户确认的公网 URL，优先使用 WebView 渲染后的 HTML，HTTP/WebView 互为兜底。
2. 确定性提取书名、作者、封面、简介、字数等元数据，缺失项再由 LLM 补充。
3. 分析目录规则和“全部章节”入口，通过 `SourceExecutor` 跟进分页；剔除最近章节摘要、按 URL 去重并纠正明显倒序。
4. 最多选择 3 个章节分析正文规则，并调用真实正文提取链验证规则。
5. 事务内 upsert `Book`、替换目录并保存 `AiBookProfile`；**不写入全局 `BookSource` 表**。
6. 默认只保存目录；用户确认后可由 `BookCacheService` 启动整书后台缓存。

导入生成的临时 `BookSource.sourceUrl` 是网站根地址；详情页、目录页和每章 URL 分别保存，不能互相替代。后续阅读、缓存和刷新统一通过 `BookSourceResolver` 解析正式书源或单书档案。

依赖：
  - SettingsStore (AI 配置)
  - NetUtil (HTTP 请求)
  - HtmlUtil (HTML 清理)
  - WebViewFetcher (Cloudflare 兜底)
  - SourceExecutor (目录分页和正文规则实测)
  - AiBookProfileTable / BookSourceResolver (单书规则持久化与复用)

端到端细节见 [`doc/modules/online_book.md`](modules/online_book.md)。

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

### 6.1 服务总览（9 个根目录服务 + 6 个 tts/ 子模块）

| 服务 | 文件 | 类型 | 说明 |
|------|------|------|------|
| BackupService | service/BackupService.ts | 工具类 | 完整备份/恢复（书架+书源+规则+RSS+设置） |
| WebDavService | service/WebDavService.ts | 工具类 | WebDAV 远程同步（备份+阅读进度） |
| DownloadService | service/DownloadService.ts | 后台 | 下载任务管理（前台+后台） |
| ReadAloudService | service/ReadAloudService.ts | 后台+Remote | TTS 朗读服务（跨 Ability 通信，**旧版废弃**） |
| ReadAloudEngine | service/ReadAloudEngine.ets | 引擎 | ★ 朗读引擎（双后端架构，状态机：播放/暂停/停止/完成） |
| WebService | service/WebService.ts | 后台 | HTTP 服务管理 |
| ControllerService | service/ControllerService.ts | 后台 | 全局播放控制、通知 |
| BookshelfTransferService | service/BookshelfTransferService.ts | 工具类 | 书架导入导出（自动匹配书源、下载目录） |
| SourceChecker | service/SourceChecker.ts | 工具类 | 书源校验（多步检查） |
| **TTS 后端模块** | service/tts/ | | |
| ITtsBackend | service/tts/ITtsBackend.ets | 接口 | TTS 后端接口抽象（synthesize/listVoices/setVoice） |
| SherpaOnnxTtsBackend | service/tts/SherpaOnnxTtsBackend.ets | 实现 | sherpa-onnx + Kokoro 离线神经 TTS |
| AzureTtsBackend | service/tts/AzureTtsBackend.ets | 实现 | Azure 云端 TTS |
| WorkerTtsBackend | service/tts/WorkerTtsBackend.ets | 实现 | Worker 线程 TTS |
| TextNormalizer | service/tts/TextNormalizer.ets | 工具 | 中文文本规范化（数字/日期/标点） |
| TtsModelManager | service/tts/TtsModelManager.ets | 工具 | TTS 模型下载/校验/解压/版本管理 |

### 6.2 ReadAloudEngine — 朗读引擎（双后端架构）

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
  setBackend(backend): void      → 切换 TTS 后端（系统/sherpa-onnx/Azure）
}
```

**双后端架构**：
```
ITtsBackend 接口 ← 调度层 (ReadAloudEngine)
  ├── 系统 TTS（兜底，低功耗，无需下载）
  └── sherpa-onnx + Kokoro（离线神经 TTS，多音色，需下载模型 ~215MB）
       └── 102 种音色，支持中英文混读
```

**关键对接**：
- `synthesize()` 返回 Int16 PCM → `AudioRenderer` writeData 驱动播放
- 动态采样率切换（16000 / 24000 Hz）
- 分句队列 + 双缓冲 + 跨章节续读

### 6.3 BookshelfTransferService — 书架传输服务

```
exportBookshelf(books?): string           → 导出书架为 JSON
importBookshelf(json): TransferResult     → 导入书架（批量）
  ├── 自动检测书籍 URL 对应的书源
  ├── 下载目录信息
  ├── upsert 书籍到数据库
  └── 返回 success/skipped/failed 统计
```

### 6.4 SourceChecker — 书源校验服务

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
│   ├── 搜索入口 → SearchPage（书源/在线双标签）
│   ├── 分组标签切换（全部/未分组/本地/漫画/自定义）
│   ├── 书架配置 (BookshelfConfigDialog)
│   ├── 分组管理 (BookGroupManageDialog)
│   ├── URL添加 (AddBookUrlDialog)
│   ├── 书架导入 (BookshelfImportDialog)
│   ├── 书架导出 (BookshelfExportDialog)
│   ├── 书架管理 (BookshelfManagePage)
│   │   └── 批量选择 / 分组筛选 / 导出导入 / 传输
│   ├── 本地书籍导入（文件选择器）
│   └── click → ReadPage (文本) / ComicReadPage (漫画) / ReaderPage (EPUB图文)
├── Tab 1: ExplorePage                 (发现/搜索)
│   ├── ExploreBookPage                (发现书单)
│   ├── YoushuExplorePage / LkongExplorePage
│   │   └── 发现书 → 选择书源搜索/在线搜索 → SearchPage 对应标签
│   ├── SearchPage                     (统一搜索：书源多源搜索 / 在线搜索与 URL 导入)
│   │   └── AiImportPreviewDialog      (WebView 人工确认、导航、桌面/移动模式)
│   ├── SearchContentPage              (书内搜索)
│   ├── WebViewFetchDialog             (WebView 兜底)
│   └── click → BookInfoPage           (书籍详情)
│       ├── ChangeSourceSheet          (切换书源)
│       ├── "加入书架" → 数据库更新
│       └── "开始阅读" → ReadPage/ComicReadPage (阅读)
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
    │   ├── BackupSettingsPage         (备份与恢复)
    │   └── FontManagerPage            (字体管理)
    ├── AiConfigPage                   (AI 配置)
    ├── AiSourceGeneratePage           (AI 生成书源)
    ├── AiImportBookPage               (旧独立页面，保留兼容；不作为在线导入主入口)
    ├── BookmarkPage                   (书签)
    ├── AboutPage                      (关于)
    ├── WebServicePage                 (Web 服务)
    └── ReadRecordPage                 (阅读记录)

独立页面（通过 router.pushUrl 跳转）：
  ReadPage / BookInfoPage / BookSourcePage / SettingsPage
  ComicReadPage / EpubReadPage / SearchPage / ErrorPage / SimplePage
  WebFetchPage / WebViewFetchDialog / ChangeSourcePage
  ChapterListPage / SearchContentPage / FontManagerPage
  BackupSettingsPage / AiImportBookPage
```

### 7.2 页面文件总览（49 个）

| 分类 | 文件 | 说明 |
|------|------|------|
| 书架 | BookshelfPage.ets | 书架主页（分组标签/配置/导入导出） |
| 书架 | BookshelfManagePage.ets | 批量管理（选择/筛选/导出导入/传输） |
| 书架 | BookshelfConfigDialog.ets | 书架显示配置 |
| 书架 | BookshelfExportDialog.ets | 导出书架 JSON |
| 书架 | BookshelfImportDialog.ets | 导入书架 JSON |
| 书架 | AddBookUrlDialog.ets | URL 添加书籍 |
| 书架 | BookGroupManageDialog.ets | 分组管理 |
| 书架 | GroupManageDialog.ets | 移动书籍到分组 |
| 发现 | ExplorePage.ets | 搜索 + 发现 |
| 发现 | ExploreBookPage.ets | 发现书单列表 |
| 发现 | SearchPage.ets | 统一搜索页：书源/在线双标签、历史、搜索引擎、URL 输入和 WebView 确认 |
| 发现 | YoushuExplorePage.ets | 优书发现书入口，选择搜索方式并跳转对应标签 |
| 发现 | LkongExplorePage.ets | 龙空发现书入口，选择搜索方式并跳转对应标签 |
| 发现 | SearchContentPage.ets | 书内搜索 |
| 阅读 | ReadPage.ets | 阅读主页面（文本/分页/滚动模式） |
| 阅读 | ReaderPage.ets | 图文混排阅读页（EPUB/MOBI WebView） |
| 阅读 | ComicReadPage.ets | 漫画阅读器（缩放手势/阅读方向/自动阅读） |
| 阅读 | EpubReadPage.ets | EPUB 阅读页（WebView 方案，框架） |
| 阅读 | SimplePage.ets | 简版阅读视图 |
| 阅读 | BookmarkPage.ets | 书签管理 |
| 阅读 | ChapterListPage.ets | 章节目录 |
| 阅读 | ChangeSourcePage.ets | 换源搜索 |
| 阅读 | ReadRecordPage.ets | 阅读记录 |
| 详情 | BookInfoPage.ets | 书籍详情 |
| RSS | RssMainPage.ets | RSS 订阅主页 |
| RSS | RssArticlesPage.ets | RSS 文章列表 |
| RSS | RssReadPage.ets | RSS 文章阅读 |
| RSS | RssFavoritesPage.ets | RSS 收藏 |
| RSS | RssSortPage.ets | RSS 排序规则 |
| RSS | RssSourceManagePage.ets | RSS 源管理 |
| RSS | RssSourceEditPage.ets | RSS 源编辑 |
| RSS | RssImportDialog.ets | RSS 源导入 |
| RSS | RSSPage.ets | 旧版 RSS（保留） |
| 书源 | BookSourcePage.ets | 书源列表 |
| 书源 | BookSourceEditPage.ets | 书源编辑 |
| 书源 | ImportSourceDialog.ets | 导入书源 |
| 书源 | RuleSubPage.ets | 规则订阅 |
| AI | AiConfigPage.ets | AI 配置 |
| AI | AiSourceGeneratePage.ets | AI 生成书源 |
| AI | AiImportBookPage.ets | 旧独立 AI 导入页（兼容保留，主流程已整合到 SearchPage） |
| 设置 | SettingsPage.ets | 设置（含备份恢复/字体管理入口） |
| 设置 | BackupSettingsPage.ets | 备份与恢复（WebDAV + 本地） |
| 设置 | FontManagerPage.ets | 字体管理（导入/预览/批量删除） |
| 设置 | AboutPage.ets | 关于 |
| Web | WebServicePage.ets | Web 服务 |
| Web | WebFetchPage.ets | WebView 取内容 |
| Web | WebViewFetchDialog.ets | WebView 兜底对话框 |
| 通用 | MainPage.ets | 4 Tab 主页 |
| 通用 | MyPage.ets | "我的"页面 |
| 通用 | ErrorPage.ets | 错误页面 |
| Worker | JsEvalWorker.ts | Worker 线程 JS 执行 |

### 7.3 阅读器组件（`components/reader/`）

| 组件 | 文件 | 用途 |
|------|------|------|
| PageView | PageView.ets | 分页视图 + 翻页动画（滑动/覆盖/无） |
| StylePanel | StylePanel.ets | 阅读样式配置面板 |
| ReadBottomMenu | ReadBottomMenu.ets | 底部菜单栏 |
| ReadAloudPanel | ReadAloudPanel.ets | 朗读控制面板（引擎切换/音色/语速/播放控制） |
| TtsControlPanel | TtsControlPanel.ets | TTS 语速/音色配置浮层 |
| ClickAction | ClickAction.ts | 点击动作定义（菜单/翻页前/翻页后/无） |
| ClickActionConfig | ClickActionConfig.ets | 点击区域配置面板 |
| PageTouchHandler | PageTouchHandler.ets | 触摸事件处理（单击/长按/滑动方向） |
| CacheDialog | CacheDialog.ets | 章节缓存管理对话框 |
| CloudflareDialog | CloudflareDialog.ets | Cloudflare 检测对话框 |
| LoginDialog | LoginDialog.ets | 书源登录对话框 |

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
├── AppTheme.ts        # 主题管理器（单例，亮/暗切换，色板持久化）
├── ColorScheme.ts     # MD3 色彩方案（光源/暗源色板，A11Y）
├── ThemeColors.ets    # ★ 统一语义化 Token（background/onBackground/surface 等）
└── ThemeMode.ts       # 主题类型枚举 + 配置接口
```

### 9.2 语义化 Token

所有页面和组件**必须**通过 `ThemeColors` 获取颜色，禁止硬编码。核心 Token：

| Token | 用法 |
|-------|------|
| `ThemeColors.background(isDark)` | 页面背景 |
| `ThemeColors.onBackground(isDark)` | 正文文字 |
| `ThemeColors.surface(isDark)` | 卡片/浮层背景 |
| `ThemeColors.onSurface(isDark)` | 卡片上文字 |
| `ThemeColors.outlineVariant(isDark)` | 分割线/边框 |
| `ThemeColors.secondaryText(isDark)` | 次要说明文字 |
| `ThemeColors.primary(isDark)` | 主色调/链接 |
| `ThemeColors.error(isDark)` | 错误/删除色 |

---

## 10. 工具层（18 个文件）

| 工具 | 文件 | 核心能力 |
|------|------|---------|
| HtmlParser | util/HtmlParser.ts | 自研 HTML/CSS 解析器，支持 Default 规则、位置索引、排除索引、属性选择器、CSS 伪类 |
| HtmlUtil | util/HtmlUtil.ts | HTML 标签剥离，实体解码，纯文本提取 |
| NetUtil | util/NetUtil.ts | HTTP GET/POST/PUT，UA/编码检测，超时控制 |
| FileUtil | util/FileUtil.ts | 文件读写，目录操作 |
| StrUtil | util/StrUtil.ts | 字符串相似度（Levenshtein/Cosine） |
| CryptoUtil | util/CryptoUtil.ts | MD5/SHA1/SHA256/Base64 |
| BookCoverUtil | util/BookCoverUtil.ts | 文字封面 Canvas 生成，颜色映射 |
| ChineseConverter | util/ChineseConverter.ts | 简繁双向转换（OpenCC 词表） |
| ContentCache | util/ContentCache.ts | 章节内容内存缓存 |
| ContentCleaner | util/ContentCleaner.ts | 广告/脚本/空行清理，formatKeepImg 图片保留 |
| ChapterCache | util/ChapterCache.ts | 章节内容缓存助手 |
| SourceSwitchStore | util/SourceSwitchStore.ts | 换源结果持久化 |
| AppContext | util/AppContext.ts | 全局 Context 单例 |
| CookieStore | util/CookieStore.ts | Cookie 持久化存储 |
| LoginInfoStore | util/LoginInfoStore.ts | 登录信息存储 |
| MangaImageLoader | util/MangaImageLoader.ts | 漫画图片加载/缓存/解密/进度回调 |
| CoverDecoder | util/CoverDecoder.ts | 封面图片解码 |
| UiUtil | util/UiUtil.ets | UI 工具函数（颜色/布局/设备信息） |

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

### 11.5 在线搜索与 AI 单书导入数据流

```text
优书/龙空“发现书” ─┐
书架搜索输入书名 ───┼→ SearchPage（书源 / 在线）
直接输入公网 URL ───┘                 │
                                      ▼
在线搜索引擎 WebView（Bing 默认，可选百度/搜狗/神马/Google）
  │ 用户进入具体小说详情页或目录页
  │ 后退 / 前进 / 刷新 / 桌面-移动切换
  ▼
AiImportPreviewDialog.confirm()
  │ 当前 URL + 渲染后 outerHTML
  ▼
AiBookImporter.import()
  ├─ URL/页面安全校验；HTTP 与 WebView 兜底
  ├─ 元数据提取（确定性优先，LLM 补充）
  ├─ 完整目录入口识别 → 目录分页（≤60 页，≤5 并发）
  ├─ 最近章节摘要剔除 → URL 去重 → 明显倒序纠正
  ├─ 最多 3 章正文样本 → 规则生成 → SourceExecutor 实测
  └─ RDB 事务
       ├─ upsert books（bookUrl = 用户确认的详情页）
       ├─ replace chapters（每章保留真实 URL 与旧缓存状态）
       └─ upsert ai_book_profiles（sourceJson 内的 sourceUrl = 网站根地址）
              ※ 不向 book_sources 写入单书临时源
  │
  ▼
导入完成 → 稍后按需缓存 / BookCacheService 立即后台缓存
  │
  └─ 后续刷新：BookSourceResolver → getToc → 保留内容地替换目录
```

这条数据流是人工确认与自动分析的组合：搜索引擎只负责定位，用户负责确认目标网页，Agent 负责把目标网页转换成经过实测的单书解析档案。详细状态、错误恢复和验收标准见 [`doc/modules/online_book.md`](modules/online_book.md)。

### 11.6 书架导入传输数据流

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

### D-004: 18 张核心表（扩展版）

**问题**：原 Android Legado 有 28 张表，部分表用途重叠。初始设计精简为 12 张。
**决策**：随着功能增加，扩展至 18 张表；除分组、搜索历史、RSS 收藏等表外，增加 `ai_book_profiles` 保存 AI 导入书的一对一解析档案。
**影响**：数据库体积略增，但单书规则不再污染全局书源列表，并可支持后续阅读、缓存和刷新。

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

### D-011: TTS 双后端架构

**问题**：系统 TTS 音色少、自然度受限、离线不可控。
**决策**：ReadAloudEngine 引入 `ITtsBackend` 接口抽象，系统 TTS 为基础后端，sherpa-onnx + Kokoro 为高品质后端。切换时动态重建 AudioRenderer（采样率 16000/24000）。
**影响**：保留低功耗兜底 + 离线高质量双选择，但模型 ~215MB 需用户主动下载。

### D-012: 漫画整页/条漫双模式

**问题**：漫画书源有页模式和条漫（长图滚动）两种阅读方式。
**决策**：ComicReadPage 支持 4 种阅读模式（条漫/左→右/右→左/单页全屏），通过 SettingsStore 持久化。图片下载缓存到沙箱，支持防盗链 Referer。
**影响**：对齐安卓版漫画阅读体验，但图片缓存增加了沙箱空间占用。

### D-013: TaskPool 替代 Worker 做解压

**问题**：EPUB 解压在主线程执行导致 ANR，Worker 创建需要 EAWorker 被 WebView 占用。
**决策**：改用 TaskPool `@Concurrent` 函数进行 ZIP 解压，不消耗 EAWorker 资源。
**影响**：避免主线程卡顿，但 `@Concurrent` 函数限制不能调用同文件的其他函数。

### D-014: PDF 原生渲染（WebView）

**问题**：鸿蒙无原生 PDF 渲染 API。
**决策**：利用 WebView 加载 PDF 文件实现渲染，支持横竖屏切换、裁边显示、双页模式。
**影响**：无需第三方库，但依赖 WebView 能力和 PDF 的浏览器兼容性。

### D-015: 在线导入采用 WebView 人工确认

**问题**：通用搜索结果、广告跳转和移动站重定向无法仅靠后台抓取可靠判断最终目标书页。
**决策**：在线搜索与直接 URL 均先进入同一个 WebView 预览，由用户导航到具体书籍页后提交当前 URL 和渲染后 DOM；默认桌面模式，并提供后退、前进、刷新和页面模式切换。
**影响**：多一步确认，但显著降低误导入；搜索引擎 DOM 变化不影响核心导入器。WebViewController 必须与单一 Web 组件绑定并在就绪后调用。

### D-016: 单书解析档案与正式书源分离

**问题**：为导入一本书创建一个全局书源，会污染书源管理、错误暗示该规则可搜索整个站点，并导致 `sourceUrl` 与详情页 URL 混淆。
**决策**：`AiBookImporter` 只构造临时 `BookSource`，其中 `sourceUrl` 为站点根地址；验证后的规则序列化到 `AiBookProfile`。`BookSourceResolver` 对上层统一解析正式书源和单书档案。
**影响**：阅读、缓存和刷新仍可复用 `SourceExecutor`，同时全局书源保持用户可控；删除书籍时应同步清理对应档案。

### D-017: 目录先行、正文按需缓存

**问题**：导入阶段同步下载整书正文耗时长、失败面大，也与阅读页和离线缓存已有能力重复。
**决策**：导入成功的边界是“书籍元数据 + 完整目录 + 已验证正文规则 + 单书档案”已原子落库；正文默认阅读时按需获取，用户也可选择立即启动后台整书缓存。
**影响**：导入更快且可恢复；缓存任务与导入事务解耦，后台缓存失败不会撤销已经成功的书籍导入。

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
