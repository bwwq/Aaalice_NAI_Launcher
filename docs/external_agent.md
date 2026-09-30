# 外部 Agent 接口

在「设置 → 外部 Agent」开启连接，复制 Codex 或 OpenCode 配置。默认关闭，默认地址为 `http://127.0.0.1:39123`；可以修改端口，也可以开启「允许局域网连接」，改为监听 `0.0.0.0` 并选择软件显示的实际局域网地址。接口不使用访问令牌，不自动修改其他客户端的配置。

内置智能体默认隐藏，包括左栏、生成页聊天、手机入口和素材菜单。原有会话及模型配置保留，需要时可在同页重新显示。外部调用不需要打开聊天；生成和素材操作也不需要配置聊天模型。依赖模型或其他服务的单项功能，仍要求先配置对应服务。

## 客户端配置

Codex 的 `config.toml`：

```toml
[mcp_servers.aaalice]
url = "http://127.0.0.1:39123/mcp"
```

OpenCode V2 的 `opencode.json`：

```json
{
  "mcp": {
    "servers": {
      "aaalice": {
        "type": "remote",
        "url": "http://127.0.0.1:39123/mcp",
        "oauth": false
      }
    }
  }
}
```

旧版 OpenCode 使用 `mcp.aaalice`，不包含 `servers` 这一层：

```json
{
  "mcp": {
    "aaalice": {
      "type": "remote",
      "url": "http://127.0.0.1:39123/mcp",
      "oauth": false
    }
  }
}
```

局域网客户端将 URL 换成软件显示的局域网地址。配置格式参照 [Codex MCP](https://learn.chatgpt.com/docs/extend/mcp)、[OpenCode V2](https://opencode.ai/v2/docs/mcp-servers) 和 [OpenCode 旧版](https://dev.opencode.ai/docs/mcp-servers/)。MCP 支持经典 Streamable HTTP 的 `2025-11-25` / `2025-06-18` 握手、JSON 响应及图片资源读取；不要求客户端支持 Tasks 扩展。

## 权限、费用和多个客户端

- **询问**：读取直接执行，写入、删除和收费操作先在软件设置页确认。
- **自动同意**：普通操作直接执行；已知收费在累计额度内执行，超额或未知费用需确认。默认额度是 `0`。
- **完全控制**：允许的操作直接执行，包括收费操作。

三种模式始终禁止账号密钥读取、备份删除、覆盖恢复、清空数据和外部修改连接权限/额度。普通删除、移动仍受所选模式管理。已经等待确认的调用必须明确批准或拒绝，切换模式不会自动批准它。

Codex、OpenCode 以及 HTTP 调用共用一个写队列。写入、生成、扫描、图像处理和导入导出按接收顺序执行；读取和暂停、继续、停止、取消保持可用。排队中、进行中、待确认及最近结果均在设置页查看。外部启动的生成队列不会因为软件最小化而暂停。

每次写调用提供全局唯一的 `request_id`，建议使用 UUID，也可加客户端前缀。重试必须使用原 ID 和相同参数；不会重复入队或扣费，同一 ID 改用其他参数会返回冲突。生成准备会保存完整参数快照，因此多个客户端应各自准备并提交自己的 `preparation_id`，不要依赖共享生成页参数在两次调用之间保持不变。

额度按真实请求发送前的估算累计，批量预先检查总费用，Vibe 编码及生成重试也经过闸门。失败请求不自动退回估算额度，实际扣费以服务端为准。累计用量只保存在本机，可在设置页重置。进程重启会将未完成调用标为 `interrupted`，不会自动重放收费请求；原准备 ID 需重新准备。相同请求 ID 仍能取回中断记录。

关闭连接只停止接收新调用；已接收任务继续受权限和额度约束，可在设置页取消，已完成结果保留。取消是协作操作：正在完成的文件写入可能已经生效，结果会保留实际状态，不能假定取消意味着回滚。

## HTTP

| 路径 | 方法 | 用途 |
| --- | --- | --- |
| `/api/v1/status` | GET | 服务状态与活动任务数 |
| `/api/v1/tools` | GET | 全部工具、参数 schema、读写及长任务说明 |
| `/api/v1/call` | POST | 调用工具，写入需 `request_id`；也支持 `Idempotency-Key` 请求头 |
| `/api/v1/jobs` | GET | 最近调用与任务 |
| `/api/v1/jobs/{job_id}` | GET | 查询进度、确认状态、错误及结果 |
| `/api/v1/jobs/{job_id}/cancel` | POST | 取消任务 |
| `/api/v1/resources/{image_id}` | GET | 读取已登记的输出 PNG |

工具清单是参数的事实来源。普通调用完成时直接返回结果；长任务及待确认操作返回 `job_id`。结果中的图片提供绝对文件 `path`、HTTP `resource_url` 和 MCP `resource_uri`。未保存的生成图也会复制为可读文件，源图不会被覆盖。普通图库查询不会改变正在浏览的筛选、页码或选择。

### 发现、准备生成和读取结果

```powershell
$base = 'http://127.0.0.1:39123'
Invoke-RestMethod "$base/api/v1/tools"

function Invoke-LauncherTool($tool, $arguments) {
    $body = @{ tool = $tool; arguments = $arguments; request_id = [guid]::NewGuid().ToString() } | ConvertTo-Json -Depth 30
    $job = Invoke-RestMethod "$base/api/v1/call" -Method Post -ContentType 'application/json' -Body $body
    while ($job.status -in @('pending', 'running', 'awaitingApproval')) {
        if ($job.status -eq 'awaitingApproval') { Write-Host '请在软件的外部 Agent 设置页确认。' }
        Start-Sleep -Milliseconds 300
        $job = Invoke-RestMethod "$base/api/v1/jobs/$($job.job_id)"
    }
    if ($job.status -ne 'completed') { throw ($job | ConvertTo-Json -Depth 30) }
    return $job.result
}

# 先准备快照并获得费用，再真正提交。
$prepared = Invoke-LauncherTool 'prepare_generation' @{ operation = 'generate'; prompt = '1girl, blue hair'; width = 832; height = 1216 }
$preparationId = $prepared.content[0].data.preparation_id
$generated = Invoke-LauncherTool 'submit_generation' @{ preparation_id = $preparationId; confirmed = $true }
$generated | ConvertTo-Json -Depth 30
```

`confirmed=true` 只表达提交意图，不能绕过软件的权限或额度确认。需要重试调用时自行保存原 `request_id`；以上便捷函数每次产生新 ID，适用于首次调用。

### 图库、词库和处理

```json
{"tool":"search_local_gallery","arguments":{"favorites_only":true,"page":0,"limit":50}}
```

收藏结果带有真实路径和 `resource_ref`。把选定引用交给词库预览导入；原图删除或取消收藏不影响词库的独立副本：

```json
{
  "tool": "set_tag_library_preview",
  "request_id": "client-unique-preview-request",
  "arguments": {"entry_id":"existing-tag-entry-id","path":"D:/Images/example.png"}
}
```

原始图片导入 Vibe 使用 `import_vibe_image`，之后可用 `encode_vibe_entry` 为指定模型编码。Vibe 文件、bundle 和精准参考导入导出使用 `import_reference_files`、`export_reference_entries`，保留逐项结果及错误。

历史使用 `get_recent_images` 与 `read_image_resource`，词库预览读取使用 `get_tag_library_preview`。相簿/分类使用 `list_gallery_albums`、`manage_gallery_album` 和 `manage_gallery_category`；分类移图是实际文件移动，相簿成员是引用。

```json
{
  "tool": "process_image",
  "request_id": "client-unique-processing-request",
  "arguments": {"operation":"upscale","path":"D:/Images/example.png"}
}
```

`process_image` 实际执行 NovelAI 超分、Director 的情绪/去背景/上色/清理/线稿/素描，或已启用的 Windows DLSS。变体及增强可通过生成准备中的图生图参数、源图和强度提交；重绘使用手动草稿或蒙版生成工具。ComfyUI 使用 `list_comfyui_workflows` 与 `execute_comfyui_workflow`，必须预先启用并配置，接口不会擅自开启它。

Vibe 和精准参考保留现有增改、应用、收藏及删除工具，文件导入/导出使用 `import_reference_files` / `export_reference_entries`，Vibe 编码使用 `encode_vibe_entry`。批量导入返回逐项结果，保留成功项并报告失败原因。

备份只提供 `list_backups`、`browse_backup` 和 `create_backup`。创建沿用当前连接及内容选择，不删除旧备份；软件存在未结束的备份/恢复事务时明确拒绝外部创建，要求先在软件完成原操作，不自动恢复它。

## 开发验证

稳定回归入口为 `test/core/external_agent/external_agent_regression_test.dart`。纯 Dart 的同一套用例也可直接执行，无需 Flutter 引擎或真实收费服务：

```powershell
dart --disable-dart-dev --packages=.dart_tool/package_config.json tool/check_external_agent.dart
```

连接配置、费用与调用日志为本机数据，不进入云同步。API 不开放通用 shell 或任意设置键写入。
