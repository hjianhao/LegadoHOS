# 书架管理功能 · Android vs 鸿蒙 对比分析

> 日期：2026-07-01 | 范围：`BookshelfManagePage.ets` (300 行) vs `BookshelfManageScreen.kt` (1669 行) + `BookshelfManageScreenViewModel.kt` (1021 行)

---

## 对比摘要

| 功能大类 | Android 代码行数 | 鸿蒙 代码行数 | 鸿蒙实现度 |
|----------|-----------------|--------------|-----------|
| 列表展示 + 选中 | ~200 | ~150 | ✅ 80% |
| 分组管理 | ~100 | ~50 | ✅ 70% |
| 批量操作 | ~400 | ~80 | ⚠️ 30% |
| **批量换源** | ~200 | 0 | ❌ 缺失 |
| **拖拽排序** | ~80 | 0 | ❌ 缺失 |
| **导出配置** (路径/类型/编码/替换/自定义) | ~400 | ~30 | ❌ 5% |
| **下载管理** (缓存进度/失败重试/通知) | ~300 | ~40 | ⚠️ 10% |
| **自定义导出** (EPUB/分割/范围) | ~200 | 0 | ❌ 缺失 |
| **长按菜单** (Info card per-book) | ~200 | 0 | ❌ 缺失 |
| **搜索方向** (书名/作者/书源/分组) | ~60 | ~20 | ⚠️ 30% |
| FAB 菜单 | ~100 | 0 | ❌ 缺失 |
| 应用日志 | ~60 | 0 | ❌ 缺失 |
| **总计** | **2690 行** | **300 行** | **~11%** |

---

## 缺失功能清单

### 1. 批量换源 (ChangeSourceSheet per-book batch) — 缺失
Android: BookshelfManageScreen 支持选中多本书后批量打开换源面板，逐本匹配源
- `BatchChangeSourcePreviewItem` 数据模型
- WebView 抓取 / source login 兜底
- 迁移选项（保留章节/进度/替换）

### 2. 拖拽排序 — 缺失
Android: `reorderableState` + `ReorderableItem` + DragHandle
- 列表项长按拖拽排序
- `BookshelfManageScreenIntent.MoveBookOrder` action

### 3. 导出配置 — 几乎全部缺失
Android 导出子系统包含：
- **导出路径** — `exportDir` launcher (OpenDocumentTree)
- **导出类型** — txt / epub 切换
- **导出编码** — UTF-8 / GBK / GB2312 / Big5 / UTF-16 + 自定义
- **导出文件名模板** — 支持 `${name}`, `${author}`, `${index}` 等变量
- **替换净化** — `exportUseReplace` toggle
- **导出包含章节名** — `exportNoChapterName` toggle
- **导出到 WebDav** — `exportToWebDav` toggle
- **导出插图文件** — `exportPictureFile` toggle
- **并行导出** — `parallelExportBook` toggle
- **自定义导出** — EPUB 章节范围 + 大小分卷 + 文件名模板
- **批量导出** — 单个/选中/全部
- **导出进度提示** — `ExportBookService.exportMsg` tracking

### 4. 下载管理 — 极简
鸿蒙版只有基于 `DownloadService` 的队列加入，缺少：
- 下载进度展示 (每本书的 `preparingDownload` / `isDownloading`)
- 下载失败原因展示 (`getDownloadFailureMessage`)
- 停止下载按钮
- 缓存计数 (`getCacheCount`)
- 后台通知进度

### 5. 书籍长按菜单 — 缺失
Android 每本书长按弹出菜单：
- 清除缓存（单本）
- 导出单本
- 导出到 WebDav
- 自定义导出
- 换源
- 更换分组
- 禁用更新
- 删除

### 6. FAB 菜单 — 缺失
Android `AppFloatingActionButtonMenu`:
- 全选 / 反选
- 缓存选中
- 批量换源
- 移动分组
- 导出选中
- 清除缓存
- 删除

---

## 鸿蒙版现有的功能

鸿蒙版 300 行实现：
- ✅ 列表展示 + 搜索 + 分组过滤
- ✅ Checkbox 多选
- ✅ 全选 / 反选
- ✅ 分组选择器底部弹窗
- ✅ 移动分组
- ✅ 移出书架（单本 + 批量）
- ✅ 导出选中（JSON 格式）
- ✅ 清除章节缓存（批量）
- ✅ 添加到缓存队列（批量）
- ✅ 书籍封面缩略图

---

## 实现优先级建议

| 优先级 | 功能 | 原因 |
|-------|------|------|
| P0 | 导出配置（类型/编码） | 核心管理功能，影响用户体验 |
| P0 | 缓存进度展示 | 下载没反馈是体验硬伤 |
| P1 | 长按菜单 | 使每本书可独立操作 |
| P1 | FAB 菜单 | 批量操作入口提升效率 |
| P2 | 批量换源 | 高级用户需要 |
| P2 | 拖拽排序 | 高级功能，可延后 |
| P3 | 自定义导出 (EPUB/chapter scope/size split) | 复杂，需 EpubParser |
