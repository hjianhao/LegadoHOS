# 云端书籍 · 阶段 7 实现说明

> 日期：2026-07-23  
> 范围：第二个 Provider（`localfolder`）、表单/凭证适配、集中注册  
> 目标：验证 `CloudProviderRegistry` 可扩展性，而非接入真实第三方网盘 OAuth

## 1. 设计选择

| 项 | 说明 |
|---|---|
| 新类型 | `localfolder`（常量 `CLOUD_PROVIDER_LOCAL_FOLDER`） |
| 存储 | 应用沙箱 `files/cloud_local_folder/<namespace>/` |
| 为何不用阿里云盘/S3 等 | 阶段 7 验收重点是抽象可扩展；OAuth/签名与业务无关，本地目录即可走通 list/download/import |
| 未改文件 | `Book` 模型、`LocalBookEngine`、`WebDavCloudProvider` 协议方法、`CloudBookPage` 核心状态机 |

## 2. 新增/调整文件

| 文件 | 职责 |
|---|---|
| `service/cloud/LocalFolderCloudProvider.ts` | 实现 `CloudStorageProvider`：list（`nextCursor` 分页）、stat、download、upload、mkdir、delete |
| `service/cloud/CloudProviderBootstrap.ts` | 集中 `ensureCloudProvidersRegistered()`：注册 webdav + localfolder |
| `model/CloudSource.ts` | 类型常量、`LocalFolderCloudConfig`、`cloudProviderDisplayName`、类型判断辅助 |
| `pages/CloudSourceEditPage.ets` | Provider 选择器；webdav / localfolder 表单字段分流 |
| `CloudSourceRepository.ts` | 按类型规范化 endpoint、解析凭证（localfolder 口令可空） |

## 3. Capabilities

```text
localfolder:
  canCreateDirectory: true
  canDelete: true
  canMove: false
  supportsEtag: false
  supportsRangeDownload: false
```

`remoteId` 使用本地绝对路径，保证同路径稳定。

## 4. 表单与凭证适配

| 字段 | WebDAV | localfolder |
|---|---|---|
| endpoint | `https://...` | 命名空间，存为 `localfolder://demo` |
| username | 必填 | 默认 `local` |
| secret | 必填密码 | 可选口令；空则占位 `local` |
| rootPath | 服务器相对根 | 命名空间下子目录 |
| 编辑切换类型 | — | 编辑态禁止切换，避免语义混乱 |

## 5. 复用链路（无改动核心）

```text
CloudBookPage → CloudBookRepository.listDirectory / downloadAndImport
  → CloudProviderRegistry.get(providerType)
  → LocalFolderCloudProvider | WebDavCloudProvider
  → Binding + LocalBookEngine 导入
```

## 6. 验收步骤（真机/模拟器）

1. 我的 → 云端书库管理 → 新增来源  
2. 选择「本地演示目录」，命名空间 `demo`，测试连接 → 应看到 seed 的 `README_cloud_demo.txt`  
3. 将 epub/txt 放入设备沙箱对应目录（或后续扩展文件选择器写入）  
4. 书架 ☁ → 进入该来源 → 浏览 → 下载导入 → 书架出现本地书  
5. 新增 WebDAV 来源仍可用；编辑旧 WebDAV 不出现类型切换  
6. 确认未改动 WebDAV 下载/列表行为

## 7. 后续可选

- 真实网盘（S3 / 阿里云盘 / OneDrive）：仅新增 Provider + 表单适配 + Bootstrap 注册  
- UI 根据 `getCapabilities()` 隐藏上传/删除按钮（阶段 5 上传 UI 时再接）  
- localfolder 从文档选择器导入文件到命名空间  
- 单元测试：分页 cursor、路径逃逸、`requireToken` 校验

## 8. 构建

```bash
./scripts/build.sh debug
```
