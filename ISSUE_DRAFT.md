# WebView2 宿主进程被外部终止后无法自愈 —— Windows 版静默退出

## 现象

在 Windows 10 上运行 `BichiKoiPond-1.2.1-Windows`，**卸载 Microsoft Copilot 会导致碧池观鱼连同桌面池塘壁纸一并静默退出**，需手动重启才能恢复。

- 发生时间：2026-10-07 22:27:39
- 影响范围：仅 Windows 版。macOS 版（原生 Swift，不依赖 WebView2）与Android 版（独立 WebView 实例且非 Edge 内核）不受影响
- 数据未丢失：`%LOCALAPPDATA%\BichiPond` 中 WebView2 profile 与 localStorage 完好，锦鲤与设置均恢复

## 复现步骤

1. Windows 10/11（已装 Edge WebView2 Runtime），运行 Windows 版碧池观鱼，确认桌面池塘正常显示
2. 安装 Microsoft Copilot（Microsoft Store 或 `winget install Microsoft.Copilot`）
3. 卸载 Copilot
4. 观察：碧池观鱼与桌面壁纸一并消失

**预期**：卸载一个无关应用不应让另一个应用退出
**实际**：静默退出，无任何错误提示

## 根因

Copilot 的卸载器 `copilot_setup.exe` **属于 Microsoft Edge 安装器家族**。执行卸载时它需要替换 Edge WebView2 运行时文件，而所有 WebView2 宿主程序都锁定着这些 DLL，因此它采取的做法是**枚举并终止全部 `msedgewebview2.exe` 进程**以释放文件锁。它无法区分宿主程序，这是所有 WebView2 应用共有的结构性脆弱点。

事件日志已确证：

```
事件名称: crashpad_log
P1: setup.exe
P2: 154.0.4258.62                  ← Edge / WebView2 运行时版本
P3: EdgeInstallerError|mscopilot
P4: 0x210
附加文件: C:\WINDOWS\SystemTemp\msedge_installer.log
```

本程序 7 个子进程全部是 `msedgewebview2.exe`：

```
...\Microsoft\EdgeWebView\Application\154.0.4258.62\msedgewebview2.exe
  --embedded-browser-webview=1
  --webview-exe-name=BichiPond.exe
  --webview-exe-version=1.2.1+0752cd5124d1d26b70b4a6430584ec26bace5882
  --user-data-dir="C:\Users\<user>\AppData\Local\BichiPond\WebView2\EBWebView"
```

## 源码层面发现的三点

我读了 `native/windows/` 的实现（commit 时为1.2.1），除了这个场景本身，还有几处让它**无法自愈**的地方：

### 1. `ProcessFailed` 里的 `Reload()` 对外部终止无效

`native/windows/PondWindows.cs:44`：

```csharp
core.ProcessFailed += (s, e) => { try { core.Reload(); } catch (Exception) { } };
```

这行注释写的是「若页面渲染进程崩溃则重新加载池塘」，对 **GPU reset / 内存不足**这类场景是对的。但本次是**外部进程直接终止浏览器进程**——进程已经不存在，`Reload()` 无处可载，于是异常被空catch 吞掉，桌面就此变空白，且不留下任何日志。

另外，`catch (Exception) { }` 使得失败被完全静默，`%LOCALAPPDATA%\BichiPond\error.log` 里也没有任何记录（这个文件只有 `Report()` 才会写，而 `ProcessFailed` 路径完全不经过它）。

### 2. 缺少退避与重试，退出的主进程无人拉起

`PondApp` 里与「恢复」相关的只有 `Rebuild(int delay)`，而它的触发条件是：
- `ShellWatcher` 收到 `TaskbarCreated`（资源管理器重启）
- `SystemEvents.DisplaySettingsChanged`（显示器变化）

即**只覆盖了 Explorer 重启与显示器变化两种显式事件**。WebView2 运行时被外部替换导致的所有进程退出，不属于这两类，主进程就此静静退出。`watch` 这个 1 秒定时器只做 `UpdateVisibility()`（判断是否被全屏窗口遮挡），没有健康检查。

### 3. `Views` 过滤掉了已死的视图，可能影响后续同步

```csharp
private IEnumerable<WebView2> Views => walls.Select(w => w.View).Concat(...).Where(v => v?.CoreWebView2 != null);
```

当 CoreWebView2 已失效时 `CoreWebView2` 会变null，这条过滤让代码"看起来还正常"，但也意味着任何基于`Views` 的自愈尝试都会静默跳过这些死掉的视图。

## 建议修复

### 方案 A：让 `ProcessFailed` 区分失败类型并真正恢复（推荐）

`CoreWebView2ProcessFailedKind` 里区分了 `BROWSER_PROCESS_EXITED` 与 `RENDERER_PROCESS_EXITED`。对前者 `Reload()` 无效，应当重建环境并重新导航：

```csharp
core.ProcessFailed += (s, e) =>
{
    Report($"WebView2 进程失败: {e.ProcessFailedKind}", null);   // 先让它留下日志
    if (e.ProcessFailedKind == CoreWebView2ProcessFailedKind.BrowserProcessExited)
        MainThread(() => Rebuild(200));   // 交给已有的 Rebuild 路径整体重建
    else
        try { core.Reload(); } catch (Exception ex) { Report("重载失败", ex); }
};
```

配合 `Report()` 允许 `ex` 为 null，让这类静默失败在 `error.log` 里留下痕迹，便于日后排查。

### 方案 B：给 `watch` 定时器加健康检查（兜底）

在既有的 1 秒 tick 里顺带检查，任一 `WallpaperForm` 的 `View?.CoreWebView2 == null` 即触发 `Rebuild()`。这样无论 WebView2 因何原因挂掉都能自愈，而不只依赖 `ProcessFailed` 事件——考虑到宿主进程被杀时事件可能来不及派发，这个兜底更有必要。

### 方案 C：随包提供独立看护进程

在发布包中附带轻量保活组件（PowerShell 或原生小工具），周期检测主进程并重新拉起。优点是不改主程序逻辑；代价是多一个常驻进程。

## 我实际使用的临时 workaround

等待修复期间，我用外部保活脚本绕过（本机已验证有效，30 秒内恢复）：

```powershell
$ErrorActionPreference = "SilentlyContinue"
$env:WEBVIEW2_ADDITIONAL_BROWSER_ARGUMENTS = "--autoplay-policy=no-user-gesture-required"
while ($true) {
  if (-not (Get-Process -Name "BichiPond" -ErrorAction SilentlyContinue)) {
    Start-Process "E:\...\BichiPond\BichiPond.exe"
    Start-Sleep -Seconds 10
  }
  Start-Sleep -Seconds 30
}
```

**注意**：脚本里必须设置 `--autoplay-policy=no-user-gesture-required`，与 `PondApp.Start()` 中 `CoreWebView2EnvironmentOptions` 的做法一致——桌面壁纸页面拿不到真实用户手势，Chromium 会拒绝启动 Web Audio，否则没有声音。

## 环境信息

| 项 | 值 |
|---|---|
| 系统 | Windows 10 家庭版 10.0.19045(Home, Build 19045) |
| 应用版本 | BichiPond 1.2.1（Windows zip release） |
| WebView2 Runtime | 154.0.4258.62 |
| 运行时 | .NET Framework 4.8 |
| 触发操作 | 卸载 Microsoft Copilot（`EdgeInstallerError|mscopilot`, `0x210`） |

## 一点补充

README 中提到「这台 Mac 上没有 Windows 环境，尚未在 Windows 上实际运行」。这个 bug 恰好出现在真实 Windows 环境下。而方案 A/B 的成本都很低——`Rebuild()` 和 `watch` 定时器都是现成的基础设施，只需补上「WebView2 健康检查」和「失败类型区分」两件事。若需要我开 PR 实现方案 A+B，请告知。

考虑到这类宿主被连带退出不只影响本项目，我也把它整理成了一份独立的最小复现与 workaround 说明：