# 云端书籍 · 阶段 0 基线确认

> 状态：已完成  
> 日期：2026-07-23  
> 对应设计：`doc/modules/cloudbook.md` 第 18 节「阶段 0」  
> 目标：确认本地书、WebDAV、数据库与备份现状，为阶段 1+ 迁移提供可回归基线。  
> 本阶段**无功能代码改动**，仅文档与构建记录。

---

## 0. 结论摘要

| 领域 | 结论 |
|---|---|
| WebDAV | 备份与进度同步能力可用；**不能直接当云端书库 Provider**。需下沉共享网络/认证工具，并另写保留目录的 PROPFIND 解析与大文件流式传输。 |
| 本地书导入 | 公开入口清晰；云端下载落地后应走 `copy/import` + EPUB 预解压；清理必须走 `BookDeleter`，不在 `BookTable.deleteBook` 里发网。 |
| 数据库 | 幂等 `CREATE TABLE IF NOT EXISTS` + 可重试 `ALTER TABLE`；新表按同样方式注册，不依赖 `DATABASE_VERSION` 作为唯一迁移手段。 |
| 凭证 | 备份 WebDAV 密码走 `SettingsStore` 加密键 `webdav_pwd`（另有 PersistentStorage 明文兼容）；云端书库需**多来源命名空间**，不可复用单例配置。 |
| 构建 | debug 构建通过（见第 5 节）。工作区有未提交改动，阶段 0 **未触碰**这些文件。 |

---

## 1. WebDAV 协议复用清单

源文件：`entry/src/main/ets/service/WebDavService.ts`（约 750 行）  
调用方：`BackupService`、进度同步相关流程。  
网络底层：`entry/src/main/ets/util/NetUtil.ts`（RCP session 池 + 自定义方法）。

### 1.1 现有能力地图

| 能力 | 方法 | 实现要点 | 备份/进度是否依赖 |
|---|---|---|---|
| 配置单例 | `configure` / `initFromStorage` / `getConfig` / `isConfigured` | **全局唯一** `WebDavConfig`：`serverUrl` + `path` + 用户名密码 | 是 |
| 连接测试 | `testConnection` | `OPTIONS` + Basic Auth，失败返回 `false`（不抛细分错误） | 是 |
| 目录列举 | `listFiles(path)` | `PROPFIND Depth:1` + `allprop`；失败时 **吞异常返回 []** | 是（备份列表） |
| 进度目录列举 | `listProgressFiles_` | 同样 PROPFIND，但 **失败抛错**，供批量进度退化为逐本 GET | 是 |
| 备份列表/存在性 | `listBackups` / `hasBackup` / `lastBackup` | 过滤 `backup*` 名，按 `lastModified` 排序 | 是 |
| 二进制上传 | `uploadBackupFile` | 独立 RCP Session；`PUT` + `ArrayBuffer`；`Overwrite: T` | 是 |
| 读本地上传字节 | `readFileBytes` | **整文件读入** `ArrayBuffer` | 是 |
| 目录创建 | `ensureDirectory` | 相对 `serverUrl` 逐级 `MKCOL`（含 config.path 段） | 是 |
| 二进制下载 | `downloadBackup` | 独立 RCP Session；`GET` 后整包写临时文件 | 是 |
| 删除 | `deleteBackup` | `DELETE`，失败忽略 | 是 |
| 进度 JSON 上下传 | `uploadBookProgress` / `downloadBookProgress` / `downloadAllBookProgress` | 文本 PUT/GET；业务冲突解决在本地 | 是 |
| URL 拼接 | `normalizeUrl` | `serverUrl` + 固定 `path` + 相对 path | 是 |
| Basic Auth | `getAuthHeader` + `base64Encode` | `username:password` → Base64 | 是 |
| PROPFIND 解析 | `parsePropfindResponse` | 正则解析 response/href/collection/lastmodified/contentlength | 是 |
| HTML 列表备选 | `parseHtmlListing` | 存在但当前主路径未调用 | 否（死代码级） |

### 1.2 可下沉为共享工具（建议新模块）

下列能力与「备份业务语义」无关，适合抽到例如 `service/cloud/WebDavHttp.ts` 或 `util/WebDavClientCore.ts`，供 **备份 WebDavService** 与 **WebDavCloudProvider** 共用：

| 共享项 | 现状位置 | 下沉时注意 |
|---|---|---|
| Basic Auth 头生成 | `getAuthHeader` / `base64Encode` | 凭证由调用方传入，不要绑单例 config |
| 自定义方法请求 | `NetUtil.httpCustomMethod`（OPTIONS/PROPFIND/MKCOL/DELETE） | 已可用；Provider 应直接依赖 NetUtil 或薄封装 |
| 文本 PUT/GET | `NetUtil.httpPut` / `httpGet` | 进度 JSON 继续用；书籍文件不用文本 API |
| 独立 RCP 二进制 Session | `uploadBackupFile` / `downloadBackup` 内联 | 提取 `putBinary` / `getBinaryToFile`，统一超时与 session close |
| 路径段拼接与去斜杠 | `normalizeUrl` 片段逻辑 | 云端书库需 `endpoint + rootPath + remotePath`，语义与备份 `path` 不同 |
| lastModified 解析 | `parseLastModifiedMs_` | 可复用为 `CloudFile.modifiedAt` |
| PROPFIND XML 块解析（底层） | `parsePropfindResponse` 中正则提取字段 | **必须改造过滤策略**后再复用（见 1.3） |
| 中文 URL 编码 | `NetUtil.normalizeUrl` 对非 ASCII 编码 | Provider 路径编码应与此一致 |

### 1.3 必须保持备份兼容、不可原样复用的部分

| 项 | 原因 | 云端书库应如何做 |
|---|---|---|
| 全局单例 `WebDavConfig` + `webdav_*` PersistentStorage | 备份/进度只有一套账户；云端书库要多来源 | 独立 `cloud_sources` + `credential_ref` |
| `path` 固定根（默认 `legado`） | 备份文件落在该目录 | 每来源独立 `rootPath`，进入来源时 `list('')` |
| `parsePropfindResponse` **过滤全部目录**（末尾 `!f.isDirectory`） | 备份只需 zip 文件列表 | **必须保留目录**；自条目（Depth 0 自身）单独剔除 |
| `listFiles` 失败返回 `[]` | 备份 UI 可接受空列表 | 浏览层需要可区分「认证失败 / 网络错误 / 空目录」 |
| `testConnection` 只返回 boolean | 设置页简单提示 | 需可理解错误（401/403/超时/根目录不存在） |
| 整文件 `ArrayBuffer` 上传/下载 | 备份 zip 通常可接受 | 书籍大文件须流式/`downloadToFile`，禁止整本常驻内存（设计 16.2） |
| 硬编码临时路径 `/data/storage/el2/base/haps/entry/files/restore_*` | 备份恢复专用 | 使用 `files/cloudbook/.tmp/<taskId>.part` |
| 业务方法（`listBackups`、`uploadBookProgress`…） | 备份/进度领域 | **禁止**写入 CloudProvider；`WebDavService` 继续只服务备份与进度 |

### 1.4 协议行为与已知坑

1. **坚果云 PROPFIND**：注释明确存在客户端/解析限制；进度同步已做「列表失败 → 逐本 GET」兜底。云端书库浏览依赖 PROPFIND，需在阶段 2 真机测坚果云/Nextcloud。  
2. **href 形态**：解析已支持绝对 URL 截路径 + `decodeURIComponent`；**尚未**把 href 收敛为相对 `rootPath` 的 `remotePath`，也未校验「是否仍在来源边界内」。  
3. **etag**：当前 PROPFIND 解析**不提取** `getetag`；更新检查阶段 5 需要补齐。  
4. **MKCOL**：`ensureDirectory` 忽略失败（含已存在）；云端书库「创建目录」应作为可选 Capability，且默认**不自动创建 rootPath**。  
5. **密码存储双轨**：`SettingsStore.webdav_pwd`（加密）+ 历史 `AppStorage.webdav_password`（明文兼容迁移）。云端书库凭证应参考 `LoginInfoStore`/加密 Preferences 模式做 **多 ref**，禁止塞进现有单键。  
6. **User-Agent**：`NetUtil.buildHeaders` 默认浏览器 UA；Basic Auth 通过自定义头覆盖。跨主机重定向时设计要求剥离 Authorization——当前 NetUtil **未实现**该安全策略，阶段 2/6 需评估。

### 1.5 建议抽取边界（阶段 1–2 实施时遵守）

```text
NetUtil（已有）
  └─ 通用 HTTP/RCP

WebDavHttp / 共享工具（新建，无业务）
  ├─ basicAuthHeader(username, secret)
  ├─ propfind(url, depth, auth) → raw XML 或 原始条目
  ├─ parsePropfindEntries(xml) → 含目录、etag、size、modified
  ├─ putBinary / getBinaryToFile / mkcol / delete
  └─ joinUrl(endpoint, ...segments) + encodePath

WebDavService（保留，备份/进度）
  └─ 继续使用共享工具，但 API 与配置模型不变

WebDavCloudProvider（新建，云端书库）
  └─ 实现 CloudStorageProvider；独立来源 config；list 保留目录
```

**验收对照（设计阶段 0）**：已明确哪些可下沉、哪些必须保持备份兼容 —— 本清单即交付物。

---

## 2. 本地导入契约（LocalBookEngine）

源文件：

- `entry/src/main/ets/engine/book/LocalBookEngine.ts`
- `entry/src/main/ets/service/BookDeleter.ets`
- 调用编排：`entry/src/main/ets/pages/BookshelfPage.ets`（`importLocalBookUris`）
- 设计参考：`doc/modules/localbook.md`

### 2.1 支持格式

| 扩展名 | parser | 导入行为摘要 |
|---|---|---|
| `.txt` | `txt` | `TxtParser.parse`；章节 content 不入库（stream）；写 `charset` |
| `.epub` | `epub` | **调用方必须先解压**；`DirEpubParser(skipContent=true)`；`tocUrl` = 解压目录；封面拷到 `books/covers/` |
| `.mobi` / `.azw` / `.azw3` | `mobi` | `MobiProbeParser.probe` 轻量探测；单章占位；正文由阅读引擎按需解析 |
| `.pdf` | `pdf` | 轻量 header 探测 + 单章「PDF」；渲染交给 PDF.js WebView |

不支持扩展名 → `ImportResult.success=false`，`error: 不支持的文件格式`。

### 2.2 公开 API（云端模块只允许依赖这些）

| API | 签名要点 | 用途 |
|---|---|---|
| `localBookEngine.importBook` | `(filePath, context?, epubDirArg?) → ImportResult` | 单文件已在沙箱路径上的解析入库 |
| `localBookEngine.importBooks` | `(ImportFileItem[], context?, onProgress?) → BatchImportResult` | 批量；item 的 `uri` 实为沙箱路径 |
| `localBookEngine.copyToSandbox` | `(uri, fileName, context?) → string` | picker URI → `files/books/<safeName>` |
| `LocalBookEngine.getEpubDir` | `(context?) → string` | 生成 `files/books/epub/<id>` |
| `LocalBookEngine.isLocalBook` | `(book) → boolean` | `origin === '本地'` |
| `localBookEngine` 单例 | — | 全局实例 |
| `LOCAL_BOOK_ORIGIN` | `'本地'` | 写入 `Book.origin` |
| `ImportResult` | `success, bookId, bookName, chapterCount, error?` | 成功时 **bookId 可用** |
| `BookDeleter.deleteBook` / `deleteBooks` | 彻底清理 DB + 本地文件 | 失败补偿、删除本地书 |

**禁止**：云端模块复制 Parser 逻辑、直接操作 `DirEpubParser`/`TxtParser` 入库、在 `BookTable.deleteBook` 内发起网络删除。

### 2.3 成功导入后的 Book 字段（与云端设计一致）

| 字段 | 值 |
|---|---|
| `bookUrl` | `local://<绝对沙箱路径>` |
| `origin` | `本地`（`LOCAL_BOOK_ORIGIN`） |
| `originUrl` | 沙箱文件绝对路径 |
| `tocUrl` | EPUB 为解压目录；其他多为 `''` |
| `isShelf` | `true` |
| `canUpdate` | `false` |
| `kind` | 扩展名大写（`TXT`/`EPUB`/…） |
| `customCoverPath` / `coverUrl` | EPUB 封面本地路径；否则可空 |

同 `bookUrl` 已存在时：`importBook` 会先删旧章节与旧 Book 再插入（**不**经 `BookDeleter`，可能残留旧 epub 解压目录——云端「从云端更新」应走设计 14.5 的显式迁移，不宜依赖该隐式 re-import 副作用）。

### 2.4 当前本地导入流水线（BookshelfPage）

```text
uris
  → copyToSandbox(uri, fileName)          // 得到 sandboxPath
  → 若 .epub：getEpubDir + taskpool extractZipConcurrent(sandboxPath, epubDir)
  → importBooks([{ uri: sandboxPath, fileName, epubDir }])
       → importBook(sandboxPath, context, epubDir)
```

云端下载导入应对齐为：

```text
Provider.downloadToFile → 临时 .part
  → 校验 → 原子移动到 files/books/cloud_<sourceId>_<hash>_<safeName>
  → 若 EPUB：解压到 getEpubDir()
  → importBook(finalPath, context, epubDir?)
  → Binding 事务绑定 bookId
失败 → 删临时/最终文件；若已入库则 BookDeleter.deleteBook；Binding=ERROR
```

### 2.5 清理契约（BookDeleter）

对本地书会删除：

1. chapters / ai_book_profiles / bookmarks / read_records  
2. books 行  
3. `originUrl` 文件、`tocUrl` 目录、`customCoverPath` 封面  
4. 漫画缓存与封面缓存  

**不删除**：任何云端远端文件（正确；云端 Binding 协调在 Repository 层，阶段 4/5 接入）。

### 2.6 与 localbook.md 的偏差（实现为准）

| 文档说法 | 代码实际 |
|---|---|
| 导入后删除原始 `.epub` 节省空间 | **保留**原始 epub 与解压目录（注释：多阅读引擎复用） |
| 非 EPUB 章节 content 全量入库 | TXT 的 content 也留空（stream）；MOBI/PDF 为占位章 |

云端模块以**代码行为**为准。

### 2.7 失败行为

| 场景 | 结果 |
|---|---|
| 不支持格式 | `success=false`，无 Book |
| 章节数为 0 | `success=false`，`未解析到任何章节` |
| 解析抛错 | catch 后 `success=false`，`error` 为消息 |
| `copyToSandbox` 失败 | 抛错，由上层捕获 |
| EPUB 未传 `epubDir` 且无 context | 可能生成错误解压路径或抛 Missing context |

**验收对照**：云端模块只调用公开导入/清理入口，不复制解析逻辑 —— 契约如上。

---

## 3. 数据库与备份相关基线

### 3.1 AppDatabase

- 文件：`entry/src/main/ets/data/database/AppDatabase.ts`
- `DATABASE_VERSION = 1` 几乎不驱动迁移
- 启动时对所有表 `CREATE TABLE IF NOT EXISTS`
- 新列：`try { ALTER TABLE ... ADD COLUMN } catch { /* 已存在 */ }`
- 阶段 1 应：注册 `cloud_sources`、`cloud_book_bindings` SQL + DAO getter，**不改 books 表语义**

### 3.2 备份

- `BackupService` + `service/backup/BackupCodec.ts` 等
- WebDAV 备份调用 `WebDavService.uploadBackupFile` / `downloadBackup`
- 阶段 6 才集成：备份**仅**导出 `cloud_sources` 非敏感字段；凭证恢复后提示重填
- 阶段 0 **不修改** BackupCodec

### 3.3 凭证基线

| 用途 | 存储 | 键 |
|---|---|---|
| 备份 WebDAV 密码 | SettingsStore 加密 | `webdav_pwd` |
| 兼容明文 | PersistentStorage | `webdav_password` |
| 书源登录 | LoginInfoStore + Asset | 按 sourceUrl |
| AI Key 等 | SettingsStore 加密 | 各自键 |

云端书库：`credential_ref` → 多来源密钥（阶段 1 新建 `CloudCredentialStore` 或扩展 SettingsStore 命名空间）。

---

## 4. 测试 WebDAV 来源与场景清单

> 阶段 0 交付「测试来源规划」，真机连接在阶段 2 验收。  
> 本地可在 `tmp/cloudbook-test-sources.local.json` 填写真实账号（**已加入忽略建议，勿提交仓库**）。

### 4.1 建议至少准备的来源拓扑

| ID | 用途 | endpoint 示例 | rootPath | 覆盖点 |
|---|---|---|---|---|
| A | 坚果云书库根 | `https://dav.jianguoyun.com/dav/` | `LegadoBooks` 或用户自建目录 | 商用 WebDAV、中文目录、认证 |
| B | 同一 endpoint 不同根 | 同上 | `LegadoBooks/归档` 或另一顶层目录 | **同 endpoint 多 rootPath 隔离** |
| C | Nextcloud/ownCloud | `https://cloud.example/remote.php/dav/files/<user>/` | `Reading` 或 `''` | 绝对 href、collection 后缀 `/` |
| D | 空 rootPath | 任意自建 | `''` | 直接列 endpoint 根 |
| E | 错误凭证 | 任意 | 任意 | 401/403 不污染旧配置 |

最低要求（设计验收）：**A + B**（两个不同 rootPath），或 **A + C**。

### 4.2 远端目录建议布局（在测试网盘中手工准备）

```text
{rootPath}/
  三体.epub
  样例.txt
  手册.pdf
  嵌套/
    同名.epub          ← 与其它目录同名文件
    中文 空格/
      测试书.epub
  不支持/
    notes.md           ← 可列出但不可加入书架
```

另一来源 rootPath 下放置**同名** `三体.epub`（内容可不同），用于验证 Binding 不按文件名串源。

### 4.3 场景矩阵（与设计第 9 节对齐，阶段 2–5 逐步勾选）

| # | 场景 | 预期 | 目标阶段 |
|---|---|---|---|
| T1 | 两来源不同 rootPath | 列表内容不串、凭证不串 | 2 |
| T2 | rootPath 为空 | 列出 endpoint 根 | 2 |
| T3 | 中文/空格/编码路径 | 进入、下载路径正确 | 2–4 |
| T4 | 同名不同来源 | 状态独立 | 3–4 |
| T5 | 未下载 | 仅云端页「云端」，不在书架 | 3 |
| T6 | 下载 EPUB/TXT/PDF | 本地书可离线开 | 4 |
| T7 | 取消/断网 | 无半文件/孤儿 Book | 4 |
| T8 | 401 密码错误 | 明确错误，旧配置保留 | 2 |
| T9 | 上传覆盖确认 | 本地属性不变 | 5 |
| T10 | 远端更新 | 仅标记可更新 | 5 |
| T11 | 删除来源 | 本地书保留 | 5 |

### 4.4 本地占位配置模板

路径：`tmp/cloudbook-test-sources.local.json.example`（可复制为 `.local.json`）。

```json
{
  "sources": [
    {
      "id": "A",
      "name": "坚果云-书库",
      "providerType": "webdav",
      "endpoint": "https://dav.jianguoyun.com/dav/",
      "rootPath": "LegadoBooks",
      "username": "<fill>",
      "password": "<fill>"
    },
    {
      "id": "B",
      "name": "坚果云-归档",
      "providerType": "webdav",
      "endpoint": "https://dav.jianguoyun.com/dav/",
      "rootPath": "LegadoBooks/归档",
      "username": "<fill>",
      "password": "<fill>"
    }
  ],
  "notes": "勿提交含真实密码的 .local.json；仅供阶段 2+ 手工/调试使用"
}
```

---

## 5. 构建与工作区基线

### 5.1 记录时刻

- 日期时间：2026-07-23 09:15（本地）
- Git HEAD：`f90f880eb8b740bb4d5389dd650f72c5cde49c6d`
- 提交说明：`修复 WebDAV 密码不持久化：改用 @StorageLink 替代加密 SettingsStore`
- 分支：`main`（相对 `origin/main` 超前，以当时 `git status` 为准）

### 5.2 构建结果

```text
命令：./scripts/build.sh debug
结果：BUILD SUCCESSFUL
日志：tmp/cloudbook-phase0-build-baseline.log
```

Hvigor 关键步骤均为 Finished / UP-TO-DATE；构建脚本随后执行了 `codegraph sync`。

### 5.3 工作区状态（阶段 0 开始时快照）

**未提交修改（阶段 0 未改这些文件）：**

- `doc/modules/sync.md`
- `entry/src/main/ets/MainAbility/MainAbility.ets`
- `entry/src/main/ets/engine/source/SourceExecutor.ts`
- `entry/src/main/ets/pages/BackupSettingsPage.ets`
- `entry/src/main/ets/pages/BookInfoPage.ets`
- `entry/src/main/ets/pages/BookshelfPage.ets`
- `entry/src/main/ets/pages/ChapterListPage.ets`
- `entry/src/main/ets/pages/ReadPage.ets`
- `entry/src/main/ets/service/BackupService.ts`
- `entry/src/main/ets/service/BookSourceResolver.ts`
- `entry/src/main/ets/service/WebDavService.ts`

**未跟踪：**

- `doc/modules/cloudbook.md`（设计文档）
- `entry/src/main/ets/service/backup/`（备份子模块重构产物，与同步设计相关）

阶段 1 开始前建议：由用户决定是否先提交当前备份/同步相关改动，再拉 `feat/cloudbook` 分支，避免云端书库与未验证备份改动缠在一起。

### 5.4 阶段 0 自身产出文件

| 路径 | 说明 |
|---|---|
| `doc/modules/cloudbook-phase0-baseline.md` | 本文档 |
| `tmp/cloudbook-phase0-build-baseline.log` | debug 构建日志 |
| `tmp/cloudbook-test-sources.local.json.example` | 测试来源模板 |

---

## 6. 进入阶段 1 的前置检查表

- [x] WebDAV 复用/不可复用边界已文档化  
- [x] LocalBookEngine / BookDeleter 公开契约已文档化  
- [x] 测试来源拓扑与场景矩阵已准备  
- [x] debug 构建基线通过  
- [ ] （建议）提交或隔离当前工作区未完成备份改动  
- [ ] （建议）准备好至少两个可连的 WebDAV rootPath  
- [ ] 阶段 1：落地模型、表、DAO、凭证命名空间（仍无云端 UI）

### 阶段 1 实现时优先注意

1. **不要**改 `WebDavService.parsePropfindResponse` 的过滤行为来「顺便」支持目录——会破坏备份列表语义；应在共享解析层用参数或新函数保留目录。  
2. **不要**给 `books` 表加 webdav 字段。  
3. EPUB 云端导入必须在 Repository 编排解压，再调 `importBook`。  
4. 大文件传输不要复制 `readFileBytes` 整读模式。  
5. 删除本地书扩展点挂在 `BookDeleter` 之前的 Repository 协调，而非 `BookTable`。

---

## 7. 关键符号速查

| 符号 | 文件 |
|---|---|
| `WebDavService` | `entry/src/main/ets/service/WebDavService.ts` |
| `NetUtil.httpCustomMethod` / `httpGetBinary` | `entry/src/main/ets/util/NetUtil.ts` |
| `LocalBookEngine` / `localBookEngine` | `entry/src/main/ets/engine/book/LocalBookEngine.ts` |
| `BookDeleter` | `entry/src/main/ets/service/BookDeleter.ets` |
| `extractZipConcurrent` | `entry/src/main/ets/engine/book/ZipExtractTask.ets` |
| `AppDatabase.doInit` | `entry/src/main/ets/data/database/AppDatabase.ts` |
| `SettingsStore.getWebDavPassword` | `entry/src/main/ets/data/preferences/SettingsStore.ts` |
| `BackupService` | `entry/src/main/ets/service/BackupService.ts` |
| `BackupCodec` | `entry/src/main/ets/service/backup/BackupCodec.ts` |
