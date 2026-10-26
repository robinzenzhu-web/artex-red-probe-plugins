<#
.SYNOPSIS
  Artex-red-probe 一键部署：ScopeSentry + 自研插件 + nuclei 模板 + 高级版扫描模板。

.DESCRIPTION
  幂等：已存在的容器 / 插件 / 模板会跳过，可反复执行。
  产物：deploy/.deployment.env（ARTEX 侧需要的连接信息）。

.PARAMETER HostPort
  ScopeSentry 在宿主机的映射端口，默认 19082。避开 Windows 保留段（netsh int ipv4 show excludedportrange protocol=tcp）。

.PARAMETER SkipNuclei
  跳过 nuclei 模板下载（已灌过可跳过，省 1 分钟）。

.PARAMETER NodeName
  扫描节点名，默认 node-lab。

.EXAMPLE
  ./deploy.ps1 -HostPort 19082
  ./deploy.ps1 -SkipNuclei
#>
[CmdletBinding()]
param(
    [int]$HostPort = 19082,
    [string]$NodeName = "node-lab",
    [switch]$SkipNuclei,
    [string]$NucleiTag = "v10.5.1"
)

$ErrorActionPreference = "Stop"
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$repoRoot = Split-Path -Parent $here
$labDir = Join-Path $here "scopesentry"
$envFile = Join-Path $here ".deployment.env"

function Info($m) { Write-Host "[*] $m" -ForegroundColor Cyan }
function Ok($m)   { Write-Host "[+] $m" -ForegroundColor Green }
function Warn($m) { Write-Host "[!] $m" -ForegroundColor Yellow }
function Die($m)  { Write-Host "[x] $m" -ForegroundColor Red; exit 1 }

# ---------- 0. 前置检查 ----------
Info "检查 Docker"
try { docker version --format '{{.Server.Version}}' | Out-Null } catch { Die "Docker 不可用" }
Ok "Docker OK"

# Windows 保留端口检查
if ($IsWindows) {
    $excluded = netsh int ipv4 show excludedportrange protocol=tcp 2>$null
    $ranges = @()
    foreach ($line in $excluded) {
        if ($line -match '^\s*(\d+)\s+(\d+)') { $ranges += ,@([int]$Matches[1], [int]$Matches[2]) }
    }
    foreach ($r in $ranges) {
        if ($HostPort -ge $r[0] -and $HostPort -le $r[1]) {
            Die "端口 $HostPort 落在 Windows 保留段 $($r[0])-$($r[1])，换一个（如 19082）"
        }
    }
}

# ---------- 1. compose 文件 ----------
New-Item -ItemType Directory -Path $labDir -Force | Out-Null
foreach ($d in @("data\mongodb", "data\redis\data", "data\files", "data\images", "data\uploads")) {
    New-Item -ItemType Directory -Path (Join-Path $labDir $d) -Force | Out-Null
}

$envPath = Join-Path $labDir ".env"
if (-not (Test-Path $envPath)) {
    $mongoPass = -join ((48..57) + (65..90) + (97..122) | Get-Random -Count 24 | ForEach-Object { [char]$_ })
    $redisPass = -join ((48..57) + (65..90) + (97..122) | Get-Random -Count 24 | ForEach-Object { [char]$_ })
    @"
MONGO_INITDB_ROOT_USERNAME=admin
MONGO_INITDB_ROOT_PASSWORD=$mongoPass
REDIS_PASSWORD=$redisPass
"@ | Set-Content -Path $envPath -Encoding UTF8
    Ok "生成 .env（随机密码）"
} else { Ok ".env 已存在，复用" }

$composePath = Join-Path $labDir "docker-compose.yml"
@"
networks:
  scopesentry-network:
    name: scopesentry-network
    driver: bridge

services:
  mongodb:
    image: mongo:7.0.28
    container_name: scopesentry-mongodb
    restart: unless-stopped
    ports:
      - "27017:27017"
    environment:
      MONGO_INITDB_ROOT_USERNAME: `${MONGO_INITDB_ROOT_USERNAME}
      MONGO_INITDB_ROOT_PASSWORD: `${MONGO_INITDB_ROOT_PASSWORD}
    volumes:
      - ./data/mongodb:/data/db
    healthcheck:
      test: ["CMD", "mongosh", "-u", "`${MONGO_INITDB_ROOT_USERNAME}", "-p", "`${MONGO_INITDB_ROOT_PASSWORD}", "--authenticationDatabase", "admin", "--eval", "db.adminCommand('ping')"]
      interval: 10s
      timeout: 5s
      retries: 15
    networks:
      - scopesentry-network

  redis:
    image: redis:7.0.11
    container_name: scopesentry-redis
    restart: unless-stopped
    ports:
      - "6379:6379"
    command: redis-server --requirepass `${REDIS_PASSWORD}
    volumes:
      - ./data/redis/data:/data
    healthcheck:
      test: ["CMD", "redis-cli", "-a", "`${REDIS_PASSWORD}", "ping"]
      interval: 10s
      timeout: 5s
      retries: 10
    networks:
      - scopesentry-network

  scope-sentry:
    image: autumn27/scopesentry:latest
    container_name: scope-sentry
    restart: unless-stopped
    ports:
      - "${HostPort}:8082"
    environment:
      TIMEZONE: Asia/Shanghai
      MONGODB_IP: scopesentry-mongodb
      MONGODB_PORT: 27017
      MONGODB_DATABASE: ScopeSentry
      MONGODB_USER: `${MONGO_INITDB_ROOT_USERNAME}
      MONGODB_PASSWORD: `${MONGO_INITDB_ROOT_PASSWORD}
      REDIS_IP: scopesentry-redis
      REDIS_PORT: 6379
      REDIS_PASSWORD: `${REDIS_PASSWORD}
    healthcheck:
      test: ["CMD-SHELL", "curl -f http://127.0.0.1:8082 || exit 1"]
      interval: 20s
      timeout: 10s
      retries: 20
      start_period: 40s
    depends_on:
      redis:
        condition: service_healthy
      mongodb:
        condition: service_healthy
    volumes:
      - ./data/files:/opt/ScopeSentry/files
      - ./data/images:/opt/ScopeSentry/images
      - ./data/uploads:/opt/ScopeSentry/uploads
    networks:
      - scopesentry-network

  scopesentry-scan:
    image: autumn27/scopesentry-scan:latest
    container_name: scopesentry-scan
    restart: unless-stopped
    environment:
      NodeName: ${NodeName}
      TimeZoneName: Asia/Shanghai
      MONGODB_IP: scopesentry-mongodb
      MONGODB_PORT: 27017
      MONGODB_DATABASE: ScopeSentry
      MONGODB_USER: `${MONGO_INITDB_ROOT_USERNAME}
      MONGODB_PASSWORD: `${MONGO_INITDB_ROOT_PASSWORD}
      REDIS_IP: scopesentry-redis
      REDIS_PORT: 6379
      REDIS_PASSWORD: `${REDIS_PASSWORD}
    depends_on:
      redis:
        condition: service_healthy
      scope-sentry:
        condition: service_healthy
    networks:
      - scopesentry-network
"@ | Set-Content -Path $composePath -Encoding UTF8

# ---------- 2. 启动 ----------
Info "启动 ScopeSentry（首次拉镜像可能较慢）"
Push-Location $labDir
try { docker compose up -d 2>&1 | Out-Null } finally { Pop-Location }

Info "等待 scope-sentry healthy（最多 180s）"
$deadline = (Get-Date).AddSeconds(180)
$healthy = $false
while ((Get-Date) -lt $deadline) {
    $st = docker inspect --format '{{.State.Health.Status}}' scope-sentry 2>$null
    if ($st -eq "healthy") { $healthy = $true; break }
    Start-Sleep -Seconds 5
}
if (-not $healthy) { Die "scope-sentry 未在 180s 内 healthy，检查 docker logs scope-sentry" }
Ok "scope-sentry healthy"

# ---------- 3. 读凭据 ----------
Info "读取管理员密码与插件密钥"
$adminPass = (docker exec scope-sentry cat /opt/ScopeSentry/PASSWORD 2>$null | Out-String).Trim()
$pluginKey = (docker exec scope-sentry cat /opt/ScopeSentry/PLUGINKEY 2>$null | Out-String).Trim()
if (-not $adminPass) { Die "读不到 PASSWORD" }
if (-not $pluginKey) { Die "读不到 PLUGINKEY" }
Ok "凭据已读取"

$base = "http://127.0.0.1:$HostPort"

# ---------- 4. 登录 ----------
Info "登录 ScopeSentry"
$loginBody = @{ username = "ScopeSentry"; password = $adminPass } | ConvertTo-Json
try {
    $login = Invoke-RestMethod -Uri "$base/api/user/login" -Method POST -ContentType "application/json" -Body $loginBody
} catch { Die "登录失败：$($_.Exception.Message)" }
$jwt = $login.data.access_token
if (-not $jwt) { Die "登录未返回 access_token" }
$auth = @{ Authorization = "Bearer $jwt" }
Ok "登录成功"

# ---------- 5. API Key（复用或新建） ----------
Info "准备 API Key"
$apiKey = $null
try {
    $keys = (Invoke-RestMethod -Uri "$base/api/apikey/list" -Method GET -Headers $auth).data.list
    $reusable = $keys | Where-Object { $_.name -eq "artex-red-probe" } | Select-Object -First 1
} catch { $reusable = $null }
if ($reusable) {
    Warn "API Key 明文只在创建时返回，无法复用；新建一个"
}
$created = Invoke-RestMethod -Uri "$base/api/apikey/create" -Method POST -Headers $auth `
    -ContentType "application/json" -Body (@{ name = "artex-red-probe" } | ConvertTo-Json)
$apiKey = $created.data.key
if (-not $apiKey) { Die "创建 API Key 失败" }
Ok "API Key 已创建"

# ---------- 6. 导入插件 ----------
function Import-Plugin($name, $dir) {
    $info = (Get-Content (Join-Path $dir "info.json") -Raw -Encoding UTF8).Trim()
    $src = Get-Content (Join-Path $dir "plugin.go") -Raw -Encoding UTF8
    $body = @{ json = $info; source = $src; isSystem = $false; key = $pluginKey } | ConvertTo-Json -Depth 5
    try {
        $r = Invoke-RestMethod -Uri "$base/api/plugin/import/data" -Method POST -Headers $auth `
            -ContentType "application/json; charset=utf-8" -Body ([Text.Encoding]::UTF8.GetBytes($body))
        Ok "导入 $name"
    } catch {
        if ($_.ErrorDetails.Message -match "already exists|duplicate") { Warn "$name 已存在，跳过" }
        else { Die "导入 $name 失败：$($_.ErrorDetails.Message)" }
    }
}

Info "导入插件"
Import-Plugin "web-fingerprint" (Join-Path $repoRoot "AssetHandle\web-fingerprint")
Import-Plugin "site-poc"        (Join-Path $repoRoot "VulnerabilityScan\site-poc")

# ---------- 7. 启用 + 装到节点 ----------
Info "启用插件并安装到节点 $NodeName"
$all = (Invoke-RestMethod -Uri "$base/api/plugin" -Method POST -Headers $auth `
    -ContentType "application/json" -Body (@{ pageIndex = 1; pageSize = 200 } | ConvertTo-Json)).data.list

$targets = @()
foreach ($pair in @(@{ n = "web-fingerprint"; m = "AssetHandle" }, @{ n = "site-poc"; m = "VulnerabilityScan" })) {
    # 取该名字下最新版本（同 name 可能有多条历史版本）
    $p = $all | Where-Object { $_.name -eq $pair.n } | Select-Object -Last 1
    if (-not $p) { Die "插件 $($pair.n) 不在列表里" }
    $targets += ,@{ n = $pair.n; m = $pair.m; hash = $p.hash }
    # status 接口对节点插件会返 500（DB 已更新），忽略
    try { Invoke-RestMethod -Uri "$base/api/plugin/status" -Method POST -Headers $auth `
        -ContentType "application/json" -Body (@{ id = $p.hash; status = $true } | ConvertTo-Json) | Out-Null } catch {}
    foreach ($act in @("reinstall", "recheck")) {
        try {
            Invoke-RestMethod -Uri "$base/api/plugin/$act" -Method POST -Headers $auth `
                -ContentType "application/json" -Body (@{ node = $NodeName; hash = $p.hash; module = $pair.m } | ConvertTo-Json) | Out-Null
        } catch { Warn "$act $($pair.n) 失败：$($_.Exception.Message)" }
    }
}

Info "等待插件 check=1（最多 60s）"
$deadline = (Get-Date).AddSeconds(60)
while ((Get-Date) -lt $deadline) {
    $np = (Invoke-RestMethod -Uri "$base/api/node/plugin" -Method POST -Headers $auth `
        -ContentType "application/json" -Body (@{ name = $NodeName } | ConvertTo-Json)).data.list
    $ready = $true
    foreach ($t in $targets) {
        $row = $np | Where-Object { $_.hash -eq $t.hash } | Select-Object -First 1
        if (-not $row -or $row.install -ne "1" -or $row.check -ne "1") { $ready = $false }
    }
    if ($ready) { Ok "插件全部 install=1 check=1"; break }
    Start-Sleep -Seconds 5
}
if (-not $ready) { Warn "插件未全部就绪，检查 docker logs scopesentry-scan" }

# ---------- 8. nuclei 模板 ----------
if (-not $SkipNuclei) {
    $count = (docker exec scopesentry-scan sh -c "find /apps/poc -name '*.yaml' 2>/dev/null | wc -l" | Out-String).Trim()
    if ([int]$count -gt 1000) {
        Ok "nuclei 模板已存在（$count 个），跳过"
    } else {
        Info "下载 nuclei-templates $NucleiTag（约 20MB）"
        $zip = Join-Path $here "nuclei-templates.zip"
        $url = "https://github.com/projectdiscovery/nuclei-templates/archive/refs/tags/$NucleiTag.zip"
        try { Invoke-WebRequest -Uri $url -OutFile $zip -TimeoutSec 600 } catch {
            Warn "官方源失败，尝试镜像"
            Invoke-WebRequest -Uri "https://ghfast.top/$url" -OutFile $zip -TimeoutSec 600
        }
        $ex = Join-Path $here "nuclei-templates"
        Remove-Item $ex -Recurse -Force -ErrorAction SilentlyContinue
        Expand-Archive -Path $zip -DestinationPath $ex -Force
        $inner = (Get-ChildItem $ex -Directory | Select-Object -First 1).FullName
        $tar = Join-Path $here "nuclei-core.tar"
        Push-Location $inner
        try { tar -cf $tar http dns ssl helpers network file headless javascript workflows profiles cloud code } finally { Pop-Location }
        docker cp $tar scopesentry-scan:/tmp/nuclei-core.tar
        docker exec scopesentry-scan sh -c "cd /apps/poc && tar -xf /tmp/nuclei-core.tar && rm -f /tmp/nuclei-core.tar"
        $n = (docker exec scopesentry-scan sh -c "find /apps/poc -name '*.yaml' | wc -l" | Out-String).Trim()
        Ok "nuclei 模板就绪（$n 个）"
        Remove-Item $zip, $tar -Force -ErrorAction SilentlyContinue
    }
} else { Warn "跳过 nuclei 模板" }

# ---------- 9. PoC 目录 ----------
Info "准备 PoC 模板目录 /apps/ext/artex-poc"
docker exec scopesentry-scan sh -c "mkdir -p /apps/ext/artex-poc" | Out-Null
$packDir = Join-Path $repoRoot "subscription-packs\web-exposure-v1\templates"
if (Test-Path $packDir) {
    docker cp "$packDir\." scopesentry-scan:/apps/ext/artex-poc/
    Ok "已投放 web-exposure-v1"
} else {
    Warn "未找到 subscription-packs/web-exposure-v1，site-poc 将无规则可匹配"
}

# ---------- 10. 高级版扫描模板 ----------
Info "创建扫描模板 artex-advanced"
$tplId = $null
$existing = (Invoke-RestMethod -Uri "$base/api/task/template" -Method POST -Headers $auth `
    -ContentType "application/json" -Body (@{ search = "artex-advanced"; pageIndex = 1; pageSize = 20 } | ConvertTo-Json)).data.list |
    Where-Object { $_.name -eq "artex-advanced" } | Select-Object -First 1

if ($existing) {
    $tplId = $existing.id
    Warn "模板已存在，复用 id=$tplId（如需重建请先删除）"
} else {
    $def = (Invoke-RestMethod -Uri "$base/api/task/template/detail" -Method POST -Headers $auth `
        -ContentType "application/json" -Body (@{ id = ((Invoke-RestMethod -Uri "$base/api/task/template" -Method POST -Headers $auth `
        -ContentType "application/json" -Body (@{ search = "default"; pageIndex = 1; pageSize = 20 } | ConvertTo-Json)).data.list |
        Where-Object { $_.name -eq "default" } | Select-Object -First 1).id } | ConvertTo-Json)).data
    $def.PSObject.Properties.Remove("id")
    $def.name = "artex-advanced"
    $def.isStart = $false; $def.TaskName = ""

    # 只保留 mapping / 指纹 / PoC 三段，避免 subfinder/rustscan 拖时间
    foreach ($m in @("TargetHandler", "SubdomainScan", "SubdomainSecurity", "PortScanPreparation", "PortScan",
                     "PortFingerprint", "URLScan", "WebCrawler", "URLSecurity", "DirScan")) {
        $def.$m = @()
        $def.Parameters.$m = [pscustomobject]@{}
    }
    $mapHash = ($def.AssetMapping | Select-Object -First 1)
    if (-not $mapHash) { Die "default 模板缺少 AssetMapping，无法克隆" }
    $def.Parameters.AssetMapping = [pscustomobject]@{ $mapHash = "-cdncheck false -screenshot false" }

    $fpHash = ($targets | Where-Object { $_.n -eq "web-fingerprint" }).hash
    $pocHash = ($targets | Where-Object { $_.n -eq "site-poc" }).hash
    $nucleiHash = ($def.Parameters.VulnerabilityScan.PSObject.Properties.Name | Select-Object -First 1)

    $def.AssetHandle = @($fpHash)
    $def.Parameters.AssetHandle = [pscustomobject]@{ $fpHash = "" }
    $def.VulnerabilityScan = @($pocHash, $nucleiHash)
    $def.Parameters.VulnerabilityScan = [pscustomobject]@{
        $pocHash    = "-templates /apps/ext/artex-poc"
        $nucleiHash = "-tags springboot,swagger,git,jenkins,phpmyadmin,actuator -c 3 -bs 3 -rl 5 -ni"
    }

    $saveBody = @{ result = $def; id = "" } | ConvertTo-Json -Depth 12
    Invoke-RestMethod -Uri "$base/api/task/template/save" -Method POST -Headers $auth `
        -ContentType "application/json; charset=utf-8" -Body ([Text.Encoding]::UTF8.GetBytes($saveBody)) | Out-Null
    $tplId = ((Invoke-RestMethod -Uri "$base/api/task/template" -Method POST -Headers $auth `
        -ContentType "application/json" -Body (@{ search = "artex-advanced"; pageIndex = 1; pageSize = 20 } | ConvertTo-Json)).data.list |
        Where-Object { $_.name -eq "artex-advanced" } | Select-Object -First 1).id
    Ok "模板已创建 id=$tplId"
}

# ---------- 11. 输出配置 ----------
@"
# Artex-red-probe 部署产物（勿提交到 Git）
SCOPESENTRY_URL=$base
SCOPESENTRY_MCP_URL=$base/mcp
SCOPESENTRY_API_KEY=$apiKey
SCOPESENTRY_PLUGIN_KEY=$pluginKey
SCOPESENTRY_ADMIN_USER=ScopeSentry
SCOPESENTRY_ADMIN_PASS=$adminPass
SCOPESENTRY_NODE=$NodeName
ARTEX_TEMPLATE_ID=$tplId
"@ | Set-Content -Path $envFile -Encoding UTF8

Write-Host ""
Ok "部署完成"
Write-Host ""
Write-Host "  产物: $envFile" -ForegroundColor Cyan
Write-Host "  ScopeSentry: $base" -ForegroundColor Cyan
Write-Host "  模板 ID: $tplId" -ForegroundColor Cyan
Write-Host ""
Write-Host "  下一步（ARTEX 侧）:" -ForegroundColor Yellow
Write-Host "    `$env:ARTEX_SCOPESENTRY_USER='ScopeSentry'"
Write-Host "    `$env:ARTEX_SCOPESENTRY_PASS='$adminPass'"
Write-Host "    在 ARTEX 里创建 MCP: transport=http url=$base/mcp env={X-API-Key:$apiKey}"
Write-Host "    给 agent 设可见性: PUT /api/agents/auto/visibility {mcp:[<id>], skill:[`"api-recon`",`"scopesentry-mcp`"]}"
Write-Host ""
Write-Host "  注意: 扫描节点重启后需等约 5 分钟（内置 ksubdomain 检查超时）才可用" -ForegroundColor Yellow
