# 桌面胶囊 · dsh-desktop-capsule

给 [DeepSeek Harness](https://github.com/deepseek-ai) 的**玻璃泡泡**式桌面浮窗：置顶显示我当前在做什么，需要你授权或回答时弹卡片提醒，点一下把 DSH 窗口切回前台。

Windows 10/11 + DSH Desktop 专用。

![桌面胶囊](docs/preview.png)

## 它解决什么问题

DSH 本身只有窗口内的进度提示：窗口一最小化，你就不知道我是在干活、在等你点授权、还是已经做完了。

这个插件把这个状态搬到桌面上：

| 状态 | 胶囊显示 | 圆点 |
|---|---|---|
| 干活中 | `正在干活 · 第 N 轮 · 03:12` | 蓝色，呼吸闪烁 |
| 等你授权 | `等你授权 · pwsh · 00:42`（已等时长） | 琥珀色 |
| 等你回答 | `等你回答 · 3 个问题` | 琥珀色 |
| 完成 | `这一轮做完了 · 04:09`（本轮耗时） | 绿色 |
| 出错 | `出错了 · <原因>` | 红色 |

- **角落通知**：切到等待/出错，或这一轮跑超过 15 秒才做完时，胶囊上方弹一张玻璃卡片 + 提示音，6 秒自动消失。
- **点一下就回去**：点胶囊或卡片，把 DeepSeek Harness 窗口切到前台（最小化会先还原）。
- **可拖动**：拖到你喜欢的位置，位置记在 `%USERPROFILE%\.dsh\desktop-capsule\prefs.json`。
- **多会话**：同时有多个会话在跑时，显示最紧急的那个，并标注「另 N 个会话」。

## 安装

### 方式一：在插件市场的 Discover 里安装（推荐）

本仓库自带一个 **format 1** 的插件市场索引：`market/index.json`。把它加进 DSH 的插件市场源，就能在「发现」页里看到并一键安装：

```
https://raw.githubusercontent.com/abraxasLi/dsh-desktop-capsule/main/market/index.json
```

两步：

1. Plugins 里启用 `@deepseek-ai/dsh-experimental-plugin-market-bundle` —— 「发现」页是这个可选包提供的，不启用就没有这个标签页。
2. 在「发现」页添加上面的索引 URL，搜索 `desktop capsule` 安装。

索引里的版本钉住了提交 `9c0c0ab`，安装时 pnpm 拉到的就是那一份代码；索引本身用 DSH 自带的 `@deepseek-ai/dsh-plugin-market-index` 校验器验过（format 1）。

### 方式二：直接从 GitHub 安装

在 DSH 里对助手说：

> 安装插件：`git+https://github.com/abraxasLi/dsh-desktop-capsule.git`

等价于 `plugin_manager` 的 `install_bundle`，`target` 传这个 git spec。要锁定版本就带提交：

```
git+https://github.com/abraxasLi/dsh-desktop-capsule.git#9c0c0ab2ca4545952c826b46021286c1f0ddf425
```

### 方式三：本地目录

把仓库目录作为 `target` 传给 `install_bundle`，或走 **Plugins** → **Add plugin** 选择本目录（含 `package.json`）。DSH 会以链接方式装入当前 profile，适合改代码时用。

### 关于“上架”与更新

- **DeepSeek 目前没有公开的插件商店提交入口**：DSH 的插件市场读的是用户自己配置的**索引 URL**，没有中心化审核队列。所以这里的“发布”= 公开仓库 + 一个能装到索引里的 `market/index.json`，任何人的 DSH 都能通过它发现本插件。
- **首次安装即时生效**，胶囊会立刻出现在桌面右下角。
- **升级或换安装源**（例如从本地目录换成 GitHub 版）后需要**重启 DSH**：宿主插件是 ESM 模块，已被加载的模块有缓存，`set_plugin` 开关不会重新导入新代码。
- 装完可以这样确认：`%USERPROFILE%\.dsh\desktop-capsule\` 下应出现 `status.json`（每 2 秒刷新）、`plugin.log`、`capsule.log`。

## 它是怎么工作的

```
DSH 进程                        胶囊进程
┌──────────────────────┐        ┌────────────────────────┐
│ index.js（宿主插件）  │        │ capsule.ps1（WPF）      │
│  订阅 agent/status    │        │  每 250ms 读状态文件    │
│  approval/request     │──写──▶ │  status.json            │
│  user-questions/...   │        │  渲染胶囊 / 弹卡片      │
│  session/event        │        │  点击 → 激活 DSH 窗口   │
└──────────────────────┘        └────────────────────────┘
```

- 宿主插件把状态写成 `%USERPROFILE%\.dsh\desktop-capsule\status.json`，并负责拉起/回收胶囊进程。
- 胶囊每 250ms 轮询这个文件；宿主心跳（`updatedAt`）超过 30 秒没更新就自行退出，不会留下孤儿窗口。
- 审批/提问两个 waterfall 都是**只观察不改变结果**：监听器一律 `await next()` 透传。
- 日志：同目录下 `plugin.log` / `capsule.log`。

## 外观调节

都在 `capsule.ps1` 里，改完重新加载插件即可：

| 想要 | 改这里 |
|---|---|
| 更透 / 更实 | `$base.Background = '#7A0B0E14'`（末两位十六进制是透明度） |
| 高光强弱 | `New-GlassBrush -Top '#33FFFFFF' -Middle '#0FFFFFFF' -Bottom '#04FFFFFF'` |
| 描边亮度 | `$rim.BorderBrush = '#59FFFFFF'` |
| 宽度 | `$window.Width = 340` |
| 文案 | `strings.json`（全中文文案都在这里，方便改其它语言） |

## 已知限制

- **只有 Windows**：胶囊进程是 Windows PowerShell + WPF。
- **没有真实模糊**：Windows 的亚克力（DWM acrylic）按**窗口矩形**铺底，不认圆角裁剪，用了会在胶囊外留一块深色矩形。这里选择「逐像素透明 + 半透叠层」，所以能看见背后的画面，但不是磨砂玻璃。
- **点击只回窗口**：多个会话时不会跳到"那一个"会话，只把 DSH 整体切到前台。
- **审批提醒依赖审批策略**：会话设为 “never” 时不会有审批请求，自然也不会弹。
- **全屏应用之上可能被盖住**：独占全屏（部分游戏/播放器）会盖过置顶窗口。

## English

A glass-style, always-on-top capsule for DeepSeek Harness on Windows: it mirrors the live agent state (working / waiting for approval / waiting for an answer / done / failed), shows a corner card with a soft sound when you are needed, and brings the DSH window back on click.

No dependencies and no build step: the host half is plain ESM, the pill is a WPF script. Windows 10/11 and DSH Desktop only.

### Install

DeepSeek Harness has no central plugin-store submission endpoint: its **Discover** page reads the **index URLs a user configures**. Publishing here therefore means a public repository plus a format-1 index that any DSH profile can point at.

```bash
# from GitHub (pin the commit for a reproducible install)
git+https://github.com/abraxasLi/dsh-desktop-capsule.git#9c0c0ab2ca4545952c826b46021286c1f0ddf425
```

```text
# market index (Discover), format 1, validated with @deepseek-ai/dsh-plugin-market-index
https://raw.githubusercontent.com/abraxasLi/dsh-desktop-capsule/main/market/index.json
```

Add that URL under Discover after enabling `@deepseek-ai/dsh-experimental-plugin-market-bundle`, then install the plugin from the listing. A local checkout works too: pass the directory as the install target.

The first install takes effect immediately. **Restart DSH after an upgrade or an install-source switch** — host plugins are ESM modules and an already-loaded module stays cached.

## License

MIT
