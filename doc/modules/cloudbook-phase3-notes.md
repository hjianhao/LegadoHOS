# 云端书籍 · 阶段 3 实现说明

> 日期：2026-07-23  
> 构建：`./scripts/build.sh debug` 通过（`tmp/cloudbook-phase3-build.log`）

## 交付清单

| 文件 | 职责 |
|---|---|
| `model/CloudBookListItem.ts` | 展示状态、列表项、尺寸/时间格式化 |
| `service/cloud/CloudBookRepository.ts` | `listDirectory` + Binding/本地书合并 + 过滤排序 |
| `pages/CloudBookPage.ets` | 浏览页：来源切换、面包屑、搜索、排序、状态徽章 |
| `MyPage` / `main_pages.json` | 入口改为浏览页；来源管理从页内进入 |

## 状态规则

| 条件 | 显示 |
|---|---|
| 目录 | 目录 |
| 无 Binding 或本地文件缺失 | 云端 |
| Binding + 本地书存在 | 已下载 |
| Binding 为 OUTDATED 或列表元数据与 Binding 不一致 | 可更新 |
| Binding ERROR 且无可用本地文件 | 错误 |

- **仅** `sourceId + remotePath` 匹配 Binding；同名不同路径/来源互不影响。  
- 未下载文件**不会**写入书架。  
- 本阶段不下载；点击可导入文件提示「下一阶段」；已下载可打开 `BookInfoPage`。

## 入口

**我的 → 云端书库** → `CloudBookPage`  
页内 **来源** / 切换菜单中的「管理来源…」→ `CloudSourceManagePage`

## 验收建议

1. 配置两个不同 rootPath 的来源，切换后列表不串。  
2. 进入子目录、点面包屑返回根。  
3. 搜索 / 排序仅作用于当前目录缓存列表。  
4. 无 Binding 的文件始终显示「云端」，即使本地有同名书。  
5. 深色/浅色模式正常。

## 下一阶段（4）

`CloudTransferManager` + 临时文件下载 + `LocalBookEngine` 导入 + Binding 写入 + 进度 UI。
