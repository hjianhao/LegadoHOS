# LegadoHOS — 设计文档

> **目标读者**：AI Agent / LLM / 后续开发者
> **编写原则**：结构化的架构、模块划分、数据流描述，减少歧义，便于 AI 理解和维护

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
│   │       │   ├── database/          # 数据库 Dao（12 张表）
│   │       │   ├── preferences/       # 偏好设置
│   │       │   └── repository/        # 仓储（组合 Dao 的高阶操作）
│   │       ├── engine/                # ★ 引擎层（核心逻辑）
│   │       │   ├── source/            # 书源引擎
│   │       │   ├── search/            # 搜索引擎
│   │       │   ├── book/              # 书籍解析
│   │       │   ├── audio/             # 音频 / TTS
│   │       │   ├── cache/             # 缓存
│   │       │   ├── download/          # 下载
│   │       │   └── web/               # Web 服务
│   │       ├── service/               # 后台服务（6 个）
│   │       ├── pages/                 # 页面（20+ 个 .ets）
│   │       ├── components/            # 可复用组件
│   │       ├── napi/                  # QuickJS NAPI 桥接
│   │       ├── theme/                 # 主题系统
│   │       ├── util/                  # 工具类（8 个）
│   │       └── widget/                # 桌面小部件
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
├── model/                             # 纯数据模型（interface / enum）
├── data/
│   ├── database/                      # Dao 层：每个表一个类，封装 SQL 操作
│   ├── preferences/                   # KV 存储封装（@ohos.data.preferences）
│   └── repository/                    # 仓储层：组合多个 Dao 的复杂操作
├── engine/                            # 无状态逻辑层
│   ├── source/                        # 书源引擎（核心复杂度所在）
│   ├── search/                        # 搜索（降级方案）
│   ├── book/                          # 书籍格式解析
│   ├── audio/                         # 音频播放 + TTS
│   ├── cache/                         # 缓存策略
│   ├── download/                      # 下载管理
│   └── web/                           # HTTP 服务
├── service/                           # 有状态后台服务
├── pages/                             # ArkUI 页面组件
├── components/                        # 可复用 UI 组件
├── theme/                             # 主题/色彩管理
├── util/                              # 工具类
├── napi/                              # NAPI 桥接（ArkTS 侧）
└── widget/                            # 桌面小部件
```

---

## 2. 整体架构

### 2.1 分层架构

```
┌─────────────────────────────────────────────┐
│               UI 层 (pages/)                 │
│   Bookshelf / Explore / Read / Settings ...  │
├─────────────────────────────────────────────┤
│           组件层 (components/)                │
│        BookCover / LoadingView / ...         │
├─────────────────────────────────────────────┤
│           服务层 (service/)                   │
│   Backup / WebDav / Download / ReadAloud     │
├─────────────────────────────────────────────┤
│             引擎层 (engine/)                  │
│  Source  │ Search │ Book │ Audio │ Cache ... │
├─────────────────────────────────────────────┤
│          仓储层 (data/repository/)            │
│         BookRepository / SourceRepo          │
├─────────────────────────────────────────────┤
│          数据访问层 (data/database/)           │
│    BookTable / SourceTable / ChapterTable    │
├─────────────────────────────────────────────┤
│   ┌──────────┐  ┌──────────┐  ┌───────────┐ │
│   │ 模型层    │  │ NAPI桥接  │  │ 工具层     │ │
│   │model/    │  │napi/     │  │util/      │ │
│   └──────────┘  └──────────┘  └───────────┘ │
├─────────────────────────────────────────────┤
│             QuickJS C++ (libraries/)         │
│         napi_bridge.cpp + quickjs.c          │
└─────────────────────────────────────────────┘
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

#### 3.1.1 表结构总览

| 表名 | 对应模型 | 用途 | 关键字段 |
|------|---------|------|---------|
| `book` | Book | 书籍信息 | name, author, origin, isShelf, durChapterIndex |
| `chapters` | BookChapter | 章节列表 | bookId, title, url, index |
| `book_sources` | BookSource | 书源规则 | sourceName, sourceUrl, ruleSearchUrl, ... |
| `bookmarks` | Bookmark | 书签 | bookId, chapter, position, content |
| `read_records` | ReadRecord | 阅读记录 | bookId, lastReadTime |
| `read_record_details` | ReadRecordDetail | 阅读详情 | recordId, chapterIndex, progress |
| `replace_rules` | ReplaceRule | 替换规则 | name, pattern, replacement, scope |
| `rss_sources` | RSSSource | RSS 源 | sourceName, url, group |
| `rss_articles` | RSSArticle | RSS 文章 | sourceId, title, content, pubDate |
| `cache` | CacheEntry | 缓存 | key, data, expireTime |
| `txt_toc_rules` | TxtTocRule | TXT 目录规则 | pattern, level |
| `search_results` | SearchResult | 搜索结果缓存 | bookName, author, sourceUrl, data |

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
2. 按序执行 12 条 `CREATE TABLE IF NOT EXISTS` SQL
3. 执行 3 条 `ALTER TABLE ADD COLUMN` 迁移（try-catch 幂等）

#### 3.1.3 Dao 层约定

每个 Table 类遵循以下模式：

```typescript
class BookTable {
  constructor(private db: relationalStore.RdbStore) {}

  // 插入
  async insert(book: Book): Promise<number>

  // 查询
  async getAllShelfBooks(): Promise<Book[]>
  async getBookByName(name: string, author: string): Promise<Book | null>

  // 更新
  async update(book: Book): Promise<void>

  // 删除
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
├── Chapter.ts        # 章节（内容文本版本，chapterId, content）
├── BookSource.ts     # ★ 书源（40+ 字段，规则定义）
├── SearchResult.ts   # 搜索结果（含去重合并逻辑）
├── Bookmark.ts       # 书签
├── ReadConfig.ts     # 阅读配置（PageMode, TextSizeUnit）
├── ReadRecord.ts     # 阅读记录
├── ReplaceRule.ts    # 替换规则（ReplaceScope 枚举）
├── RSSSource.ts      # RSS 源和文章
├── CacheEntry.ts     # 缓存条目
└── BookSource.ts     # 书源脚本接口（BookSourceScript）
```

### 4.2 BookSource 核心字段（40+ 规则字段）

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
│ script (完整 JS 书源脚本，可替代规则式) │
└─────────────────────────────────────────┘
```

**规则字段类型兼容性**（`toRuleString()`）：
- 字符串 → 直接存储
- JSON 对象 → `JSON.stringify` 后存储
- JSON 数组 → `JSON.stringify` 后存储

---

## 5. 引擎层

### 5.1 书源引擎（`engine/source/`）

这是整个应用最核心最复杂的模块。

```
engine/source/
├── SourceExecutor.ts       # ★ 书源执行器（核心协调者）
├── ScriptEngine.ts         # QuickJS 脚本引擎封装
├── ScriptApi.ts            # JS polyfill + 规则执行器脚本生成
├── RuleParser.ts           # 规则解析器（JSONPath / CSS / XPath / 正则）
├── ExploreEngine.ts        # 发现页引擎
└── SourceSwitcher.ts       # 书源切换器
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

**URL 构建系统**（`buildUrl()` / `resolveUrl()`）：

```
模板变量替换：
  {{key}} / {{keyword}} → encodeURIComponent(搜索词)
  {{page}} / {{pageNum}} → 页码
  {{bookUrl}} / {{bookurl}} → 书籍详情页 URL
  {{id}} / {{novelId}} → 从 chapterUrl 提取数字 ID

分组页语法：
  <选项1, 选项2, 选项3> → 按页码选择对应项

相对路径处理：
  非 http(s) 开头 → baseUrl + 相对路径
```

**搜索响应解析链路**：

```
HTTP 响应
  │
  ├── 尝试 JSON.parse → 成功 → JSONPath 规则解析
  │
  ├── 有 ruleSearchList → RuleParser 规则解析
  │
  ├── 无 ruleSearchList → 兜底文本提取 (extractBookNamesFromHtml)
  │
  └── 最后尝试 → 直接规则解析（不通过 QuickJS）
```

**章节反转自动检测**（`isReversedOrder()`）：

```
检测条件（任一条满足即认为反转）：
  1. 首个标题含"大结局/尾声/后记/完本" 且 末个标题含"第一章"
  2. 中间某个标题是第一章，但首个不是
  3. 末个标题是第一章，但首个不是
  4. 首章节号远大于末章节号（差值 > 50）
```

#### 5.1.2 ScriptEngine — QuickJS 封装

```
class ScriptEngine {
  initialize()     → 加载原生模块 / 创建引擎实例 / 注册 HTTP handler
  executeScript()  → 执行 JS 字符串
  callFunction()   → 调用 JS 全局函数（JSON 序列化传参）
  loadSourceScript() → 加载书源脚本到引擎
  hasFunction()    → 检查 JS 环境是否有某函数
  destroy()        → 销毁引擎
}
```

**HTTP 请求委托机制**（避免 NAPI 死锁）：

```
JS 侧发起 fetch(url)
  → NAPI bridge 收到请求，回调 ArkTS handler
  → ArkTS 侧通过 NetUtil.httpGet() 实际发起网络请求
  → 结果通过 onHttpResponse() 传回 JS 侧
```

#### 5.1.3 RuleParser — 规则解析器

```
支持四种规则类型：

1. JSONPath:    $.list[*].name
   → 用 . 分隔路径，支持 [*] 和 [N]

2. CSS 选择器:  div.book-list > .item
   → 简化的标签/ID/Class 匹配

3. XPath:       //div[@class="book-list"]
   → 标签名 + 属性过滤

4. 正则:        regex(pattern, flags)
   → new RegExp + exec 循环
```

#### 5.1.4 引擎降级策略

```
原生 QuickJS 可用          → ScriptEngine + RuleParser 双模式
原生 QuickJS 不可用 (Mock)  → 所有解析走 RuleParser（纯 ArkTS）
├── JSONPath / CSS / XPath / 正则  → 正常
├── JS 书源脚本                  → 无法执行
└── polyfill 函数                → 无法执行
```

### 5.2 书籍解析引擎（`engine/book/`）

```
engine/book/
├── TxtParser.ts           # TXT 解析（章节分割 + 编码检测）
├── EpubParser.ts          # EPUB 解析（OPF + NCX）
├── MobiParser.ts          # MOBI 解析（PDB 格式）
├── PdfParser.ts           # PDF 解析（元数据 + 目录结构）
├── ComicReader.ts         # 漫画阅读器（页面模式 + 缩放模式）
├── ChapterManager.ts      # 章节管理器（预加载 + 排序）
├── ContentReplace.ts      # 内容替换引擎
└── TextLayout.ts          # 文字排版（分页 + 分行）
```

#### 5.2.1 TXT 解析器

```
TxtParser.parse(filePath: string): TxtParseResult
  → 编码检测 → 章节分割（正则模式匹配）
  → 返回 { chapters: [{title, startPos, endPos}], encoding }

章节分割模式：
  "第X章" / "第X节" / "第X卷" / "序章" / "引子" ...
  支持正则模式自定义（通过 txt_toc_rules 表）
```

#### 5.2.2 EPUB 解析器

```
EpubParser.parse(filePath: string): EpubParseResult
  → 解压 → 读取 OPF (package.opf)
  → 解析 manifest (所有资源文件)
  → 解析 spine (阅读顺序)
  → 解析 NCX / nav (目录结构)
  → 提取章节 HTML → 清理 → 纯文本
```

### 5.3 音频引擎（`engine/audio/`）

```
engine/audio/
├── TTSPlayer.ts            # 文字转语音朗读
├── AudioPlayer.ts          # 有声书音频播放
├── PlaylistManager.ts      # 播放列表与模式管理
└── ReadTimer.ts            # 定时关闭
```

**TTSPlayer**:
- 基于 HarmonyOS `@ohos.reminderAgent` / 系统 TTS 能力
- 支持暂停/继续/停止/进度回调
- 支持跨 Ability 后台朗读（通过 ReadAloudService）

**AudioPlayer**:
- 基于 `@ohos.multimedia.audio`
- 支持暂停/继续/seek
- 支持 PlayState 状态管理

**PlaylistManager**:
- 支持四种播放模式：顺序、循环、随机、单曲循环
- 自动下一首

**ReadTimer**:
- 支持 15/30/45/60 分钟定时关闭
- 倒计时机制

### 5.4 缓存引擎（`engine/cache/CacheManager.ts`）

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

### 5.5 下载引擎（`engine/download/DownloadManager.ts`）

```
DownloadManager:
  download(items: DownloadItem[]): void    → 批量加入下载队列
  pause(taskId): void                      → 暂停
  resume(taskId): void                     → 继续
  cancel(taskId): void                     → 取消
  getProgress(taskId): number              → 获取进度

DownloadItem:
  bookId, chapterUrl, chapterTitle, retryCount
```

### 5.6 翻译引擎（`engine/translation/TranslationEngine.ts`）

```
TranslationEngine:
  translate(text, from, to, provider?): Promise<string>
  detectLanguage(text): string

支持的翻译提供商（TranslationProvider）：
  GOOGLE, DEEPL, BAIDU, YOUDAO, MICROSOFT
```

### 5.7 Web 服务（`engine/web/WebServer.ts`）

```
WebServer:
  start(port: number): void       → 启动 HTTP 服务器
  stop(): void                     → 停止服务
  isRunning(): boolean             → 检查运行状态

提供：
  - 阅读内容 HTTP 访问
  - 远程管理接口
```

---

## 6. 服务层

### 6.1 服务总览

| 服务 | 文件 | 类型 | 说明 |
|------|------|------|------|
| BackupService | service/BackupService.ts | 工具类 | 完整备份/恢复（书架+书源+规则+RSS+设置） |
| WebDavService | service/WebDavService.ts | 工具类 | WebDAV 远程同步 |
| DownloadService | service/DownloadService.ts | 后台 | 下载任务管理（前台+后台） |
| ReadAloudService | service/ReadAloudService.ts | 后台+Remote | TTS 朗读服务（跨 Ability 通信） |
| WebService | service/WebService.ts | 后台 | HTTP 服务管理 |
| ControllerService | service/ControllerService.ts | 后台 | 全局播放控制、通知 |

### 6.2 BackupService

```
exportBackup() → 导出 JSON（books + sources + replaceRules + rss + settings）
importBackup(data) → 导入（逐项 try-catch，记录错误数）
ImportResult { books, sources, rules, errors }
```

### 6.3 WebDavService

```
WebDavConfig:
  serverUrl, username, password, path

功能：
  upload(data, filename)    → 上传到 WebDAV
  download(filename)        → 从 WebDAV 下载
  list()                    → 列出远程文件
  delete(filename)          → 删除远程文件
```

### 6.4 ReadAloudService

```
extends rpc.RemoteObject   → 跨进程通信

方法：
  startRead(text, options)  → 开始朗读
  pause()                   → 暂停
  resume()                  → 继续
  stop()                    → 停止
  getProgress()             → 获取进度
```

---

## 7. UI 层

### 7.1 页面导航结构

```
MainPage (Tabs)
├── Tab 0: BookshelfPage        (书架)
│   └── click → ReadPage        (阅读)
├── Tab 1: ExplorePage          (发现/搜索)
│   └── click → BookInfoPage    (书籍详情)
│       ├── "加入书架" → 数据库更新
│       └── "开始阅读" → ReadPage (阅读)
├── Tab 2: (RSS placeholder)
└── Tab 3: MyPage               (我的)
    ├── BookSourcePage           (书源管理)
    │   └── ImportSourceDialog   (导入书源)
    ├── SettingsPage             (设置)
    ├── BookmarkPage             (书签)
    ├── AboutPage                (关于)
    ├── WebServicePage           (Web服务)
    └── ReadRecordPage           (阅读记录)

独立页面（通过 router.pushUrl 跳转）：
  ReadPage / BookInfoPage / BookSourcePage / SettingsPage
  ComicReadPage / RSSPage / SearchPage / ErrorPage / SimplePage
  WebFetchPage / WebViewFetchDialog
```

### 7.2 组件复用

| 组件 | 文件 | 用途 |
|------|------|------|
| BookCover | components/BookCover.ets | 书籍封面（图片/首字色块） |
| LoadingView | components/common/LoadingView.ets | 加载中占位 |
| BookItem | components/ui/BookItem.ets | 书籍列表项 |

### 7.3 Widget

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

### 8.3 QuickJSBridge 接口

```typescript
interface QuickJSBridge {
  createEngine(): number;
  destroyEngine(engineId: number): void;
  executeScript(engineId: number, script: string): string;
  callFunction(engineId: number, functionName: string, argsJson: string): string;
  onHttpResponse(requestId: number, responseBody: string, isError: boolean): void;
  registerHttpHandler(
    handler: (requestId: number, url: string, method: string,
              headersJson: string, body?: string) => void
  ): void;
}
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

### 9.2 AppTheme

```
class AppTheme {
  isDark: boolean               → 当前是否为暗色模式
  getCurrentScheme(): AppColorScheme  → 获取当前色彩方案
  
  toggle(): Promise<void>       → 切换亮/暗
  setTheme(mode: ThemeMode): Promise<void>  → 设置主题
  loadSaved(): Promise<void>    → 加载已保存的主题设置
}
```

### 9.3 ColorScheme

```
AppColorScheme {
  primary, primaryContainer,       → MD3 主色
  secondary, secondaryContainer,
  tertiary, tertiaryContainer,
  background, surface, surfaceVariant,
  error, errorContainer,
  onPrimary, onSecondary,
  onBackground, onSurface,
  outline, shadow, ...
}
```

### 9.4 ThemeMode

```
ThemeMode: LIGHT | DARK | SYSTEM
ColorMode: MONOCHROME | RED | ORANGE | YELLOW | GREEN | BLUE | PURPLE
PresetPalette: DEFAULT | SEPIA | GREEN | BLUE | GRAY | NIGHT
```

---

## 10. 工具层

| 工具 | 文件 | 核心能力 |
|------|------|---------|
| NetUtil | util/NetUtil.ts | HTTP GET/POST/PUT，编码检测，超时控制，UA 构建 |
| HtmlUtil | util/HtmlUtil.ts | HTML 标签剥离，实体解码，纯文本提取，资源URL提取 |
| FileUtil | util/FileUtil.ts | 文件读写，目录操作（创建/删除/列出），路径工具 |
| StrUtil | util/StrUtil.ts | 字符串相似度（Levenshtein/Cosine），格式校验 |
| CryptoUtil | util/CryptoUtil.ts | MD5/SHA1/SHA256/Base64 编解码 |
| ZipReader | util/ZipReader.ts | Zip 解压（支持 store/deflate），条目列表，流式读取 |
| BookCoverUtil | util/BookCoverUtil.ts | 文字封面 Canvas 生成，颜色映射 |

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
  └─ 无书源 → NetUtil.httpGet 直连 → stripHtml
```

### 11.3 书源导入数据流

```
ImportSourceDialog → 用户输入 URL 或 JSON
  │
  ├─ URL 模式 → NetUtil.httpGet → JSON.parse
  └─ JSON 模式 → 直接 JSON.parse
  │
  ▼
parseBookSource(json) → 兼容多字段名
  │
  ▼
BookSourceTable.insert(source) → 数据库保存
```

### 11.4 备份/恢复数据流

```
导出：
  BackupService.exportBackup()
  → 查询所有表 (shelfBooks + sources + rules + rss + settings)
  → 组装 BackupData
  → JSON.stringify
  → 保存文件 / 上传 WebDAV

导入：
  BackupService.importBackup(data)
  → 逐项 insert
  → 记录错误数返回
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

### D-004: 单数据库 + 12 张核心表（精简版）

**问题**：原 Android Legado 有 28 张表，部分表用途重叠。
**决策**：精简为 12 张核心表，移除不常用的审计日志、历史表等。
**影响**：数据库体积更小，迁移更简单，但可能丢失部分非核心功能。

### D-005: 双模式书源加载

**问题**：书源有两种格式（规则式 JSON + JS 脚本式），需要统一处理。
**决策**：RuleParser 解析规则式，ScriptEngine 执行 JS 脚本式，SourceExecutor 作为统一入口根据书源内容自动选择。
**影响**：兼容现有全部 Legado 书源，但代码复杂度增加。

### D-006: 章节反转自动检测

**问题**：部分小说网站最新章在前，直接显示会导致阅读顺序错误。
**决策**：在 ReadPage 加载目录后自动检测反转（4 种条件），检测到则反转列表。
**影响**：用户无需手动调整，但检测算法可能对非标准网站误判。

### D-007: 引擎降级策略

**问题**：QuickJS NAPI 模块可能因平台版本或编译问题不可用。
**决策**：NAPI 桥接层设计为可降级（Mock 模式），当原生模块不可用时，所有解析走 RuleParser（纯 ArkTS）。JS 书源脚本无法执行，但规则式书源可正常使用。
**影响**：增强应用鲁棒性，但降级后失去 JS 脚本能力。

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
            ┌────────────────────────┼────────────────────────┐
            │                        │                        │
   ┌────────▼────────┐    ┌──────────▼──────────┐  ┌─────────▼─────────┐
   │    Pages        │    │    SourceExecutor    │  │    Services       │
   │  (UI 组件)       │    │  (engine/source/)   │  │  (service/)       │
   └────────┬────────┘    └──────────┬──────────┘  └─────────┬─────────┘
            │                        │                        │
            ├──→ Model               ├──→ ScriptEngine        ├──→ Database
            ├──→ Theme               │    └──→ quickjs_bridge ├──→ Model
            ├──→ Util                ├──→ RuleParser
            ├──→ Database            ├──→ NetUtil
            └──→ Engine              ├──→ Model
                                     └──→ HtmlUtil
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
└─────────────────────────────────────────────────────────┘
```
