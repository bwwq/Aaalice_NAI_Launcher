# 云备份协议与验证

本文维护当前代码的结构与不变量，OAuth 注册见 [cloud_drive_oauth.md](cloud_drive_oauth.md)。用户操作与数据选择边界见 [AGENTS.md](../AGENTS.md#云同步兼容性)。本文不记录历史迁移任务、某次机器的性能结果或真实服务通过状态。

## 代码入口

| 职责 | 入口 |
|---|---|
| 协议模型与限制 | [models.dart](../lib/core/cloud_sync/models.dart) |
| 同步协调、上传与下载 | [coordinator.dart](../lib/core/cloud_sync/coordinator.dart)、[snapshot_uploader.dart](../lib/core/cloud_sync/snapshot_uploader.dart)、[snapshot_transfer.dart](../lib/core/cloud_sync/snapshot_transfer.dart) |
| 小对象打包与上传产物 | [snapshot_object_packer.dart](../lib/core/cloud_sync/snapshot_object_packer.dart)、[snapshot_upload_plan.dart](../lib/core/cloud_sync/snapshot_upload_plan.dart) |
| 有界调度 | [bounded_transfer_scheduler.dart](../lib/core/cloud_sync/bounded_transfer_scheduler.dart) |
| 后端契约与四种实现 | [backend/](../lib/core/cloud_sync/backend/) |
| 本地准备与持久化 | [app_cloud_sync_data_source.dart](../lib/data/cloud_sync/app_cloud_sync_data_source.dart)、[verified_blob_store.dart](../lib/data/cloud_sync/verified_blob_store.dart) |
| 内容类型与适配器 | [content_selection.dart](../lib/core/cloud_sync/content_selection.dart)、[app_cloud_sync_adapters.dart](../lib/data/cloud_sync/app_cloud_sync_adapters.dart) |
| 业务入口与界面 | [providers/cloud_sync/](../lib/presentation/providers/cloud_sync/)、[screens/cloud_sync/](../lib/presentation/screens/cloud_sync/) |
| 回归测试 | [test/core/cloud_sync/](../test/core/cloud_sync/)、[test/data/cloud_sync/](../test/data/cloud_sync/) |

## 协议与数据身份

新备份写入配置路径追加 `-v4` 的命名空间，继续读取 `-v3` 中已发布的 schema 2/3 明文备份。后端接口仍使用 `HEAD.json`、`snapshots/<snapshotId>.json`、`objects/<sha256>`；内容寻址使用密文 SHA-256。

- 业务记录及 journal 保留逻辑内容身份；`EncryptedCloudSyncBackend` 在传输边界压缩、加密和校验，不把明文文件名、标签或内容哈希暴露在远端清单中。
- 每个逻辑对象按最多 3 MiB 切成 ZIP 分卷，再用 AES-256-GCM 加密，最终对象不超过 4 MiB。nonce 每次新加密随机生成；重复上传使用持久化的同一份密文。
- 每个对象有随机数据密钥，每份快照有随机清单密钥；加密清单包含对象映射和数据密钥。清单按树状分页加密；独立密钥封装对象保存被软件恢复密钥加密的清单密钥。
- 恢复密钥内置且带版本，新版本保留旧版本密钥。不依赖本机缓存或用户密码，不属于只有用户能解密的端到端加密。
- 对象和密钥封装先上传，然后提交不可变快照入口，最后条件提交 HEAD。HEAD 内加密的成功快照目录只在提交时更新，未提交清单不进入成功历史。
- HEAD 成功目录保留最多 100 个入口，与可配置保留上限一致；过期数据的物理清理另行受后端能力限制。分页仅限制单页大小，不设置备份总量上限。
- 缓存持久化对象密文、随机密钥、分页清单和封装；恢复上传会重新核对远端存在性。GitHub 未提交 blob 在重启后重新暂存，仍通过最后一次 tree/commit/ref 发布。
- schema 2/3 继续按原格式读取，不自动改写旧备份。清理只发生在新备份成功提交之后，不因连接或预览触发。

## 收藏原图与保留份数

本地收藏原图默认开启，可独立关闭。UUID 映射独立于 SQLite 自增 ID；原图按内容哈希去重复用。导入时先校验并写文件，再登记索引、收藏时间和标签，相簿通过路径映射绑定。重名不同内容保留双方，重复恢复复用已恢复文件；取消收藏不删除原图。缺失或变化的源文件阻止本次提交。

每个连接保存 `keepSnapshots`，默认 5，范围 1～100。新旧格式共同计数，优先保留当前 HEAD，其余按创建时间倒序。新快照成功提交后才清理；共享分卷、清单分页和密钥都按保留快照的可达引用保存。GitHub 通过条件 tree commit 原子清理两个命名空间，Git 历史本身仍保留旧数据；其他后端当前缺少同等删除协调，显示旧备份待清理，不冒险物理删除。

## 本地准备、预览与恢复

本地使用 verified blob store 与持久化 descriptor 保存对象引用。准备、上传、预览、应用与恢复应复用已校验的产物，避免重复复制完整 payload。

- 来源写入先经过临时文件、大小与 SHA-256 校验，再发布可引用对象；半成品不能标为 READY。
- 进程内可复用已验证句柄；跨进程重建引用后在实际读取时验证内容。文件大小、mtime、provider eTag 或 MD5 不能代替协议 SHA-256。
- 预览确认前复核本地状态与远端 HEAD；变化时报告预览过期，不能用旧结果覆盖新数据。
- 应用前完成 preflight、恢复数据与 journal 的持久化；中断后按实际 journal 恢复，不能把异常吞掉后继续宣布成功。
- 本地对象回收必须尊重 base、operation、recovery 和 preview 引用。引用损坏须报错，不能把无法解析的对象当作未引用对象删除。

## 传输与后端能力

当前调度默认 Android 2 路/16 MiB 在途 payload，桌面 4 路/32 MiB；更保守的后端限制仍需遵守。暂停/取消阻止新任务，manifest/HEAD 的提交顺序保持串行。

| 后端 | 维护约束 |
|---|---|
| OneDrive | 已有目录先只读解析，缺失时按明确的 fail 冲突语义创建并处理并发创建；复用分页 inventory；HEAD 保持条件更新，模糊响应读回校验 |
| Google Drive | 授权审核未通过，新增连接入口暂时禁用；保留已保存连接、备份读取和后端实现。保持 `manualBackupOnly`，不把 version/headRevisionId 当作强 CAS |
| GitHub | 读取固定 commit/tree；对象通过 Git Database API 组织，tree/commit/ref 一次发布，禁止逐文件 Contents API 替代原子提交 |
| WebDAV | 根据实际 ETag/条件写能力决定模式；能力不足保持手动备份；坚果云单并发，不自动合并或恢复历史 |
| WebDAV 远端维护 | 不执行自动 GC；缺少可证明安全的删除协调时不能猜测共享对象已无引用 |

重试须区分不可变对象与可变提交；429、Retry-After、响应丢失、409/412 等保留原始错误与上下文。不能盲目重放 HEAD 提交。

保存连接仅保存并验证配置，不自动上传、下载、恢复或续跑待处理操作。OAuth/账户凭据和设备专属状态不进备份；本地图库仅上传用户所选的收藏原图。

启动时立即开始恢复已保存连接，账号信息先于网络校验显示，首次恢复期间不显示重复登录入口；无已保存连接时不得重建正在编辑的设置表单。已连接时的前台刷新保留 Dashboard，首次恢复只读取一次 HEAD，成功后清除先前失败状态。自动上传、自动拉取仍未启用。

手动操作遇到已开始的前台连接检查时，等待该检查结束后继续，不把后台检查误报为重复同步；等待期间拒绝重复手动提交，检查失败保留原始错误。取消或断开连接后不得启动尚在等待的备份。

## 验证方式

日常修改优先运行受影响测试；下面的目录用于限定云同步范围：

~~~powershell
pwsh -NoProfile -ExecutionPolicy Bypass -File scripts/test_affected.ps1 -Path "lib/core/cloud_sync,lib/data/cloud_sync,lib/presentation/providers/cloud_sync,lib/presentation/screens/cloud_sync"
~~~

协议、并发、恢复或性能变化时使用有总时限的基准入口：

~~~powershell
pwsh -NoProfile -ExecutionPolicy Bypass -File scripts/run_cloud_sync_benchmark.ps1
~~~

该脚本默认包含 production 1 GiB round trip、补充 N/C 场景、provider contract 和进程内存采样，最多 600 秒。报告默认写入 `tool/.tmp/cloud-sync-benchmark/report.json`，不提交；不要为纯文档修改默认执行该基准。

判断结果时区分：

- **逻辑指标**：对象复用、source open/hash 次数、网络/磁盘字节、请求数、在途预算。
- **进程指标**：实际 WorkingSet/RSS、峰值及采样范围；不能用调度器预留字节替代。
- **测试后端**：fake provider 和 loopback 证明其断言覆盖的协议行为，不证明公网服务的延迟、配额或账号兼容性。
- **真实服务**：按用户已明确授权的范围在隔离目标验证，记录账号类型、服务版本、场景、请求与结果；历史文档中的授权描述或通过结论不构成本次执行证据。

本地化变化后重新生成 ARB 输出并运行相关本地化测试；UI 自动化按 [运行验收技能](../.agents/skills/aaalice-runtime-verify/SKILL.md) 执行。所有检查仅报告本次实际结果。
