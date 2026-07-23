# 云端书籍 · 阶段 1 实现说明

> 日期：2026-07-23  
> 分支建议：`feat/cloudbook-phase1`  
> 构建：`./scripts/build.sh debug` 通过（`tmp/cloudbook-phase1-build.log`）

## 交付清单

| 文件 | 职责 |
|---|---|
| `model/CloudSource.ts` | 来源 / 凭证 / WebDAV 配置模型 |
| `model/CloudBookBinding.ts` | Binding 与同步状态常量 |
| `service/cloud/CloudStorageProvider.ts` | Provider 接口与 CloudFile 模型 |
| `service/cloud/CloudPath.ts` | rootPath/remotePath 规范化与安全校验 |
| `service/cloud/CloudProviderRegistry.ts` | Provider 注册路由（阶段 2 注册 WebDAV） |
| `service/cloud/CloudSourceRepository.ts` | 来源 CRUD、凭证编排、删除编排 |
| `service/cloud/CloudBookBindingRepository.ts` | Binding upsert/解绑/查询 |
| `data/database/CloudSourceTable.ts` | `cloud_sources` DAO + DDL |
| `data/database/CloudBookBindingTable.ts` | `cloud_book_bindings` DAO + 索引 |
| `data/preferences/CloudCredentialStore.ts` | 多来源加密凭证 |
| `data/preferences/SettingsStore.ts` | 新增 `putSecret` / `getSecret` / `remove` |
| `data/database/AppDatabase.ts` | 幂等建表 + DAO getter |

## 设计对齐说明

1. **`bookId` 用 `0` 表示未绑定**（设计文档写 `null`）。RDB 与 ArkTS 更简单；语义与「book_id 为空」一致。
2. **可选字段**（etag 等）在模型中用空字符串而非 optional `?`，避免 ArkTS 可选链扩散。
3. **阶段 1 不测连接、不浏览远端**；`CloudSourceRepository.save` 只做本地持久化。连接测试在阶段 2 接入 Provider 后补上。
4. **删除来源**顺序：`deleteBySource` bindings → 删 source 行 → 删 credential。不碰 Book。
5. **凭证**键：`cloud_cred:` + ref，经 SettingsStore AES-GCM（不可用时明文降级，与现有 WebDAV 密码一致）。

## 最小用法示例（调试）

```ts
// 需 AppDatabase.init + SettingsStore.init 之后
const repo = new CloudSourceRepository();
const a = await repo.save({
  name: '坚果云-书库',
  endpoint: 'https://dav.jianguoyun.com/dav/',
  rootPath: 'LegadoBooks',
  username: 'user@example.com',
  secret: 'app-password',
  updateSecret: true,
});
const b = await repo.save({
  name: '坚果云-归档',
  endpoint: 'https://dav.jianguoyun.com/dav/',
  rootPath: 'LegadoBooks/归档',
  username: 'user@example.com',
  secret: 'app-password',
  updateSecret: true,
});
const list = await repo.listAll(); // 两条，rootPath 不同
// 凭证不在 RDB：SELECT * FROM cloud_sources 只有 credential_ref
await repo.deleteSource(a.id); // 本地书不受影响
```

## 下一阶段（2）

1. `WebDavCloudProvider`：testConnection / list（保留目录）/ stat / href 归一化  
2. 从 WebDavService 抽取共享工具，备份 API 不回归  
3. 来源管理页 + 编辑页 + 测试连接  
