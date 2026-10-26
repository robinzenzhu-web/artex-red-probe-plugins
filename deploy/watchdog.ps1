<#
.SYNOPSIS
  ScopeSentry 节点守护：检测队列堆积 / running 计数泄漏 / 节点离线，并自动恢复。

.DESCRIPTION
  已知缺陷（ScopeSentry 侧，无法改源码）：
    1. 节点 running 计数会泄漏——重启容器不清，任务永久 pending。
    2. Redis 队列有任务但节点不消费——必须重启节点才恢复。
    3. 节点重启后内置 ksubdomain 检查会卡约 5 分钟。

  本脚本轮询上述状态并做最小修复：清 NodeTask 队列 + 重启 scan 容器。
  退出码：0 = 健康；1 = 已自动修复；2 = 需人工介入。

.PARAMETER Loop
  持续运行（默认单次检查）。

.PARAMETER IntervalSec
  循环间隔秒数，默认 300。

.PARAMETER NoFix
  只报告不修复。

.EXAMPLE
  ./watchdog.ps1
  ./watchdog.ps1 -Loop -IntervalSec 300
#>
[CmdletBinding()]
param(
    [switch]$Loop,
    [int]$IntervalSec = 300,
    [switch]$NoFix
)

$ErrorActionPreference = "Continue"
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$envFile = Join-Path $here ".deployment.env"
$logFile = Join-Path $here "watchdog.log"

function Log($msg, $level = "INFO") {
    $line = "[{0}] [{1}] {2}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss"), $level, $msg
    Write-Host $line
    Add-Content -Path $logFile -Value $line -Encoding UTF8
}

if (-not (Test-Path $envFile)) {
    Log "缺少 $envFile，先跑 deploy.ps1" "ERROR"
    exit 2
}

# 读部署产物
$cfg = @{}
foreach ($line in Get-Content $envFile -Encoding UTF8) {
    if ($line -match '^\s*([A-Z_]+)\s*=\s*(.*)$') { $cfg[$Matches[1]] = $Matches[2].Trim() }
}
$base = $cfg["SCOPESENTRY_URL"]
$node = $cfg["SCOPESENTRY_NODE"]
$user = $cfg["SCOPESENTRY_ADMIN_USER"]
$pass = $cfg["SCOPESENTRY_ADMIN_PASS"]
if (-not $base -or -not $node) { Log ".deployment.env 缺少 SCOPESENTRY_URL/NODE" "ERROR"; exit 2 }

function Get-Jwt {
    try {
        $r = Invoke-RestMethod -Uri "$base/api/user/login" -Method POST -ContentType "application/json" `
            -Body (@{ username = $user; password = $pass } | ConvertTo-Json) -TimeoutSec 15
        return $r.data.access_token
    } catch { return $null }
}

function Invoke-Check {
    $jwt = Get-Jwt
    if (-not $jwt) { Log "登录失败（ScopeSentry 不可达？）" "ERROR"; return 2 }
    $auth = @{ Authorization = "Bearer $jwt" }

    # --- 1. 容器状态 ---
    $running = (docker inspect --format '{{.State.Running}}' scopesentry-scan 2>$null | Out-String).Trim()
    if ($running -ne "true") {
        Log "scan 容器未运行" "ERROR"
        if (-not $NoFix) {
            docker start scopesentry-scan 2>&1 | Out-Null
            Log "已启动 scan 容器；注意需等约 5 分钟 ksubdomain 检查" "FIX"
            return 1
        }
        return 2
    }

    # --- 2. 节点在线状态 ---
    try {
        $nodes = (Invoke-RestMethod -Uri "$base/api/node" -Method GET -Headers $auth -TimeoutSec 15).data.list
    } catch { Log "查询节点失败：$($_.Exception.Message)" "ERROR"; return 2 }
    $n = $nodes | Where-Object { $_.name -eq $node } | Select-Object -First 1
    if (-not $n) { Log "节点 $node 不存在" "ERROR"; return 2 }
    if ($n.state -ne "1") {
        Log "节点 $node 离线（state=$($n.state)）" "WARN"
        if (-not $NoFix) {
            docker restart scopesentry-scan 2>&1 | Out-Null
            Log "已重启 scan 容器" "FIX"
            return 1
        }
        return 2
    }

    # --- 3. 队列 vs 运行数 ---
    $redisPass = $null
    $envPath = Join-Path (Join-Path $here "scopesentry") ".env"
    if (Test-Path $envPath) {
        foreach ($line in Get-Content $envPath -Encoding UTF8) {
            if ($line -match '^\s*REDIS_PASSWORD\s*=\s*(.*)$') { $redisPass = $Matches[1].Trim() }
        }
    }
    $queueLen = -1
    if ($redisPass) {
        $raw = (docker exec scopesentry-redis redis-cli -a $redisPass --no-auth-warning LLEN "NodeTask:$node" 2>$null | Out-String).Trim()
        if ($raw -match '^\d+$') { $queueLen = [int]$raw }
    } else { Log "读不到 REDIS_PASSWORD，跳过队列检查" "WARN" }

    $runCount = [int]$n.running
    $finCount = [int]$n.finished
    Log "节点 ${node}: state=$($n.state) running=$runCount finished=$finCount queue=$queueLen"

    # 队列有货但节点不干活 → 队列卡死
    if ($queueLen -gt 0 -and $runCount -eq 0) {
        Log "队列堆积 $queueLen 条但 running=0，判定队列卡死" "WARN"
        if (-not $NoFix) {
            docker exec scopesentry-redis redis-cli -a $redisPass --no-auth-warning DEL "NodeTask:$node" 2>&1 | Out-Null
            Log "已清空 NodeTask:$node" "FIX"
            docker restart scopesentry-scan 2>&1 | Out-Null
            Log "已重启 scan 容器；需等约 5 分钟 ksubdomain 检查" "FIX"
            return 1
        }
        return 2
    }

    # running 计数超过节点上限（maxTaskNum）→ 计数泄漏
    $maxTask = [int]$n.maxTaskNum
    if ($maxTask -gt 0 -and $runCount -ge $maxTask -and $queueLen -gt 0) {
        # 交叉验证：mongo 里是否真有 status=2 的任务
        $mongoPass = $null
        if (Test-Path $envPath) {
            foreach ($line in Get-Content $envPath -Encoding UTF8) {
                if ($line -match '^\s*MONGO_INITDB_ROOT_PASSWORD\s*=\s*(.*)$') { $mongoPass = $Matches[1].Trim() }
            }
        }
        if ($mongoPass) {
            $active = (docker exec scopesentry-mongodb mongosh -u admin -p $mongoPass --authenticationDatabase admin --quiet `
                --eval 'db.getSiblingDB("ScopeSentry").task.countDocuments({status:2})' 2>$null | Out-String).Trim()
            if ($active -match '^\d+$' -and [int]$active -eq 0) {
                Log "running=$runCount 但 mongo 无 status=2 任务，判定计数泄漏" "WARN"
                if (-not $NoFix) {
                    docker exec scopesentry-redis redis-cli -a $redisPass --no-auth-warning DEL "NodeTask:$node" 2>&1 | Out-Null
                    docker restart scopesentry-scan 2>&1 | Out-Null
                    Log "已清队列并重启节点" "FIX"
                    return 1
                }
                return 2
            }
        }
    }

    Log "健康"
    return 0
}

if ($Loop) {
    Log "watchdog 启动，间隔 ${IntervalSec}s"
    while ($true) {
        $rc = Invoke-Check
        Start-Sleep -Seconds $IntervalSec
    }
} else {
    $rc = Invoke-Check
    exit $rc
}
