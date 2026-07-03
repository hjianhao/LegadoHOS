# 备份与同步模块设计

> 目标：沉淀 Android 版 Legado 备份/恢复和 WebDAV 同步的产品规格，并对照当前 LegadoHOS 鸿蒙实现，明确已实现、部分实现和未实现范围。
> 更新日期：2026-07-03

---

## 1. 范围与术语

本文档覆盖"数据备份与恢复"主流程，即从设置页进入备份/恢复功能，包括本地文件备份（ZIP）、WebDAV 云端备份、阅读进度同步，以及 Web 远程管理。

Android 参考实现来自 `/Users/hjianhao/code/ai/legado-with-MD3`：

| 模块 | 文件 |
|------|------|
| 备份引擎 | `app/src/main/java/io/legado/app/help/storage/Backup.kt` |
| 恢复引擎 | `app/src/main/java/io/legado/app/help/storage/Restore.kt` |
| 备份配置/忽略策略 | `app/src/main/java/io/legado/app/help/storage/BackupConfig.kt` |
| 加密工具 | `app/src/main/java/io/legado/app/help/storage/BackupAES.kt` |
| 互斥锁 | `app/src/main/java/io/legado/app/help/storage/BackupRestoreLock.kt` |
| WebDAV 客户端 | `app/src/main/java/io/legado/app/lib/webdav/WebDav.kt` |
| WebDAV 文件模型 | `app/src/main/java/io/legado/app/lib/webdav/WebDavFile.kt` |
| WebDAV 授权 | `app/src/main/java/io/legado/app/lib/webdav/Authorization.kt` |
| WebDAV 异常 | `app/src/main/java/io/legado/app/lib/webdav/WebDavException.kt` |
| WebDAV 管理器 | `app/src/main/java/io/legado/app/help/AppWebDav.kt` |
| WebDAV 新版管理器 | `app/src/main/java/io/legado/app/help/WebDavManager.kt` |
| WebDAV 领域网关 | `app/src/main/java/io/legado/app/domain/gateway/WebDavBackupGateway.kt` |
| WebDAV 用例层 | `app/src/main/java/io/legado/app/domain/usecase/WebDavBackupUseCase.kt` |
| WebDAV 领域模型 | `app/src/main/java/io/legado/app/domain/model/WebDavBackup.kt` |
| WebDAV 数据仓库 | `app/src/main/java/io/legado/app/data/repository/WebDavBackupRepository.kt` |
| 备份设置 UI | `app/src/main/java/io/legado/app/ui/config/backupConfig/BackupConfigScreen.kt` |
| 备份设置 ViewModel | `app/src/main/java/io/legado/app/ui/config/backupConfig/BackupConfigViewModel.kt` |
| 备份配置 UI 层 | `app/src/main/java/io/legado/app/ui/config/backupConfig/BackupConfig.kt` |
| WebDAV 欢迎页 | `app/src/main/java/io/legado/app/ui/welcome/WebDavFragment.kt` |
| Web 远程管理 | `app/src/main/java/io/legado/app/help/WebService.kt` |

鸿蒙当前实现来自 LegadoHOS：

| 模块 | 文件 |
|------|------|
| 备份/恢复服务 | `entry/src/main/ets/service/BackupService.ts` |
| WebDAV 服务 | `entry/src/main/ets/service/WebDavService.ts` |
| 设置存储 | `entry/src/main/ets/data/preferences/SettingsStore.ts` |
| ZIP 写入器 | `entry/src/main/ets/util/ZipWriter.ts` |
| ZIP 读取器 | `entry/src/main/ets/util/ZipReader.ts` |
| 备份设置页面 | `entry/src/main/ets/pages/BackupSettingsPage.ets` |
| 设置页面入口 | `entry/src/main/ets/pages/SettingsPage.ets` |
| Web 远程管理 | `entry/src/main/ets/engine/web/WebServer.ts` |

状态标注：

| 状态 | 含义 |
|------|------|
| 已实现 | 鸿蒙版已经具备可用功能，行为与 Android 基本对齐 |
| 部分实现 | 鸿蒙版已有主体能力，但交互、持久化、边界处理或排序策略与 Android 有差距 |
| 未实现 | 当前鸿蒙版没有对应能力 |

---

## 2. 产品目标

备份/恢复模块是阅读 App 的"数据保险箱"。它需要同时承担：

1. 完整导出书架书籍、阅读进度、书源、替换规则、RSS、书签等所有用户数据。
2. 支持 ZIP 打包为标准备份文件，兼容 Android Legado 备份格式。
3. 提供本地文件备份（通过系统文件选择器保存/加载）。
4. 提供 WebDAV 云端备份（上传/下载/列表/删除）。
5. 支持 WebDAV 阅读进度双向同步。
6. 提供 AES 加密保护敏感数据（WebDAV 密码等）。
7. 支持恢复时选择性忽略部分数据类型。
8. 提供 Web 远程管理界面（通过浏览器管理书架/书源/搜索）。

---

## 3. 规格差距总表

### 3.1 本地备份

| # | 规格 | Android 行为 | 鸿蒙当前状态 | 差距说明 |
|---|------|--------------|--------------|----------|
| B-001 | 导出数据类型 | 20+ 种数据：bookshelf、bookSource、replaceRule、rssSources、rssStar、rssArticles、bookmark、readRecord、searchHistory、ruleSub、txtTocRule、httpTTS、dictRule、servers(AES)、config.xml | 已实现 | 鸿蒙导出 books、bookmarks、book_groups、book_sources、replace_rules、rss_sources、rss_stars、rss_read_records、read_records、read_record_details、search_history、txt_toc_rules、book_sources_cache + settings |
| B-002 | 备份文件格式 | ZIP 打包（兼容 GSON 序列化的 JSON 数组文件 + config.xml） | 已实现 | ZIP（STORED 模式）+ backup.json（JSON），无 config.xml |
| B-003 | 本地保存 | content URI / SAF（DocumentFile）写入 | 已实现 | `DocumentViewPicker.save()` |
| B-004 | 本地加载 | content URI / SAF（DocumentFile）读取，支持 ZIP 解压 | 已实现 | `DocumentViewPicker.select()` → `ZipReader` 解压 |
| B-005 | 备份文件名 | `backup{yyyy-MM-dd}-{deviceName}.zip` 或 `backup.zip`（最新） | 部分实现 | `backup_{yyyy-MM-dd}.zip`，无设备名 |
| B-006 | AES 加密 | WebDAV 密码等敏感字段使用用户本地密码的 MD5 前 16 位作为 AES 密钥加密 | 未实现 | 鸿蒙明文存储 WebDAV 密码 |

### 3.2 WebDAV 备份

| # | 规格 | Android 行为 | 鸿蒙当前状态 | 差距说明 |
|---|------|--------------|--------------|----------|
| W-001 | PROPFIND 列表 | 解析 XML 响应获取文件/目录列表 | 已实现 | `parsePropfindResponse()` XML 正则解析 |
| W-002 | MKCOL 创建目录 | 创建远程目录 | 已实现 | `ensureDirectory()` |
| W-003 | PUT 上传 | 上传 ZIP 文件 | 已实现 | `uploadBackupZip()` |
| W-004 | GET 下载 | 下载到本地文件 | 已实现 | `downloadBackup()` |
| W-005 | DELETE 删除 | 删除远程文件 | 已实现 | `deleteBackup()` |
| W-006 | Basic Auth | HTTP Basic 认证（base64） | 已实现 | `getAuthHeader()` |
| W-007 | 云端备份列表 | 列出 webdav 目录下所有 `.zip` 文件 | 已实现 | `listBackups()` |
| W-008 | 云端备份恢复 | 下载备份 → 解压 → 恢复 | 已实现 | `BackupService.restoreFromWebDav()` |
| W-009 | 备份目录结构 | `{root}/legado/backup*.zip` | 已实现 | `BACKUP_DIR = 'legado'` |
| W-010 | 阅读进度上传 | 上传 `progress_{name}_{author}.json` | 已实现 | `uploadBookProgress()` |
| W-011 | 阅读进度下载 | 下载单书进度 | 已实现 | `downloadBookProgress()` |
| W-012 | 全量进度同步 | 遍历所有书籍双向合并（时间戳/进度对比） | 已实现 | `syncAllProgress()` |
| W-013 | 背景图同步 | 上传/下载阅读背景图片 | 未实现 | 鸿蒙无阅读背景同步 |
| W-014 | 远程书籍同步 | 通过 WebDAV 管理远程书籍 | 未实现 | Android 有 `RemoteBookWebDav` |
| W-015 | 自动备份 | 启动时/进入阅读时检查距上次备份是否超过 24 小时，自动触发 | 未实现 | 鸿蒙无自动备份触发机制 |
| W-016 | 备份模式选择 | local / webdav / both / remote / disabled | 未实现 | 鸿蒙手动触发，无模式持久化 |
| W-017 | 测试连接 | PROPFIND 根目录，检查 401 | 已实现 | `testConnection()` |
| W-018 | 仅保留最新备份 | 开关控制只保留最新一份备份 | 未实现 | 鸿蒙每次都生成新文件 |

### 3.3 恢复流程

| # | 规格 | Android 行为 | 鸿蒙当前状态 | 差距说明 |
|---|------|--------------|--------------|----------|
| R-001 | 导入书籍 | 按 `bookUrl` 判重，存在则 UPDATE，不存在则 INSERT | 已实现 | `books` 表直接 `rdb.insert()` |
| R-002 | 导入书源 | 按 `sourceUrl` 判重 | 已实现 | 直插 `book_sources` 表 |
| R-003 | 导入替换规则 | 直接插入 | 已实现 | 直插 `replace_rules` 表 |
| R-004 | 导入设置 | 解析 config.xml（XML Pull Parser），写入 SharedPreferences + DataStore | 部分实现 | 鸿蒙通过 `SettingsStore.importAll()` 写入 Preferences，无 XML 格式 |
| R-005 | 恢复忽略设置 | 可跳过 readConfig/themeMode/themeConfig/coverConfig/bookshelfLayout/showRss/threadCount/localBook | 未实现 | 鸿蒙无恢复忽略 UI |
| R-006 | 互斥锁 | 协程 Mutex 防止并发备份/恢复 | 未实现 | 鸿蒙无并发保护 |

### 3.4 备份设置 UI

| # | 规格 | Android 行为 | 鸿蒙当前状态 | 差距说明 |
|---|------|--------------|--------------|----------|
| U-001 | WebDAV 配置区域 | 服务器 URL、账号、密码、子目录、设备名 | 已实现 | 鸿蒙有 URL/账号/密码/路径/自动同步 |
| U-002 | 测试连接按钮 | 显示连接成功/失败 | 已实现 | `testConnection()` |
| U-003 | 手动备份 | 底部菜单：本地/网络/两者 | 部分实现 | 鸿蒙有独立的"备份到本地"和"备份到云端"按钮，无组合选项 |
| U-004 | 手动恢复 | 底部菜单：从本地/从网络 | 已实现 | 鸿蒙有独立的"从本地恢复"和"从云端恢复" |
| U-005 | 云端备份列表选择 | 加载 WebDAV 备份列表，BottomSheet 选文件 | 部分实现 | 鸿蒙列出备份文件名，点击直接恢复，无 BottomSheet 选择 |
| U-006 | 恢复忽略设置 | 对话框勾选跳过的数据类型 | 未实现 | 鸿蒙无忽略设置 |
| U-007 | 自动备份配置 | 开关 + 间隔配置 | 未实现 | 鸿蒙无自动备份UI |
| U-008 | 备份路径选择 | SAF 选择目录（OpenDocumentTree） | 未实现 | 鸿蒙直接使用文件选择器保存，无持久化路径 |
| U-009 | 进度提示 | 显示备份/恢复进度和结果 | 已实现 | 鸿蒙 `statusText` 展示进度 |

### 3.5 Web 远程管理

| # | 规格 | Android 行为 | 鸿蒙当前状态 | 差距说明 |
|---|------|--------------|--------------|----------|
| M-001 | 嵌入式 HTTP 服务 | 基于 NanoHTTPD 启动内嵌服务器 | 部分实现 | `WebServer.ts` 基于 `TcpServer` 的实现有 `route()` 方法但监听未启用 |
| M-002 | 书架 API | `GET /api/bookshelf` | 部分实现 | 路由存在但监听未启用 |
| M-003 | 书源 API | `GET /api/sources` | 部分实现 | 路由存在但监听未启用 |
| M-004 | 搜索 API | `GET /api/search?keyword=` | 部分实现 | 路由存在但监听未启用 |
| M-005 | 管理页面 | 内嵌 HTML 管理界面（rawfile） | 部分实现 | 路由存在但监听未启用 |
| M-006 | 状态 API | `GET /api/status` | 已实现 | `route()` 中处理 |

---

## 4. 核心数据

### 4.1 备份数据格式

```json
{
  "version": "1.0",
  "exportTime": "2026-07-03T12:00:00.000Z",
  "appVersion": "1.0",
  "books": [{ ... }],
  "bookSources": [{ ... }],
  "replaceRules": [{ ... }],
  "rssSources": [{ ... }],
  "rssStars": [{ ... }],
  "rssReadRecords": [{ ... }],
  "readRecords": [{ ... }],
  "readRecordDetails": [{ ... }],
  "searchHistory": [{ ... }],
  "txtTocRules": [{ ... }],
  "bookSourcesCache": [{ ... }],
  "settings": { "key": "value", ... }
}
```

所有 JSON 文件打包为 ZIP 存档，兼容标准 ZIP 读取器。

### 4.2 WebDAV 数据结构

```
{serverUrl}/{path}/legado/
  ├── backup_2026-07-03.zip
  ├── backup_2026-07-02.zip
  ├── progress_书名_作者.json
  ├── progress_书名_作者.json
  └── ...
```

### 4.3 设置存储键

备份恢复涉及以下偏好键：

| 键 | 类型 | 默认值 | 说明 |
|-----|------|--------|------|
| `webdav_url` | string | `https://dav.jianguoyun.com/dav/` | WebDAV 服务器地址 |
| `webdav_user` | string | `""` | WebDAV 用户名 |
| `webdav_pwd` | string | `""` | WebDAV 密码（明文，需加密） |
| `webdav_path` | string | `"legado"` | WebDAV 路径前缀 |
| `webdav_auto_sync` | boolean | `false` | 自动同步开关 |

### 4.4 ZIP 文件格式（ZipWriter）

鸿蒙 `ZipWriter` 使用 STORED（无压缩）模式：

```
Local File Header (30 + filename bytes)
File Data (raw)
Central Directory Header (46 + filename bytes)
End of Central Directory Record (22 bytes)
```

CRC-32 校验使用标准查表法，兼容所有 ZIP 读取器。

---

## 5. 关键设计

### 5.1 备份流程

```
exportBackup()
  → 查询 13 张数据库表（直接 SQL）
  → 读取 SettingsStore 所有键值
  → 组装 BackupData（JSON）
  → 返回 BackupData 对象

[本地保存]
  → ZipWriter.addTextFile('backup.json', JSON.stringify(data))
  → DocumentViewPicker.save() → 用户选择路径
  → zip.saveTo(uri)

[WebDAV 上传]
  → ZipWriter.addTextFile('backup.json', JSON.stringify(data))
  → WebDavService.uploadBackupZip(zip)
    → ensureDirectory('legado')
    → PUT {url}/legado/backup_2026-07-03.zip
```

### 5.2 恢复流程

```
[本地]
  → DocumentViewPicker.select() → 用户选择 ZIP/JSON
  → 尝试直接 JSON.parse（非 ZIP 格式兜底）
  → ZipReader 解压 → 读取 backup.json
  → importBackup(backupData)
    → 逐表 INSERT（rdb.insert）
    → SettingsStore.importAll(settings)

[WebDAV]
  → WebDavService.listBackups() → 列出备份
  → 用户选择备份名
  → WebDavService.downloadBackup(name) → 下载到临时文件
  → ZipReader 解压 → 读取 backup.json → importBackup()
```

### 5.3 WebDAV 协议交互

```
PROPFIND /
  Request:  Depth: 0, Authorization: Basic xxx
  Response: XML multistat (文件/目录属性)

PROPFIND /path
  Request:  Depth: 1
  Response: XML 包含目录下所有条目

MKCOL /path
  → 创建目录（如果不存在）

PUT /path/file.zip
  → 上传文件（application/zip）

GET /path/file.zip
  → 下载文件

DELETE /path/file.zip
  → 删除远程文件
```

XML 响应解析使用正则提取：
```
<response>
  <href>/path/file.zip</href>
  <propstat>
    <prop>
      <getlastmodified>Mon, 03 Jul 2026 12:00:00 GMT</getlastmodified>
      <getcontentlength>12345</getcontentlength>
      <resourcetype/>
    </prop>
  </propstat>
</response>
```

### 5.4 阅读进度同步

```
uploadBookProgress(bookName, author, progressJson)
  → PUT {root}/legado/progress_{name}_{author}.json

downloadBookProgress(bookName, author)
  → GET {root}/legado/progress_{name}_{author}.json
  → 返回 null 如果不存在

syncAllProgress(localProgress)
  → 遍历本地所有书籍
  → 下载云端进度
  → 比较 durChapterIndex（取更大者）
  → 返回合并后结果
```

### 5.5 恢复忽略策略

Android 支持在恢复时跳过以下配置：

| 忽略项 | 说明 |
|--------|------|
| `readConfig` | 阅读界面配置（字体、行距等） |
| `themeMode` | 深色/浅色模式 |
| `themeConfig` | 主题自定义配置 |
| `coverConfig` | 封面配置 |
| `bookshelfLayout` | 书架布局 |
| `showRss` | 显示 RSS |
| `threadCount` | 搜索并发线程数 |
| `localBook` | 本地书籍 |

鸿蒙当前未实现忽略设置（所有数据均导入）。

---

## 6. 界面布局

### 6.1 备份设置页面

```
Column
  TopBar
    "< 返回" + "备份与恢复" + StatusText
  Scroll
    WebDAV Config Section
      Server URL Input (默认 https://dav.jianguoyun.com/dav/)
      Username Input
      Password Input (InputType.Password)
      Path Prefix Input (默认 "legado")
      Auto Sync Toggle
      Test Connection Button
    Local Backup Section
      "备份到本地文件" Button
      "从本地文件恢复（选 ZIP）" Button
    Cloud Backup Section
      "备份到云端" Button
      "从云端恢复" Button
      Backup File List (显示可用备份)
```

### 6.2 设置页入口

在 `SettingsPage.ets` 主菜单中添加"备份与恢复"条目（`🔄`），点击直接导航到 `BackupSettingsPage`。

---

## 7. 与 Android 关键差距

| 差距 | 影响 | 优先级 |
|------|------|--------|
| 无 AES 加密（WebDAV 密码明文存储） | 密码泄露风险 | P0 |
| 无自动备份触发 | 用户需手动操作 | P1 |
| 无恢复忽略设置 | 恢复可能覆盖用户当前配置 | P1 |
| 无备份模式选择（local/webdav/both） | 功能完整性 | P1 |
| 无 config.xml 兼容（Android 使用 XML 格式存设置） | 跨平台备份互操作受限 | P2 |
| 无 Web 远程管理（WebServer 路由就绪但监听未启用） | 功能缺失 | P2 |
| 无背景图同步 | 功能缺失 | P2 |
| 无远程书籍同步 | 功能缺失 | P2 |
| 无互斥锁 | 极端情况下并发备份/恢复可能冲突 | P2 |
| 无备份设备名 | 文件名区分度不足 | P3 |

---

## 8. 验收清单

备份与同步模块补齐后至少满足：

1. 从设置页进入"备份与恢复"，能看到 WebDAV 配置区域。
2. 配置 WebDAV 账号密码后能测试连接，成功/失败有反馈。
3. 点击"备份到本地文件"能呼出文件选择器，保存 ZIP 文件。
4. 点击"从本地文件恢复"能选 ZIP 文件，恢复后书架和书源正常。
5. 点击"备份到云端"能上传备份到 WebDAV 服务器。
6. 点击"从云端恢复"能列出云端备份，选择后恢复。
7. WebDAV 阅读进度同步能正常上传/下载/合并。
8. WebDAV 密码存储为加密形式（非明文）。
9. 恢复时能被询问是否跳过某些数据类型。
10. 自动备份能在每次启动时检查并触发（如超 24 小时）。
