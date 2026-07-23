# 云端书籍 · 阶段 2 实现说明

> 日期：2026-07-23  
> 分支：`feat/cloudbook-phase1`（阶段 1+2 连续开发）  
> 构建：`./scripts/build.sh debug` 通过（`tmp/cloudbook-phase2-build.log`）

## 交付清单

| 文件 | 职责 |
|---|---|
| `service/cloud/WebDavHttp.ts` | Basic Auth、URL 拼接/编码、PROPFIND 解析（可保留目录 + etag）、错误文案 |
| `service/cloud/WebDavCloudProvider.ts` | `testConnection` / `list` / `stat` / 上下传 / MKCOL / DELETE |
| `service/WebDavService.ts` | 备份列表改用共享解析，`includeDirectories=false` 保持兼容 |
| `service/cloud/CloudSourceRepository.ts` | `testConnection` / `saveWithValidation` |
| `pages/CloudSourceManagePage.ets` | 来源列表、启用开关、删除确认 |
| `pages/CloudSourceEditPage.ets` | 编辑/新增、测试连接、根目录预览、保存前校验 |
| `MyPage` + `main_pages.json` | 「我的」一级菜单入口「云端书库」（不在设置二级） |
| `MainAbility` | 启动时 `ensureCloudProvidersRegistered()` |

## 行为要点

1. **多来源独立 rootPath**：保存与测试均以 `endpoint + rootPath` 为根，`list('')` 直接列该目录。  
2. **目录保留**：`WebDavCloudProvider.list` 使用 `includeDirectories: true`；备份 `WebDavService` 仍过滤目录。  
3. **保存失败不覆盖**：`saveWithValidation` 先 `testConnection`+`list`，失败不写库、不改凭证。  
4. **编辑密码**：留空表示不修改；勾选改密逻辑由 `passwordDirty` / `updateSecret` 控制。  
5. **HTTP 风险提示**：非 HTTPS 地址在编辑页黄色提示。  
6. **删除来源**：只删配置 + Binding + 凭证，不动本地书（对话框文案已说明）。

## 真机验收清单

- [ ] 同一 endpoint、两个不同 rootPath 的来源，测试连接预览内容不同  
- [ ] rootPath 为空时列出 endpoint 根  
- [ ] 中文 / 空格目录能列出  
- [ ] 错误密码显示 401 类提示，旧配置仍在  
- [ ] 备份 WebDAV 列表/上传仍可用（回归）

## 下一阶段（3）

云端书籍浏览页、面包屑导航、Binding 状态合并（尚未下载不进书架）。
