# 云端书籍 · 阶段 6 实现说明

> 日期：2026-07-23  
> 范围：备份集成、安全收敛、兼容性文档（**跳过阶段 5**）  
> 构建：`./scripts/build.sh debug` 通过（`tmp/cloudbook-phase6-build.log`）

## 1. 备份集成（BackupCodec）

### 导出
- `backup.json` 增加 `cloudSources[]`：
  - `name` / `providerType` / `endpoint` / `rootPath` / `configJson` / `enabled` / `sortNumber`
  - **不包含** password、secret、credentialRef、username
- `settings` 导出时过滤敏感键（`webdav_pwd`、`cloud_cred*`、`password`、`token`、`api_key` 等）
- 安卓 `config.xml` 同步不写入敏感键

### 恢复
- 按 `endpoint + rootPath` 匹配已有来源并更新；否则新建
- 新来源生成新 `credentialRef`，**密码从不恢复**
- `ImportResult` 新增：
  - `cloudSources`：恢复条数
  - `cloudSourcesNeedPassword`：需补密码条数
- 恢复后：
  - Toast 提示补密码
  - AppStorage `cloud_sources_show_password_hint`
  - 管理页黄色横幅引导编辑

### 路径
- 设置 → 备份与恢复 → 本地/云端恢复  
- 我的 → 云端书库管理 → 补密码

## 2. 安全加固

| 项 | 实现 |
|---|---|
| 凭证不进备份 | 导出剥离 + 恢复不写 secret |
| 日志脱敏 | `WebDavHttp.sanitizeUrlForLog` / `redactSecrets_` / `toUserMessage` |
| 跨主机重定向 | `shouldStripAuthOnRedirect` 工具方法（自定义跟随时用） |
| 路径逃逸 | 已有 `CloudPath` 拒绝 `..` / 协议 / 反斜杠 |
| HTTPS 提示 | 编辑页非 HTTPS 风险提示（阶段 2） |

## 3. 兼容性与质量检查清单

### WebDAV 服务端
| 场景 | 预期 |
|---|---|
| 坚果云 | PROPFIND 列目录、Basic Auth、中文路径 |
| Nextcloud/ownCloud | 绝对 href 归一化、目录尾 `/` |
| rootPath 空 | 列 endpoint 根 |
| 中文/空格路径 | encode 分段后可进入/下载 |

### 性能与异常
| 场景 | 预期 |
|---|---|
| 应用重启 | `.part` 超过 24h 清理 |
| 并发下载 | 默认 2，不永久卡在下载中 |
| 取消下载 | 协作式标记，结束后清临时文件 |
| 备份包体积 | settings 合并受 8MB 限制（既有） |

### 回归
- [ ] 本地书导入 / 书架 / 小说模式阅读
- [ ] WebDAV 备份上传与进度同步
- [ ] 云端书库浏览与下载
- [ ] 备份→恢复→云端来源在、密码需重填

## 4. 未做（阶段 5 范围）

- 本地书上传到云端
- 可更新确认后重新导入
- BookInfo 云端副本面板

## 5. 相关文件

- `service/backup/BackupCodec.ts`
- `service/BackupService.ts`
- `pages/BackupSettingsPage.ets`
- `pages/CloudSourceManagePage.ets`
- `service/cloud/WebDavHttp.ts`
- `service/cloud/WebDavCloudProvider.ts`
