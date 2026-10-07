# WebView2 Host Keeper

Keep a WebView2-based desktop app alive when the WebView2 runtime is updated or replaced underneath it.

English | [中文](README.zh-CN.md)

## The problem

Applications built on **Edge WebView2** share a structural fragility: **any operation that updates or replaces the WebView2 runtime will silently take your app down with it.**

The most common trigger in practice is uninstalling or updating Microsoft Copilot. Its uninstaller (`copilot_setup.exe`) is part of the Microsoft Edge installer family. To replace the runtime files it must release the DLL locks held by running WebView2 hosts, so it **terminates every `msedgewebview2.exe` process on the machine**. It cannot tell hosts apart, so your application dies too — with no error message, no dialog, nothing in the log.

This affects any WebView2 host, not just wallpaper apps: .NET desktop tools, some utilities, parts of Electron-alternative stacks.

### Confirming it happened

The event log (`Applications and Services Logs` → `Microsoft-Windows-WER`) will show two `crashpad_log` entries at the moment your app disappears:

```
P1: setup.exe
P2: 154.0.4258.62                  ← Edge / WebView2 runtime version
P3: EdgeInstallerError|mscopilot← the uninstaller identifies itself here
P4: 0x210
```

`EdgeInstallerError` in P3 is the giveaway.

To see which processes belong to your app:

```powershell
Get-CimInstance Win32_Process -Filter "Name='msedgewebview2.exe'" |
  Where-Object CommandLine -match 'YourApp.exe'
```

## Workaround: an external keeper

`watch-webview2-host.ps1` polls for your process and relaunches it when it disappears.

```powershell
.\watch-webview2-host.ps1 -ProcessName "BichiPond" -Exe "E:\App\BichiPond.exe"
```

Register it to start at login. It must run in your **interactive session** — a service or Session 0 process would launch the app somewhere you cannot see it:

```powershell
schtasks /Create /TN "WebView2HostKeeper" `
  /SC ONLOGON /RU $env:USERNAME /RL LIMITED `
  /TR "powershell.exe -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$PWD\watch-webview2-host.ps1`" -ProcessName `"BichiPond`" -Exe `"E:\App\BichiPond.exe`"" `
  /F
```

### Web Audio caveat

Pages that never receive a real user gesture — desktop wallpapers being the classic case — leave Chromium's `AudioContext` suspended forever, producing a picture with no sound. The script sets `--autoplay-policy=no-user-gesture-required` by default, matching what most hosts do. Pass `-NoAutoplay` if your app does not use Web Audio.

### Parameters

| Parameter | Default | Purpose |
|---|---|---|
| `-ProcessName` | required | Target process name, without `.exe` |
| `-Exe` | — | Full path used to relaunch; required if the process is not found |
| `-IntervalSeconds` | `30` | Poll interval |
| `-LogFile` | `keeper.log` beside the script | Where restarts are recorded |
| `-QuitAfterRecover` | off | Relaunch once, then exit |
| `-NoAutoplay` | off | Do not relax the WebView2 autoplay policy |

## If you maintain a WebView2 host: fix it properly

The keeper is a band-aid. If you own the app, handle the failure in-process instead.

### 1. Do not `Reload()` on browser-process exit

```csharp
// Ineffective: after the browser process is terminated externally there is
// nothing to reload, and the empty catch swallows the failure silently.
core.ProcessFailed += (s, e) => { try { core.Reload(); } catch (Exception) { } };
```

Branch on the failure kind instead — `Reload()` is only meaningful for renderer crashes:

```csharp
core.ProcessFailed += (s, e) =>
{
    Log($"WebView2 process failed: {e.ProcessFailedKind}");
    if (e.ProcessFailedKind == CoreWebView2ProcessFailedKind.BrowserProcessExited)
        Rebuild();                        // rebuild the environment and navigate again
    else
        try { core.Reload(); } catch (Exception ex) { Log("reload failed", ex); }
};
```

### 2. Add a periodic health check as a second line of defence

When the host is killed outright the event may not be delivered in time. A cheap check in an existing timer covers it:

```csharp
if (walls.Any(w => w.View?.CoreWebView2 == null)) Rebuild();
```

### 3. Never fail silently

`catch (Exception) { }` makes the problem disappear completely. Write it to a log file so the next occurrence is diagnosable.

## Verified

Tested on Windows 10 (build 19045), .NET Framework 4.8 host, WebView2 Runtime 154.0.4258.62: killing the host process and all of its `msedgewebview2` children, then running one iteration of the keeper, brought the app back with a responding main process and a full set of WebView2 children rebuilt.

## License

MIT — see [LICENSE](LICENSE).

## Related

- [`moli-xia/fishwallpaper`](https://github.com/moli-xia/fishwallpaper) — 碧池观鱼, the multi-platform koi pond wallpaper. The issue this was built for.