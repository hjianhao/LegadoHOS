# 本地书模块

阅读本地 EPUB/TXT/MOBI/PDF 文件。结构分为三层：导入层、解析层、阅读引擎层。

## 架构总览

```
用户导入
  └→ [BookshelfPage] 文件选择器
       ├→ copyToSandbox() 复制到沙箱 files/books/
       ├→ [EPUB] TaskPool: zlib.unzipFile() 解压到沙箱
       │          ZipExtractTask.ets (@Concurrent)
       └→ LocalBookEngine.importBooks()
             ├→ [EPUB] DirEpubParser.parse() 从目录解析
             ├→ [TXT]  TxtParser.parse()
             ├→ [MOBI] MobiParser.parse()
             └→ [PDF]  PdfParser.parse()
                   ↓
             BookTable.insertBook()      ← books 表
             ChapterTable.insertChapters() ← chapters 表（EPUB 不存 content）
                   ↓
书架 → continueRead()
  ├→ 小说引擎（默认）: ReadPage（Text 组件）
  │    ├→ 目录：DirEpubParser 实时从解压目录读取（不依赖 DB 缓存）
  │    └→ 内容：从解压目录读取 HTML → HtmlUtil.toPlainText() → 分页
  └→ 图文混排引擎（设置切换）: ReaderPage（WebView + EPUB.js）
```

---

## 导入流程

### BookshelfPage

`entry/src/main/ets/pages/BookshelfPage.ets`

**入口**: 用户选择文件后，BookshelfPage 处理导入：

1. 文件选择器返回 URI → 构造 `ImportFileItem[]`
2. `copyToSandbox(uri, fileName)` → 复制到 `files/books/` 沙箱
3. EPUB 文件：`TaskPool(@Concurrent) → zlib.unzipFile()` 解压到 `files/books/epub/{uuid}/`
4. `localBookEngine.importBooks()` 解析并入库

**解压使用 TaskPool 而非 Worker**：
- Worker 需要 EAWorker（引擎级工作线程），被 WebView 组件占用时无法创建
- TaskPool 的 `@Concurrent` 函数在池中执行，不需要 EAWorker
- `@Concurrent` 函数只能使用 import 变量和参数，不能调用同文件的其他函数

### LocalBookEngine

`entry/src/main/ets/engine/book/LocalBookEngine.ts`

**导入单本**: `importBook(filePath, context, epubDirArg?)`

步骤：
1. 根据扩展名选择解析器
2. EPUB：`DirEpubParser.parse(epubDir, skipContent=true)` 从解压目录解析
3. 解析结果为 `LocalBookMeta` + `BookChapter[]`
4. 写入 `books` 表（`origin='本地'`, `canUpdate=false`）
5. 写入 `chapters` 表
   - EPUB：`content` 字段留空（内容按需从文件读取）
   - 其他格式：`content` 全量写入（isCached=true）
6. 保存 `epubDir` 到 `book.tocUrl`（供阅读时定位解压文件）
7. 删除原始 `.epub` 文件（节省沙箱空间）

### EPUB 导入（核心路径）

```
EPUB 文件 (.epub = ZIP)
  → [TaskPool] zlib.unzipFile(filePath, targetDir, {})   解压到沙箱
  → DirEpubParser.parse(rootDir, skipContent=true)       从目录解析
```

**解压目录结构**（使用 UUID 目录名，避免文件名特殊字符问题）:
```
files/books/epub/{uuid}/
├── META-INF/container.xml
└── OEBPS/ (or OPS/)
    ├── package.opf          ← 元数据 + manifest + spine
    ├── toc.ncx              ← 目录（EPUB 2）
    ├── chapter*.xhtml       ← 章节内容
    ├── style.css
    └── images/
        └── cover.jpg
```

**UUID 目录名**：使用 `Date.now().toString(36) + Math.random().toString(36).slice(2, 8)` 生成，
避免使用文件名（含特殊字符、中文等）导致 `zlib.unzipFile` 路径校验失败。

### DirEpubParser

`entry/src/main/ets/engine/book/DirEpubParser.ts`

解析步骤：
1. 读 `META-INF/container.xml` → 提取 OPF 路径
2. 读 `package.opf`:
   - `parseOpfMeta_()` → 提取 title/author/description/cover
   - `parseManifest_()` → 构建 id→href 映射
   - `parseSpine_()` → spine 顺序的 ID 列表
3. 读 NCX（`toc.ncx`）:
   - 先按 `<spine toc="id">` 查找
   - 找不到时按 `media-type="application/x-dtbncx+xml"` 在 manifest 中查找
   - `parseNcxFlat_()` → 基于深度计数的 navPoint 解析，正确处理嵌套
   - 去重（按 href）+ spine 过滤（去掉卷级分组节点）
4. 方式 B：EPUB 3 nav.xhtml（manifest 中 `properties="nav"`）
   - `parseNav_()` → 只取顶级 `<ol>` 中的链接（去掉嵌套子节）
5. 兜底：从 spine 生成
6. 按 navMap + spine 合并提取正文：
   - EPUB 中一个章节（回）可能分布在多个 spine 文件
   - navMap 只指向该章节的第一个 spine 文件
   - 合并从 navPoint href 到下一个 navPoint href 之间所有 spine 的内容
   - 后续 spine 文件开头若重复章节标题则剥离（`skipContent=true` 时不处理内容）
7. 封面提取：`<meta name="cover" content="id"/>` → manifest 中找 href → 读取图片

**重要**: 章节顺序按 `spine`（线性阅读顺序），标题按 NCX/nav。

### ZipExtractTask.ets (@Concurrent)

`entry/src/main/ets/engine/book/ZipExtractTask.ets`

TaskPool 并发任务，在后台线程解压 EPUB：
- 使用 `zlib.unzipFile(filePath, targetDir, {})` 系统 API
- 自动处理 ZIP 格式解析和 DEFLATE 解压
- 执行前确保目标目录存在

---

## 阅读引擎

### 双引擎架构

```
EpubEngineConfig (engine/EpubEngineConfig.ets)
├── EpubEngineType.NOVEL = 0   ← 小说阅读（默认）
└── EpubEngineType.COMIC = 1   ← 图文混排（开发中）
```

**引擎切换**: 设置 → 阅读设置 → EPUB 阅读引擎（Radio）

### 小说引擎（当前）

**目录加载**（本地书）：
- 从 `book.tocUrl`（解压目录路径）创建 `DirEpubParser`
- 实时解析 OPF/NCX，不依赖 DB 缓存
- 解析结果缓存在 `ChapterCache`（内存），供 ChapterListPage 使用

**内容加载**：
- 优先从 `tocUrl + ch.url`（解压目录 + 章节相对路径）读取 HTML 文件
- DB 内容为空时（新导入）从文件读取
- `HtmlUtil.toPlainText()` 将 HTML 转为纯文本（自动去除 `<style>`/`<script>`/`<title>` 标签）
- 兜底：从 DB 读取（旧导入）

**阅读设置加载**：
- `aboutToAppear()` 中 `await loadSettings()` 完成后再加载内容
- 首次渲染直接使用用户配置的字体/段距/行高
- 避免默认值到目标值的闪烁和二次 layout

**预加载**：`preloadNextChapter_()` 提前读取下一章内容

流程:
```
书架点击 → continueRead()
  → ReadPage
  → aboutToAppear()
       → loadSettings() ← 等待设置加载
       → loadContent()
            → 本地书: DirEpubParser.parse(tocUrl) ← 从目录读章节列表
            → loadChapter(idx)
                 → fetchChapterContent_(idx)
                      → 读 tocUrl + ch.url（HTML 文件）
                      → HtmlUtil.toPlainText() → 纯文本
                 → layoutText(text) ← 首次即用用户配置
                 → PageView 显示
```

**章节排序**: `chapter_index` 即 spine 位置，DB 查询 `ORDER BY chapter_index ASC`。
ChapterListPage 的 `ensureAscendingOrder()` 对本地书（`origin='本地'`）跳过反转。

**内容按需读取**（不存 DB）：
- 导入时 `content` 留空，`url` 保存章节文件相对路径
- 阅读时从 `tocUrl/chapter.url` 读取 HTML → `toPlainText()`
- 内容缓存在 `this.text`（内存），切章或重新打开时读取文件
- 删除书籍时清理 `tocUrl` 目录

### 图文混排引擎（框架）

```
解压目录 → EpubServer（本地 HTTP 服务）
         → WebView 加载 reader.html
         → EPUB.js 通过 HTTP 读取 OPF，分页渲染
         → runJavaScript / WebMessagePort 双向通信
```

**未实现部分**:
- `EpubServer.ets`（HTTP 服务器，Socket API）
- `ReaderPage.ets`（WebView 阅读页）
- `reader.html`（EPUB.js 渲染页面）

---

## 数据库

### books 表

| 字段 | 说明 |
|------|------|
| `name` | 书名（来自 OPF dc:title） |
| `author` | 作者（来自 OPF dc:creator） |
| `cover_url` | 封面路径（`file://` + 封面沙箱路径） |
| `custom_cover_path` | 封面绝对路径 |
| `book_url` | 唯一标识 `local://<沙箱路径>` |
| `origin` | `'本地'`（`LOCAL_BOOK_ORIGIN`） |
| `origin_url` | EPUB 文件沙箱路径（导入后已删除） |
| `kind` | `'EPUB'` |
| `is_shelf` | 1（书架显示） |
| `can_update` | 0（本地书不更新） |
| `introduce` | 简介（stripHtml 后的纯文本） |
| `word_count` | 总字数 |
| `toc_url` | 解压目录路径（`files/books/epub/{uuid}/`），阅读时定位文件 |
| `custom_cover_path` | 封面沙箱路径 |

### chapters 表

| 字段 | 说明 |
|------|------|
| `book_id` | FK → books.id |
| `chapter_index` | spine 顺序索引 |
| `title` | 章节标题（来自 NCX/nav） |
| `url` | 章节文件相对路径（相对于解压目录，如 `OEBPS/Text/chapter1.xhtml`） |
| `content` | EPUB 留空，TXT/MOBI/PDF 为全文纯文本 |
| `content_length` | 0（EPUB） |
| `is_cached` | 1 |

**查询**: `ORDER BY chapter_index ASC`

---

## 关键文件

| 文件 | 说明 |
|------|------|
| `engine/book/LocalBookEngine.ts` | 导入引擎入口 |
| `engine/book/DirEpubParser.ts` | 目录解析器（从解压目录读取 OPF/NCX） |
| `engine/book/ZipExtractTask.ets` | TaskPool `@Concurrent` 解压任务 |
| `engine/book/EpubParser.ts` | **已废弃**（旧 ZIP 解析器） |
| `workers/ZipExtractWorker.ts` | **已移除**（改用 TaskPool） |
| `engine/EpubEngineConfig.ets` | 双引擎配置 |
| `util/ZipReader.ts` | ZIP 读取器（含 `@ohos.zlib` 原生解压） |
| `util/HtmlUtil.ts` | HTML 清洗（`toPlainText`/`stripHtml`） |
| `pages/ReadPage.ets` | 小说阅读页 |
| `pages/ReaderPage.ets` | 图文混排阅读页（框架） |
| `utils/EpubServer.ets` | HTTP 服务器（框架） |
| `pages/ChapterListPage.ets` | 章节目录列表 |
| `pages/BookshelfPage.ets` | 书架页（导入入口） |
| `components/BookCover.ets` | 封面组件（支持本地 `file://` 路径） |

---

## 已修复问题记录

| 问题 | 原因 | 修复 |
|------|------|------|
| container.xml 解析失败 | 用 `href` 而非 `full-path` 属性 | 改为同时匹配 `full-path` |
| 封面未提取 | 没用标准 `<meta name="cover">` | 优先按标准方式提取 |
| 简介含 HTML 标签 | `extractContentArea` 截断内容 | 改用 `toPlainText`（跳过正文定位） |
| 简介显示 CSS 代码 | HTML 实体 `&lt;style&gt;` 后解码 | 先解码实体再移除标签 |
| 章节内容空白 | NCX 仅指向单文件，内容跨多个 spine 文件 | 合并 spine 区间内容 |
| 章节排序错乱 | `ensureAscendingOrder` 误反转 | 本地书跳过反转（需传 `origin` 参数） |
| 封面 Image 不显示 | 绝对路径被当成资源路径 | 加 `file://` 前缀 |
| TextDecoder 类型 | `decodeToString` 需 `Uint8Array` | `new Uint8Array(buf)` 包装 |
| 章节导入慢 | 129 个章节逐个 INSERT | 改用 `batchInsert` |
| 多次导入不更新 | 命中"已导入"早期返回 | 改为删旧记录重新导入 |
| 导入报"非法参数" | 解压时空缓冲区写入 | `extractAll` 跳过空条目 + `byteLength > 0` 检查 |
| 主线程卡死 6s | 纯 JS DEFLATE 解压 227 条目 | `@ohos.zlib` 原生解压 + TaskPool 后台线程 |
| Worker 无法启动 | EAWorker 被 WebView 占满 | 改用 TaskPool（无需 EAWorker） |
| `zlib.decompressFile` 失败 900002 | NAPI 不支持负 windowBits；目录名含特殊字符 | 改用 `zlib.unzipFile`；UUID 目录名 |
| 100MB 书导入 ANR | `toPlainText` 处理全部 spine 内容 | `skipContent=true`，内容按需加载 |
| 目录缺章节 | NCX 嵌套 navPoint 的非贪婪 regex 吞内层节点 | 深度计数解析 + href 去重 + spine 过滤 |
| 目录顺序反转 | 导航未传 `origin` 参数，`ensureAscendingOrder` 误判 | 传 `origin` 参数 |
| 章节开头显示"未知" | `<title>` 标签未剥离 | `toPlainText` 移除 `<title>` |
| 风格调整卡顿 | 连续调整每次立即 layout | 200ms 防抖 |
| 打开书时样式闪烁 | `loadSettings` 异步，首次渲染用默认值 | `aboutToAppear` 中 await 设置完成再加载内容 |
| 导入进度显示乱码 | picker URI 未 decode | `decodeURIComponent()` |

---

## 设计决策

### 为什么用 TaskPool 而不是 Worker？

- Worker 创建时需要 EAWorker（引擎级工作线程）
- WebView 组件占用 EAWorker 名额，导致后续 Worker 创建失败
- TaskPool 使用预创建的线程池，不消耗 EAWorker
- `@Concurrent` 函数限制：不能调用同文件的其他函数、只能使用 import 和参数

### 为什么内容不存数据库？

- EPUB 内容已解压到目录，按需读取更灵活
- DB 体积更小，导入更快
- 修改解析逻辑后无需重新导入（目录和内容都实时读取）
- 支持图文混排引擎直接使用原始 HTML

### 为什么用 UUID 目录名？

- 避免文件名中的特殊字符（中文、空格、括号、逗号等）导致 `zlib.unzipFile` 路径校验失败
- 每本书独立目录，互不干扰
- 目录名与内容无关，删除书时可安全清理

---

## 下一步工作

### P0 - 小说引擎调优

- [ ] 大章节风格调整性能优化（拆分合并的 spine 或缓存 layout 结果）
- [ ] 删除书籍时递归清理解压目录

### P1 - 图文混排引擎开发

- [ ] **EpubServer**：实现 TCP Socket HTTP 服务器
- [ ] **ReaderPage**：WebView 加载 `reader.html`，EPUB.js 通过 HTTP 加载 OPF
- [ ] **双向通信**：翻页/目录/设置通过 `runJavaScript` + `WebMessagePort`

### P2 - 清理

- [ ] **移除旧代码**：`EpubParser.ts` 和 `EpubJS相关` 文件
- [ ] **ZipReader**：保留 `extractAll` 方法
- [ ] **workers/ZipExtractWorker.ts**：已移除，确认 build-profile 中无残留
