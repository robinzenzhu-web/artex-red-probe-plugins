# 安装到 ScopeSentry（高级版）

## 前置

1. 已部署 ScopeSentry（mongo + redis + server + scan）
2. 插件二次校验密码（`docker logs scope-sentry`）
3. ARTEX MCP 已配置 `ScopeSentry`（url + X-API-Key）

## 1. 安装插件

1. 上传 `AssetHandle/web-fingerprint`（info.json + plugin.go）
2. 上传 `VulnerabilityScan/site-poc`
3. 启用，记下 hash
4. 节点上 reinstall + recheck，确认 `install=1 check=1`

```bash
# API 方式（web-fingerprint 示例）
POST /api/plugin/import/data   {"json":..., "source":..., "isSystem":false, "key":"<PLUGINKEY>"}
POST /api/plugin/reinstall     {"node":"node-lab","hash":"<hash>","module":"AssetHandle"}
POST /api/plugin/recheck       {"node":"node-lab","hash":"<hash>","module":"AssetHandle"}
```

> 注意：`POST /api/plugin/status` 对**扫描节点插件**会返回 500（`failed to get plugin`），因为 `GlobalPluginManager` 只持有服务端 yaegi 插件。DB 状态其实已更新，忽略该错误即可，用 `install/check` 字段确认。

## 2. 部署 nuclei 模板（必须）

nuclei 编译在 `ScopeSentry-Scan` 二进制内，**没有独立 CLI**，模板目录由 `~/.config/nuclei/.templates-config.json` 指定（默认 `/apps/poc`），**初始为空**。

```bash
# 宿主机
curl -L -o nt.zip https://github.com/projectdiscovery/nuclei-templates/archive/refs/tags/v10.5.1.zip
unzip nt.zip
cd nuclei-templates-10.5.1
tar -cf /tmp/nuclei-core.tar http dns ssl helpers network file headless javascript workflows profiles cloud code
docker cp /tmp/nuclei-core.tar scopesentry-scan:/tmp/
docker exec scopesentry-scan sh -c "cd /apps/poc && tar -xf /tmp/nuclei-core.tar && rm /tmp/nuclei-core.tar"
docker exec scopesentry-scan sh -c "find /apps/poc -name '*.yaml' | wc -l"   # 预期 ~13853
```

未部署时日志会出现 `Nuclei ... cause="No templates available"`。

## 3. 订阅 PoC 包

```bash
mkdir -p /apps/ext/artex-poc
# 从订阅服务拉 subscription-packs/web-exposure-v1/templates/*.json 到该目录
```

`site-poc` 参数：`-templates /apps/ext/artex-poc`

## 4. 建高级版模板

`create_scan_template`，流水线：

1. 目标/子域/端口（官方模块）
2. **AssetMapping**（httpx，必须在前）
3. **web-fingerprint**
4. **site-poc**（`-templates /apps/ext/artex-poc`）
5. **内置 nuclei**（建议 `-tags exposure,misconfig -c 5 -bs 5 -rl 10`）

### nuclei 参数建议

| 参数 | 说明 |
|---|---|
| `-tags exposure` | 只跑暴露面类（快，适合常规核查） |
| `-s high,critical` | 按严重度过滤 |
| `-c 5 -bs 5 -rl 10` | **必须限速**，否则并发会打挂小目标（实测把单线程服务打到 `unresponsive 30 times`） |

## 5. 验证

```
list_plugins
list_scan_templates
create_scan_task        # 小范围授权目标
get_asset_detail        # tags / technologies / vulns
```

## 已知坑

### 节点 running 计数泄漏

任务永久 `pending`（`status=1 progress=0`），节点 `running` 卡在 maxTaskNum，但 mongo 里没有 `status=2` 的任务。

```bash
docker exec scopesentry-redis redis-cli -a <REDIS_PASSWORD> --no-auth-warning DEL "NodeTask:<node-name>"
docker restart scopesentry-scan
```

### 资产 body 不在 list_assets 返回

`list_assets` 的 `asset` 记录 `body` 恒为空，body 存在独立的 `HttpBody` 集合。不要用 list_assets 判断 body 内容，用 `get_asset_detail`。

### 路径归一化

`AssetMapping`(httpx) 可能把 `http://host:port/path` 归一化为 `host:port`，路径丢失后 site-poc 只能判定首页。需要路径级判定时用 nuclei 主动探测。

## 注意

- ScopeSentry 无 LICENSE：只分发自写插件，不要打包 ScopeSentry
- 本产品不做基础版裁剪；默认即高级版完整链路
