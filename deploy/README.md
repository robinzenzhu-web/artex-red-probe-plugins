# 部署与运维

ScopeSentry + 自研插件的一键部署与守护脚本。

## 快速开始

```powershell
cd deploy
./deploy.ps1 -HostPort 19082
```

脚本会依次完成：

1. 检查 Docker 与端口占用（Windows 保留段）
2. 生成 `deploy/scopesentry/.env`（随机 mongo/redis 密码）
3. `docker compose up -d`（mongo / redis / server / scan 四容器）
4. 等 `scope-sentry` healthy
5. 从容器内 `PASSWORD` / `PLUGINKEY` 读凭据
6. 登录 → 创建 API Key
7. 导入 `web-fingerprint` + `site-poc`
8. `reinstall` + `recheck`，等 `install=1 check=1`
9. 灌 nuclei 模板（约 13853 个；`-SkipNuclei` 可跳过）
10. 投放 `subscription-packs/web-exposure-v1` 到 `/apps/ext/artex-poc`
11. 创建扫描模板 `artex-advanced`
12. 写出 `deploy/.deployment.env`

**幂等**：容器/插件/模板已存在会跳过，可反复执行。

## 产物

`deploy/.deployment.env`（含凭据，已被 `.gitignore` 排除）：

```
SCOPESENTRY_URL=http://127.0.0.1:19082
SCOPESENTRY_MCP_URL=http://127.0.0.1:19082/mcp
SCOPESENTRY_API_KEY=ssk_...
SCOPESENTRY_PLUGIN_KEY=...
SCOPESENTRY_ADMIN_USER=ScopeSentry
SCOPESENTRY_ADMIN_PASS=...
SCOPESENTRY_NODE=node-lab
ARTEX_TEMPLATE_ID=...
```

## ARTEX 侧接线

### 1. MCP 配置

```http
POST /api/mcp
{
  "id": 1,
  "name": "ScopeSentry",
  "transport": "http",
  "url": "http://127.0.0.1:19082/mcp",
  "env": { "X-API-Key": "<SCOPESENTRY_API_KEY>" },
  "enabled": true
}
```

验证：`GET /api/sync/scopesentry/status` 应返回 `reachable: true` 和 17 个工具。

### 2. 自动启动凭据（关键）

ScopeSentry 的 MCP `create_scan_task` **只建任务不启动**，而 REST `/api/task/start` 只认 JWT。ARTEX 侧会包装该工具并自动跟一个 start，需要：

```powershell
$env:ARTEX_SCOPESENTRY_USER = "ScopeSentry"
$env:ARTEX_SCOPESENTRY_PASS = "<SCOPESENTRY_ADMIN_PASS>"
```

不设这两个变量时包装器是纯透传，任务不会自动启动。

### 3. Agent 可见性（关键）

新装环境下 `agent_visibility.mcp` 是 `null`，17 个 MCP 工具**不会**暴露给任何 agent：

```http
PUT /api/agents/auto/visibility
{ "mcp": [1], "skill": ["api-recon", "scopesentry-mcp"] }
```

`skill` 里的 `scopesentry-mcp` 依赖 `skills/scopesentry/SKILL.md` 的 frontmatter 正确（`name` + `mcps: ScopeSentry`）。

## Watchdog

```powershell
./watchdog.ps1              # 单次检查
./watchdog.ps1 -Loop        # 常驻，默认 300s 间隔
./watchdog.ps1 -NoFix       # 只报告不修复
```

退出码：`0` 健康 / `1` 已自动修复 / `2` 需人工介入。

检测项：

| 症状 | 判定 | 动作 |
|---|---|---|
| `scopesentry-scan` 容器未运行 | 容器停止 | `docker start` |
| 节点 `state != 1` | 节点离线 | `docker restart` |
| 队列 `LLEN > 0` 且 `running = 0` | 队列卡死 | 清 `NodeTask:<node>` + 重启节点 |
| `running >= maxTaskNum` 且 mongo 无 `status=2` 任务 | 计数泄漏 | 同上 |

日志写入 `deploy/watchdog.log`。

## 已知缺陷（ScopeSentry 侧，无法改源码）

ScopeSentry 无 LICENSE，只能外部调用，不能改代码。以下行为需要运维兜底：

### 1. 节点重启后卡 5 分钟

内置 `ksubdomain` 插件在启动时执行 `v -f <target>` 检查，无外网时超时 5 分钟。期间节点 `state=1` 但不消费任务。

**无法绕过**（它是编译进二进制的内置插件，删 mongo 记录无效）。

对策：
- 重启后等 5 分钟再投任务
- 或让 watchdog 在 `queue > 0 && running == 0` 时也按卡死处理（默认行为）

### 2. 任务运行中 `status` 不更新

节点已 `Task begin`，但 `task.status` 仍为 `1`（不是 `2`）。ARTEX 侧已通过注解 `get_task` 结果缓解：

> status: 1 = queued（DB 滞后，可能已在执行）, 2 = running, 3 = finished

### 3. `/api/plugin/status` 对节点插件返 500

`failed to get plugin` —— 服务端 `GlobalPluginManager` 只持有服务端插件。DB 实际已更新，忽略错误，用 `install/check` 字段确认。

### 4. `create_scan_task` 不启动任务

已由 ARTEX 侧包装修复（见上文「自动启动凭据」）。

### 5. nuclei 参数过宽会拖死小目标

`-tags exposure` 仍有数百模板且会连 `oast.pro`。部署脚本已设为：

```
-tags springboot,swagger,git,jenkins,phpmyadmin,actuator -c 3 -bs 3 -rl 5 -ni
```

实测：同一目标从「5 分钟跑不完」降到「3.5 分钟，8 个发现」。

## 故障排查

```powershell
# 容器
docker ps -a | Select-String "scope"

# 服务端日志
docker logs scope-sentry --tail 50

# 节点日志（看 Task begin / timed out）
docker logs scopesentry-scan --tail 50

# 队列
docker exec scopesentry-redis redis-cli -a <REDIS_PASSWORD> --no-auth-warning LLEN "NodeTask:node-lab"

# 节点插件状态
curl -H "Authorization: Bearer <JWT>" http://127.0.0.1:19082/api/node/plugin
```

## 端口说明（Windows）

Windows 会保留大量端口段，Docker 绑定会失败：

```powershell
netsh int ipv4 show excludedportrange protocol=tcp
```

`deploy.ps1` 会检查并在冲突时报错。实测 `8082` 常落在保留段，默认改用 `19082`。
