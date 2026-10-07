<#
.SYNOPSIS
    保活基于Edge WebView2 构建的桌面应用。

.DESCRIPTION
    Edge WebView2 的宿主程序有一项结构性脆弱点：任何更新或替换 WebView2 运行时的操作
    （自动更新、Copilot / Edge 组件的安装与卸载等），都会因为需要释放 DLL 文件锁而终止
    全部 msedgewebview2.exe 进程。卸载器无法区分宿主程序，因此你的应用会被连带终止，
    表现为无任何提示的静默退出。

    本脚本周期检测目标进程，未运行则重新拉起。

.PARAMETER ProcessName
    目标进程名（不含 .exe），如 BichiPond。

.PARAMETER Exe
    目标可执行文件的完整路径。当 ProcessName 提供的进程不存在时，此参数必须指定。

.PARAMETER IntervalSeconds
    检测间隔秒数，默认 30。

.PARAMETER LogFile
    触发重启时的记录文件。默认为脚本同级目录下的 keeper.log。

.PARAMETER QuitAfterRecover
    触发一次重启后退出脚本。默认持续守护。

.EXAMPLE
    .\watch-webview2-host.ps1 -ProcessName "BichiPond" -Exe "E:\...\BichiPond.exe"

.EXAMPLE
    注册为登录时自动启动（注意：必须在交互式会话中运行，
    否则拉起的进程会落在 Session 0，用户看不到界面）：
    schtasks /Create /TN "WebView2HostKeeper" /SC ONLOGON /RU $env:USERNAME /RL LIMITED `
      /TR "powershell.exe -WindowStyle Hidden -ExecutionPolicy Bypass -File <脚本路径> -ProcessName `"BichiPond`" -Exe `"E:\...\BichiPond.exe`"" /F

.NOTES
    Web Audio 说明：
    桌面壁纸这类页面拿不到真实的用户手势，Chromium 的自动播放策略会因此让 AudioContext
    永久挂起，表现为「有画面没声音」。脚本已默认设置
    WEBVIEW2_ADDITIONAL_BROWSER_ARGUMENTS 放行自动播放，与宿主应用通常的做法一致。
    若你的应用不需要 Web Audio，可用 -NoAutoplay 关闭该行为。
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string]$ProcessName,

    [string]$Exe,

    [ValidateRange(5, 3600)]
    [int]$IntervalSeconds = 30,

    [string]$LogFile,

    [switch]$QuitAfterRecover,
    [switch]$NoAutoplay
)

$ErrorActionPreference = 'SilentlyContinue'

if (-not $LogFile) {
    $LogFile = Join-Path $PSScriptRoot 'keeper.log'
}

function Write-KeeperLog {
    param([string]$Message)
    $line = '[{0}] {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Message
    try {
        Add-Content -LiteralPath $LogFile -Value $line -Encoding UTF8
    } catch {
        # 日志写入失败不应影响守护本身
    }
    Write-Verbose $line
}

# 放行 Web Audio 自动播放：壁纸类页面收不到用户手势，否则永远静音
if (-not $NoAutoplay) {
    $env:WEBVIEW2_ADDITIONAL_BROWSER_ARGUMENTS = '--autoplay-policy=no-user-gesture-required'
}

Write-KeeperLog "watcher started: process='$ProcessName' interval=${IntervalSeconds}s autoplay=$(-not $NoAutoplay)"

while ($true) {
    $running = Get-Process -Name $ProcessName -ErrorAction SilentlyContinue

    if (-not $running) {
        if (-not $Exe -or -not (Test-Path -LiteralPath $Exe)) {
            Write-KeeperLog "target not running, but -Exe is missing or invalid; cannot relaunch"
        }
        else {
            Write-KeeperLog "target not running -> relaunching '$Exe'"
            try {
                Start-Process -FilePath $Exe -WorkingDirectory (Split-Path -Parent $Exe)
                Start-Sleep -Seconds 10
                if (Get-Process -Name $ProcessName -ErrorAction SilentlyContinue) {
                    Write-KeeperLog "relaunched successfully"
                } else {
                    Write-KeeperLog "relaunch attempted, but process still not visible"
                }
            } catch {
                Write-KeeperLog "relaunch failed: $($_.Exception.Message)"
            }

            if ($QuitAfterRecover) {
                Write-KeeperLog 'exiting after recovery (QuitAfterRecover)'
                break
            }
        }
    }

    Start-Sleep -Seconds $IntervalSeconds
}