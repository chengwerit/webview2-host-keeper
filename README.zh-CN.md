# WebView2 宿主被连带退出的复现与保活

这是 [`moli-xia/fishwallpaper`](https://github.com/moli-xia/fishwallpaper)（碧池观鱼）在 Windows 上遇到的一个兼容性问题的独立复现与规避方案。

**原仓库 issue**：https://github.com/moli-xia/fishwallpaper/issues （见正文）

## 问题

任何基于 **Edge WebView2** 构建的应用，都可能在 WebView2 运行时被更新或替换时被连带终止。

Copilot 的卸载器 `copilot_setup.exe` 属于 Edge 安装器家族，卸载时会枚举并终止**全部** `msedgewebview2.exe` 进程以释放 DLL 文件锁。它无法区分宿主程序——你的应用也一起被杀，表现为**无任何提示的静默退出**。

影响的不只是碧池观鱼。任何基于 WebView2 的桌面应用（笔记工具、Electron 之外的部分 .NET 应用、某些 AI 客户端等）都可能中招。

## 复现

```powershell
# 1. 装好 WebView2 Runtime 与任一 WebView2 应用，确认正常运行
# 2. 记录父进程与子进程
Get-Process -Name msedgewebview2 | Select-Object Id, ProcessName

# 3. 安装并卸载 Copilot
winget install Microsoft.Copilot
winget uninstall Microsoft.Copilot

# 4. 观察：WebView2 应用连同所有 msedgewebview2 子进程一并消失
Get-Process -Name msedgewebview2 -ErrorAction SilentlyContinue
```

事件日志（`Applications and Services Logs` → `Microsoft-Windows-WER`）中会留下：

```
事件名称: crashpad_log
P1: setup.exe
P2: 154.0.4258.62
P3: EdgeInstallerError|mscopilot
P4: 0x210
```

`P3` 中的 `EdgeInstallerError` 就是「卸载器属于 Edge 安装器家族」的直接证据。

## 规避方案

### 方式一：外部保活脚本（无需改被保活的应用）

`watch-webview2-host.ps1` —— 周期检测主进程，未运行则重新拉起：

```powershell
.\watch-webview2-host.ps1 -ProcessName "BichiPond" -Exe "E:\...\BichiPond.exe"
```

注册为登录时自动启动（**在交互式会话中运行**，否则拉起的进程会落在 Session 0）：

```powershell
schtasks /Create /TN "WebView2HostKeeper" `
  /SC ONLOGON /RU $env:USERNAME `
  /TR "powershell.exe -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$PWD\watch-webview2-host.ps1`" -ProcessName `"BichiPond`" -Exe `"E:\...\BichiPond.exe`"" `
  /RL LIMITED /F
```

**重要**：如果目标应用依赖 Web Audio，必须同时设置 autoplay 参数，否则重启后会没有声音——桌面壁纸这类拿不到真实用户手势的页面尤其如此：

```powershell
$env:WEBVIEW2_ADDITIONAL_BROWSER_ARGUMENTS = "--autoplay-policy=no-user-gesture-required"
```

脚本已内置此参数。

### 方式二：在应用内自愈（更根本）

如果你是 WebView2 宿主应用的开发者，参见下面两处改动思路。

## 对宿主应用开发者的建议

以 `.NET Framework 4.8 + WebView2` 为例：

### 1. 不要用 `Reload()` 应对浏览器进程退出

```csharp
// 有缺陷：外部终止浏览器进程后，Reload() 无处可载，异常还被空 catch 吞掉
core.ProcessFailed += (s, e) => { try { core.Reload(); } catch (Exception) { } };
```

改为区分失败类型，浏览器进程退出时走整体重建：

```csharp
core.ProcessFailed += (s, e) =>
{
    if (e.ProcessFailedKind == CoreWebView2ProcessFailedKind.BrowserProcessExited)
        Rebuild();                                  // 重新建环境并导航
    else
        try { core.Reload(); } catch { /* 记日志 */ }
};
```

### 2. 加一层定时健康检查兜底

宿主进程被杀时 `ProcessFailed` 事件可能来不及派发。配合周期性的存活检查更稳：

```csharp
// 在既有的定时器 tick 里
if (walls.Any(w => w.View?.CoreWebView2 == null)) Rebuild();
```

### 3. 静默失败必须留日志

`catch (Exception) { }` 会让问题彻底消失。把失败写进日志文件，下次遇到就能直接定位。

## 授权

MIT。详见 [LICENSE](LICENSE)。