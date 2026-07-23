# 云端书籍 · 阶段 4 实现说明

> 日期：2026-07-23  
> 构建：`./scripts/build.sh debug` 通过（`tmp/cloudbook-phase4-build.log`）

## 交付清单

| 文件 | 职责 |
|---|---|
| `service/cloud/CloudLocalFileStore.ts` | 临时目录、最终路径、原子移动、启动清理 `.part` |
| `service/cloud/CloudTransferManager.ts` | 进程内任务、并发槽、进度回调、取消标记 |
| `service/cloud/CloudBookRepository.ets` | `downloadAndImport` / 批量 / 传输叠加 |
| `pages/CloudBookPage.ets` | 下载按钮、进度条、多选批量下载 |
| `service/BookDeleter.ets` | 删本地书时 `unlinkBook`（保留远端） |
| `MainAbility` | `AppContextHolder` + 启动清理临时文件 |

## 下载流程

```
点击下载
  → TransferManager.beginDownload (sourceId+remotePath 去重)
  → 并发槽（默认 2）
  → Provider.downloadToFile → files/cloudbook/.tmp/<taskId>.part
  → 校验非空 → 原子移动到 files/books/cloud_<sourceId>_<hash>_<name>
  → EPUB：TaskPool 解压 → LocalBookEngine.importBook
  → Binding upsert + bindBook(DOWNLOADED)
  → shelfRefreshCounter++
失败：删临时/半成品；若已导入则 BookDeleter 清理；Binding markError
```

## UI

- 文件行「下载」按钮 / 点击云端项即下载  
- 下载中显示进度条与百分比  
- 多选 → 下载所选（单项失败不取消其他）  
- 已下载点击打开 BookInfo  

## 删除语义

书架删除本地书 → 仅 `unlinkBook`（Binding.bookId=0 → 云端页显示「云端」），**不删**远端文件。

## 限制说明

- RCP `fetch` 仍会拿到完整响应 body 再落盘；大文件内存峰值仍受限于系统 HTTP 栈。  
- 取消为协作式标记：进行中的 GET 无法中断 socket，结束后丢弃结果并清理临时文件。

## 验收建议

1. 下载 TXT/EPUB/PDF → 书架出现本地书，断网可开  
2. 同名不同来源可各自下载  
3. 中途杀进程：重启后无永久「下载中」，tmp 过期清理  
4. 删书架书后云端页恢复「云端」  

## 下一阶段（5）

上传、可更新确认导入、云端副本面板。
