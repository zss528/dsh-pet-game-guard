#requires -version 5.1
<#
.SYNOPSIS
    DSH 桌宠 · 游戏自动隐藏（pet game guard）

.DESCRIPTION
    检测到「游戏进程」或「全屏前台窗口」时，把 dsh-pet 桌宠隐藏；游戏退出后自动恢复。
    只依赖 dsh-pet 自带的本地 HTTP 接口（POST <DSH>/dsh-pet-7340/pet-display），
    不需要改插件、不需要管理员权限。

.PARAMETER Install
    安装：写默认配置 + 在「启动」文件夹创建快捷方式，并立即后台启动。

.PARAMETER Uninstall
    卸载：删除启动项，并尽量把桌宠恢复成显示状态。

.PARAMETER Status
    体检：找到的 DSH 端口、每只宠物的当前 display、此刻的判定结果，然后退出。

.PARAMETER DryRun
    试运行：只打印「现在该隐藏还是该恢复」，不真的改桌宠。配合 -Once 用。

.PARAMETER Once
    跑 N 轮后退出（默认 0 = 常驻）。用于调试。

.PARAMETER SimulateSeconds
    自测：强制判定为「游戏中」N 秒，用来验证隐藏/恢复正常。

.PARAMETER ConfigPath
    自定义配置文件路径（默认同目录 pet-game-guard.config.json）。

.EXAMPLE
    powershell -NoProfile -ExecutionPolicy Bypass -File .\PetGameGuard.ps1 -Install

.EXAMPLE
    powershell -NoProfile -ExecutionPolicy Bypass -File .\PetGameGuard.ps1 -Status
#>
[CmdletBinding()]
param(
    [int]$PollSeconds = 3,
    [string]$ConfigPath = '',
    [switch]$Install,
    [switch]$Uninstall,
    [switch]$Status,
    [switch]$DryRun,
    [int]$Once = 0,
    [int]$SimulateSeconds = 0,
    [string]$InstanceTag = 'main'
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0

$scriptDir = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
if (-not $ConfigPath) { $ConfigPath = Join-Path $scriptDir 'pet-game-guard.config.json' }
$logPath = Join-Path $scriptDir 'pet-game-guard.log'
$statePath = Join-Path $scriptDir 'pet-game-guard.state'
$scriptPath = if ($PSCommandPath) { $PSCommandPath } else { Join-Path $scriptDir 'PetGameGuard.ps1' }

# ───────────────────────────── 日志 ─────────────────────────────
$script:lastLogKey = ''
function Write-Log {
    param([string]$Message, [string]$Key = '')
    $line = '[{0}] {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Message
    try {
        if ((Test-Path $logPath) -and ((Get-Item $logPath).Length -gt 1MB)) {
            Move-Item -LiteralPath $logPath -Destination "$logPath.1" -Force
        }
        Add-Content -LiteralPath $logPath -Value $line -Encoding UTF8
    } catch { }
    Write-Host $line
    if ($Key) { $script:lastLogKey = $Key }
}

# ───────────────────────────── 配置 ─────────────────────────────
# 默认配置：只放"绝大多数人开箱即用"的规则；用户配置里的 processes 会整体覆盖，extraProcesses 只追加。
$defaultConfig = [ordered]@{
    restoreDisplay   = 'desktop'   # 游戏退出后恢复成什么：desktop / none
    hideOnFullscreen = $true       # 无匹配进程时，是否也按"全屏前台窗口"判定
    pollSeconds      = 3           # 轮询间隔（秒）
    dshPort          = 0           # 0 = 自动探测；填了就不自动找端口
    routePrefix      = '/dsh-pet-7340'  # dsh-pet 的 HTTP 路由前缀
    heartbeatMinutes = 60          # 每隔多久写一条心跳日志（0 = 不写）
    processes        = @()
    extraProcesses   = @(
        '*Win64-Shipping'    # 虚幻引擎游戏（三角洲、无畏契约打包版、多数 3A）
        '*Win32-Shipping'
        'DeltaForce*', 'GenshinImpact', 'YuanShen', 'StarRail', 'ZenlessZoneZero'
        'League*', 'cs2', 'dota2', 'VALORANT*', 'valorant*'
        'GTA5*', 'RDR2*', 'Cyberpunk2077', 'EldenRing', 'Forza*'
        'Minecraft*', 'Terraria', 'Stardew*'
        'ApexLegends*', 'r5apex*', 'Overwatch*', 'PUBG*', 'TslGame'
        'Palworld*', 'BaldursGate3', 'HogwartsLegacy', 'Sekiro*', 'DarkSouls*'
    )
}

function Get-GuardConfig {
    $cfg = [ordered]@{}
    foreach ($k in $defaultConfig.Keys) { $cfg[$k] = $defaultConfig[$k] }
    if (-not (Test-Path -LiteralPath $ConfigPath)) { return [pscustomobject]$cfg }
    try {
        $raw = Get-Content -LiteralPath $ConfigPath -Raw -Encoding UTF8
        if (-not $raw.Trim()) { return [pscustomobject]$cfg }
        $user = $raw | ConvertFrom-Json
        foreach ($k in @($user.PSObject.Properties.Name)) {
            switch ($k) {
                'processes'      { if ($user.processes) { $cfg['processes'] = @($user.processes) } }
                'extraProcesses' { if ($user.extraProcesses) { $cfg['extraProcesses'] = @($user.extraProcesses) } }
                'dshPort'        { $cfg['dshPort'] = [int]$user.dshPort }
                'pollSeconds'    { if ([int]$user.pollSeconds -ge 1) { $cfg['pollSeconds'] = [int]$user.pollSeconds } }
                'routePrefix'    { if ($user.routePrefix) { $cfg['routePrefix'] = [string]$user.routePrefix } }
                'restoreDisplay' { if ($user.restoreDisplay) { $cfg['restoreDisplay'] = [string]$user.restoreDisplay } }
                'hideOnFullscreen' { if ($null -ne $user.hideOnFullscreen) { $cfg['hideOnFullscreen'] = [bool]$user.hideOnFullscreen } }
                'heartbeatMinutes' { if ($null -ne $user.heartbeatMinutes) { $cfg['heartbeatMinutes'] = [int]$user.heartbeatMinutes } }
            }
        }
    } catch {
        Write-Log "配置文件解析失败，已回退默认值：$($_.Exception.Message)"
    }
    if ($cfg.restoreDisplay -eq 'none') { $cfg.restoreDisplay = 'desktop' }
    # 规则合并：用户给了 processes 就认为"我要完全自己定"；否则用默认规则 + extraProcesses。
    if ($cfg.processes -and @($cfg.processes).Count -gt 0) {
        $all = @($cfg.processes)
    } else {
        $all = @($cfg.extraProcesses)
    }
    $cfg['processes'] = @($all | Where-Object { $_ } | Select-Object -Unique)
    return [pscustomobject]$cfg
}

# ───────────────────────────── Win32 ─────────────────────────────
if (-not ('PetGuardWin' -as [type])) {
    Add-Type -TypeDefinition @"
using System;
using System.Text;
using System.Runtime.InteropServices;
[StructLayout(LayoutKind.Sequential)]
public struct PetGuardRect { public int Left; public int Top; public int Right; public int Bottom; }
[StructLayout(LayoutKind.Sequential)]
public struct PetGuardMonitorInfo {
  public int cbSize; public PetGuardRect rcMonitor; public PetGuardRect rcWork; public uint dwFlags;
}
public static class PetGuardWin {
  [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
  [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr hWnd, out PetGuardRect lpRect);
  [DllImport("user32.dll")] public static extern IntPtr MonitorFromWindow(IntPtr hwnd, uint dwFlags);
  [DllImport("user32.dll")] public static extern bool GetMonitorInfo(IntPtr hMonitor, ref PetGuardMonitorInfo lpmi);
  [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr hWnd);
  [DllImport("user32.dll")] public static extern int GetWindowLong(IntPtr hWnd, int nIndex);
  [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint pid);
  [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern int GetClassName(IntPtr hWnd, StringBuilder name, int max);
}
"@
}

# ───────────────────────────── DSH / 桌宠 定位 ─────────────────────────────
function Get-ListeningPorts {
    $out = New-Object System.Collections.ArrayList
    try {
        foreach ($line in (& netstat.exe -ano 2>$null)) {
            if ($line -match '^\s*TCP\s+\S+:(\d+)\s+\S+\s+LISTENING\s+(\d+)\s*$') {
                [void]$out.Add([pscustomobject]@{ Port = [int]$Matches[1]; Pid = [int]$Matches[2] })
            }
        }
    } catch { }
    return $out
}

function Test-TcpOpen([int]$port, [int]$timeoutMs = 150) {
    $client = New-Object System.Net.Sockets.TcpClient
    try {
        $ar = $client.BeginConnect('127.0.0.1', $port, $null, $null)
        if (-not $ar.AsyncWaitHandle.WaitOne($timeoutMs)) { return $false }
        $client.EndConnect($ar)
        return $true
    } catch { return $false }
    finally { $client.Close() }
}

function Get-CachedPort {
    try {
        if (Test-Path -LiteralPath $statePath) {
            $cached = (Get-Content -LiteralPath $statePath -Raw).Trim()
            if ($cached -match '^\d+$') { return [int]$cached }
        }
    } catch { }
    return 0
}

function Save-CachedPort([int]$port) {
    try { Set-Content -LiteralPath $statePath -Value "$port" -Encoding ASCII -NoNewline } catch { }
}

<#
    找到「正在跑桌宠的那一个 DSH」。
    改进点（对比旧版）：
      1. 只探测 DSH 自己进程监听的端口（旧版会逐个 HTTP 请求所有本地端口，既慢又会打扰别的服务）；
      2. 支持 config.dshPort 手动指定，省掉探测；
      3. 路由前缀做成配置项，dsh-pet 将来换前缀也能用。
#>
function Find-PetHost {
    param($Cfg, [int]$CachedPort = 0)
    $candidates = New-Object System.Collections.ArrayList
    if ([int]$Cfg.dshPort -gt 0) { [void]$candidates.Add([int]$Cfg.dshPort) }
    if ($CachedPort -gt 0) { [void]$candidates.Add($CachedPort) }

    $listeners = @(Get-ListeningPorts | Where-Object { $_.Port -ge 1024 })
    foreach ($l in $listeners) {
        $proc = Get-Process -Id $l.Pid -ErrorAction SilentlyContinue
        if ($proc -and ($proc.ProcessName -like 'DeepSeek*' -or $proc.ProcessName -like 'dsh*' -or $proc.ProcessName -eq 'electron')) {
            [void]$candidates.Add($l.Port)
        }
    }
    # 兜底：DSH 桌面端几乎总是落在临时端口段
    foreach ($l in $listeners) { if ($l.Port -ge 49152) { [void]$candidates.Add($l.Port) } }

    $tried = @{}
    foreach ($port in @($candidates | Select-Object -Unique)) {
        if ($tried.ContainsKey($port)) { continue }
        $tried[$port] = 1
        if (-not (Test-TcpOpen $port 150)) { continue }
        $base = "http://127.0.0.1:$port"
        try {
            $resp = Invoke-WebRequest -Uri "$base$($Cfg.routePrefix)/config" -UseBasicParsing -TimeoutSec 2 -ErrorAction Stop
            if ($resp.StatusCode -eq 200 -and $resp.Content -match '"pets"') {
                $json = $resp.Content | ConvertFrom-Json
                $ids = New-Object System.Collections.ArrayList
                # /config 的结构是 { <实例名>: { pets: [ { id, display, ... } ] } }，
                # 真正给 pet-display 用的是 pets[].id；实例名只在没写 id 时兜底。
                foreach ($inst in @($json.PSObject.Properties.Name)) {
                    $node = $json.$inst
                    $petsProp = $null
                    try { $petsProp = $node.pets } catch { $petsProp = $null }
                    if ($petsProp) {
                        foreach ($p in @($petsProp)) {
                            $pid_ = $null
                            try { $pid_ = $p.id } catch { $pid_ = $null }
                            if ($pid_) { [void]$ids.Add([string]$pid_) }
                        }
                    }
                    if ($ids.Count -eq 0) { [void]$ids.Add([string]$inst) }
                }
                $idList = @($ids | Select-Object -Unique)
                if ($idList.Count -eq 0) { $idList = @($json.PSObject.Properties.Name) }
                Save-CachedPort $port
                return [pscustomobject]@{ Base = $base; Pets = $idList; Port = $port }
            }
        } catch { }
    }
    return $null
}

function Get-PetDisplayMap {
    param($Host_)
    $map = @{}
    try {
        $json = (Invoke-WebRequest -Uri "$($Host_.Base)$($script:cfg.routePrefix)/config" -UseBasicParsing -TimeoutSec 3 -ErrorAction Stop).Content | ConvertFrom-Json
        foreach ($inst in @($json.PSObject.Properties.Name)) {
            $node = $json.$inst
            $petsProp = $null
            try { $petsProp = $node.pets } catch { $petsProp = $null }
            if (-not $petsProp) { continue }
            foreach ($p in @($petsProp)) {
                $id_ = $null; $disp = ''
                try { $id_ = [string]$p.id } catch { $id_ = '' }
                try { $disp = [string]$p.display } catch { $disp = '' }
                if ($id_) { $map[$id_] = $disp }
            }
        }
    } catch { }
    return $map
}

function Set-PetDisplay {
    param($Host_, [string]$Display)
    $ok = 0; $fail = 0
    foreach ($petId in $Host_.Pets) {
        $payload = @{ id = $petId; display = $Display } | ConvertTo-Json -Compress
        try {
            Invoke-WebRequest -Uri "$($Host_.Base)$($script:cfg.routePrefix)/pet-display" -Method Post -ContentType 'application/json' `
                -Body $payload -UseBasicParsing -TimeoutSec 10 -ErrorAction Stop | Out-Null
            $ok++
        } catch { $fail++ }
    }
    if ($fail -gt 0 -and $ok -eq 0) { throw "设置 display=$Display 失败（$fail 只宠物全部失败）" }
    return $ok
}

# ───────────────────────────── 判定 ─────────────────────────────
function Get-ForegroundInfo {
    $h = [PetGuardWin]::GetForegroundWindow()
    if ($h -eq [IntPtr]::Zero) { return $null }
    if (-not [PetGuardWin]::IsWindowVisible($h)) { return $null }

    # 排除桌面 / 任务栏 / 开始菜单这类"看着像全屏"的系统窗口
    $sb = New-Object System.Text.StringBuilder 256
    [void][PetGuardWin]::GetClassName($h, $sb, 256)
    $cls = $sb.ToString()
    if ($cls -in @('Progman', 'WorkerW', 'Shell_TrayWnd', 'Shell_SecondaryTrayWnd', 'Windows.UI.Core.CoreWindow', 'ApplicationFrameWindow')) { return $null }

    $r = New-Object PetGuardRect
    if (-not [PetGuardWin]::GetWindowRect($h, [ref]$r)) { return $null }
    if (($r.Right - $r.Left) -le 0 -or ($r.Bottom - $r.Top) -le 0) { return $null }

    $mi = New-Object PetGuardMonitorInfo
    $mi.cbSize = [System.Runtime.InteropServices.Marshal]::SizeOf($mi)
    $mon = [PetGuardWin]::MonitorFromWindow($h, 2)  # MONITOR_DEFAULTTONEAREST
    if (-not [PetGuardWin]::GetMonitorInfo($mon, [ref]$mi)) { return $null }

    $covers = ($r.Left -le $mi.rcMonitor.Left) -and ($r.Top -le $mi.rcMonitor.Top) -and
              ($r.Right -ge $mi.rcMonitor.Right) -and ($r.Bottom -ge $mi.rcMonitor.Bottom)
    return [pscustomobject]@{ Handle = $h; Class = $cls; CoversMonitor = [bool]$covers }
}

function Get-GameVerdict {
    param($Cfg)
    # 一次枚举所有进程再比名字：比"每个规则各 Get-Process 一次"快一个数量级
    $all = @(Get-Process -ErrorAction SilentlyContinue)
    foreach ($p in $all) {
        foreach ($pat in $Cfg.processes) {
            if ($p.ProcessName -like $pat) { return "进程 $($p.ProcessName)" }
        }
    }
    if ($Cfg.hideOnFullscreen) {
        $fg = Get-ForegroundInfo
        if ($fg -and $fg.CoversMonitor) { return '全屏前台' }
    }
    return ''
}

# ───────────────────────────── 安装 / 卸载 / 体检 ─────────────────────────────
function Get-StartupShortcutPath {
    return (Join-Path ([Environment]::GetFolderPath('Startup')) 'DSH桌宠-游戏自动隐藏.lnk')
}

function Install-Guard {
    param($Cfg)
    if (-not (Test-Path -LiteralPath $ConfigPath)) {
        $sample = [ordered]@{
            restoreDisplay   = $Cfg.restoreDisplay
            hideOnFullscreen = $Cfg.hideOnFullscreen
            pollSeconds      = $Cfg.pollSeconds
            dshPort          = 0
            routePrefix      = $Cfg.routePrefix
            heartbeatMinutes = $Cfg.heartbeatMinutes
            processes        = @()
            extraProcesses   = @($Cfg.extraProcesses)
        }
        ($sample | ConvertTo-Json -Depth 5) | Set-Content -LiteralPath $ConfigPath -Encoding UTF8
        Write-Log "已生成默认配置：$ConfigPath"
    }

    $lnkPath = Get-StartupShortcutPath
    $shell = New-Object -ComObject WScript.Shell
    $lnk = $shell.CreateShortcut($lnkPath)
    $lnk.TargetPath = Join-Path $env:WINDIR 'System32\wscript.exe'
    $vbs = Join-Path $scriptDir 'pet-game-guard.vbs'
    if (Test-Path -LiteralPath $vbs) {
        $lnk.Arguments = '"' + $vbs + '"'
    } else {
        $lnk.TargetPath = Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'
        $lnk.Arguments = '-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "' + $scriptPath + '"'
    }
    $lnk.WorkingDirectory = $scriptDir
    $lnk.WindowStyle = 7
    $lnk.Description = '检测到游戏时自动隐藏 DSH 桌宠，退出游戏后恢复'
    $lnk.Save()

    Write-Log "已创建启动项：$lnkPath"
    Write-Host ''
    Write-Host '安装完成。正在后台启动守护（首次启动会立刻体检一次）…'
    Start-Process -FilePath (Join-Path $env:WINDIR 'System32\wscript.exe') -ArgumentList ('"' + $vbs + '"') -WindowStyle Hidden -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 3
    Show-Status -Cfg $Cfg
}

function Uninstall-Guard {
    param($Cfg)
    $lnkPath = Get-StartupShortcutPath
    if (Test-Path -LiteralPath $lnkPath) {
        Remove-Item -LiteralPath $lnkPath -Force
        Write-Log "已删除启动项：$lnkPath"
    } else {
        Write-Log '启动项不存在（可能已卸载）'
    }
    # 顺手把正在跑的守护也停掉（只停本目录这一份，别误伤别的 powershell）
    try {
        $running = @(Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ErrorAction SilentlyContinue |
            Where-Object { $_.CommandLine -and $_.CommandLine -match [regex]::Escape($scriptPath) -and $_.ProcessId -ne $PID })
        foreach ($r in $running) {
            Stop-Process -Id $r.ProcessId -Force -ErrorAction SilentlyContinue
            Write-Log "已结束守护进程（pid=$($r.ProcessId)）"
        }
    } catch { Write-Log "结束守护进程失败（可手动注销）：$($_.Exception.Message)" }
    try {
        $hostInfo = Find-PetHost -Cfg $Cfg
        if ($hostInfo) {
            Set-PetDisplay -Host_ $hostInfo -Display 'desktop' | Out-Null
            Write-Log '已把桌宠恢复为显示'
        }
    } catch { Write-Log "恢复桌宠失败：$($_.Exception.Message)" }
    Write-Host ''
    Write-Host '卸载完成。启动项已删除，守护进程已停止，桌宠已恢复显示。'
}

function Show-Status {
    param($Cfg)
    Write-Host ''
    Write-Host '── DSH 桌宠守护 · 体检 ──'
    $hostInfo = Find-PetHost -Cfg $Cfg -CachedPort (Get-CachedPort)
    if (-not $hostInfo) {
        Write-Host 'DSH：未找到（DSH 桌面端没开，或没装 dsh-pet 插件）'
        return
    }
    Write-Host "DSH：$($hostInfo.Base)（宠物：$($hostInfo.Pets -join ', ')）"
    $map = Get-PetDisplayMap -Host_ $hostInfo
    foreach ($k in $map.Keys) { Write-Host ("  · {0}  display = {1}" -f $k, $map[$k]) }
    $verdict = Get-GameVerdict -Cfg $Cfg
    if ($verdict) { Write-Host "当前判定：游戏中（$verdict）→ 应该隐藏" }
    else { Write-Host '当前判定：不在游戏 / 无全屏 → 应该显示' }
    $lnk = Get-StartupShortcutPath
    Write-Host ("开机自启：{0}" -f $(if (Test-Path -LiteralPath $lnk) { '已安装' } else { '未安装（运行 -Install）' }))
    if (Test-Path -LiteralPath $logPath) {
        Write-Host '── 最近日志 ──'
        Get-Content -LiteralPath $logPath -Tail 6 -Encoding UTF8 | ForEach-Object { Write-Host $_ }
    }
    Write-Host ''
}

# ───────────────────────────── 入口 ─────────────────────────────
$script:cfg = Get-GuardConfig
if ($PollSeconds -gt 0 -and $PollSeconds -ne 3) { $script:cfg.pollSeconds = $PollSeconds }
elseif ([int]$script:cfg.pollSeconds -ge 1) { $PollSeconds = [int]$script:cfg.pollSeconds }

if ($Install)   { Install-Guard  -Cfg $script:cfg; exit 0 }
if ($Uninstall) { Uninstall-Guard -Cfg $script:cfg; exit 0 }
if ($Status)    { Show-Status    -Cfg $script:cfg; exit 0 }

# ── 单实例（每个用户、每个 InstanceTag 一个）────────────────────────────────
$mutex = New-Object System.Threading.Mutex($false, "Local\DshPetGameGuard-$InstanceTag")
$hasMutex = $false
try { $hasMutex = $mutex.WaitOne(0) } catch { $hasMutex = $false }
if (-not $hasMutex) {
    Write-Host '[pet-guard] 已有一个实例在运行，本次退出。'
    exit 0
}

$hidden = $false
$hostInfo = $null
$nextDiscovery = Get-Date
$cachedPort = Get-CachedPort
$startedAt = Get-Date
$lastHeartbeat = Get-Date
$simUntil = if ($SimulateSeconds -gt 0) { (Get-Date).AddSeconds($SimulateSeconds) } else { $null }

Write-Log ("启动：轮询 {0}s｜规则 {1} 条｜全屏判定={2}｜恢复为 {3}｜DryRun={4}" -f `
    $PollSeconds, $script:cfg.processes.Count, $script:cfg.hideOnFullscreen, $script:cfg.restoreDisplay, [bool]$DryRun)

# 启动自愈：上次若异常退出（被强杀、注销、DSH 重启），桌宠可能还藏着；现在没游戏就恢复回来。
try {
    $hostInfo = Find-PetHost -Cfg $script:cfg -CachedPort $cachedPort
    if ($hostInfo) {
        $map = Get-PetDisplayMap -Host_ $hostInfo
        $anyHidden = @($map.Values | Where-Object { $_ -eq 'none' }).Count -gt 0
        $verdict0 = Get-GameVerdict -Cfg $script:cfg
        if ($anyHidden -and -not $verdict0 -and -not $DryRun) {
            Set-PetDisplay -Host_ $hostInfo -Display $script:cfg.restoreDisplay | Out-Null
            Write-Log '启动自愈：发现桌宠处于隐藏状态但没有游戏在跑，已恢复显示'
        }
        $hidden = ($anyHidden -and [bool]$verdict0)
        $nextDiscovery = (Get-Date).AddSeconds(30)
    }
} catch {
    Write-Log "启动体检失败（稍后自动重试）：$($_.Exception.Message)"
    $hostInfo = $null
}

$iter = 0
try {
    while ($true) {
        $iter++
        if ($Once -gt 0 -and $iter -gt $Once) { break }
        try {
            if (-not $hostInfo -or (Get-Date) -ge $nextDiscovery) {
                # 每 30 秒顺便热重载一次配置：改 processes / restoreDisplay / hideOnFullscreen
                # 不用重启守护（pollSeconds 是启动参数，改了要重启）。
                try {
                    $fresh = Get-GuardConfig
                    $script:cfg.processes = $fresh.processes
                    $script:cfg.restoreDisplay = $fresh.restoreDisplay
                    $script:cfg.hideOnFullscreen = $fresh.hideOnFullscreen
                    $script:cfg.routePrefix = $fresh.routePrefix
                    $script:cfg.dshPort = $fresh.dshPort
                    $script:cfg.heartbeatMinutes = $fresh.heartbeatMinutes
                } catch { }
                $hostInfo = Find-PetHost -Cfg $script:cfg -CachedPort $cachedPort
                $nextDiscovery = (Get-Date).AddSeconds(30)
                if (-not $hostInfo) {
                    Write-Log '还没找到 DSH（桌面端没开 / 没装 dsh-pet），稍后重试'
                    Start-Sleep -Seconds $PollSeconds
                    continue
                }
                $cachedPort = $hostInfo.Port
                Write-Log "找到 DSH：$($hostInfo.Base)（宠物：$($hostInfo.Pets -join ', ')）" -Key "host:$($hostInfo.Port)"
            }

            $reason = ''
            if ($simUntil -and (Get-Date) -lt $simUntil) { $reason = '自测' }
            else { $reason = Get-GameVerdict -Cfg $script:cfg }

            if ($reason -and -not $hidden) {
                if ($DryRun) { Write-Log "（DryRun）应该隐藏：$reason" 'dry:hide' }
                else {
                    Set-PetDisplay -Host_ $hostInfo -Display 'none' | Out-Null
                    Write-Log "隐藏桌宠（$reason）" 'state:hidden'
                }
                $hidden = $true
            } elseif (-not $reason -and $hidden) {
                if ($DryRun) { Write-Log '（DryRun）应该恢复显示' 'dry:show' }
                else {
                    Set-PetDisplay -Host_ $hostInfo -Display $script:cfg.restoreDisplay | Out-Null
                    Write-Log "恢复桌宠（游戏已退出）" 'state:shown'
                }
                $hidden = $false
            }

            if ([int]$script:cfg.heartbeatMinutes -gt 0 -and ((Get-Date) - $lastHeartbeat).TotalMinutes -ge [int]$script:cfg.heartbeatMinutes) {
                $lastHeartbeat = Get-Date
                Write-Log ("心跳：运行 {0:N0} 分钟｜当前隐藏={1}" -f ((Get-Date) - $startedAt).TotalMinutes, $hidden) 'heartbeat'
            }
        } catch {
            # 多半是 DSH 换端口 / 重启：清空缓存，下一轮重新发现；桌宠的真实状态以启动自愈为准
            Write-Log "操作失败，重新定位 DSH：$($_.Exception.Message)"
            $hostInfo = $null
            $nextDiscovery = Get-Date
        }
        Start-Sleep -Seconds $PollSeconds
    }
} finally {
    # 退出时（Ctrl+C / 注销 / 正常结束）尽量把桌宠恢复，别让它留在隐藏状态
    if ($hidden -and -not $DryRun) {
        try {
            if (-not $hostInfo) { $hostInfo = Find-PetHost -Cfg $script:cfg -CachedPort $cachedPort }
            if ($hostInfo) {
                Set-PetDisplay -Host_ $hostInfo -Display $script:cfg.restoreDisplay | Out-Null
                Write-Log '守护退出：已恢复桌宠显示'
            }
        } catch { Write-Log "守护退出时恢复失败：$($_.Exception.Message)" }
    }
    try { $mutex.ReleaseMutex() } catch { }
    try { $mutex.Dispose() } catch { }
}
