# Desktop capsule

A floating, always-on-top glass pill for the current agent work, plus a corner
card when the agent needs you. Windows only.

## Look

A smoked-glass bubble: fully rounded ends, a translucent dark base so the text
stays readable over any wallpaper, a white gradient sheen, and a 1 px bright
rim. It is a per-pixel transparent window, so the desktop shows through around
and inside it.

Real background blur is deliberately not used: the Windows acrylic backdrop
paints the whole window rectangle and leaves a dark box around the rounded
pill, so the capsule trades blur for true transparency.

## What it shows

One line of state and a right-hand time, for the most urgent live session:

| State | Line | Accent |
|---|---|---|
| Working | `正在干活 · 第 N 轮` with elapsed time | blue, breathing dot |
| Needs approval | `等你授权 · <tool>` with wait time | amber |
| Needs an answer | `等你回答 · <n 个问题>` with wait time | amber |
| Turn finished | `这一轮做完了` with the turn duration | green |
| Failed | `出错了 · <message>` | red |

When several sessions are live, the pill shows the most urgent one and appends
`· 另 N 个会话`.

## Notifications

A corner card appears above the pill, with a short system sound, when the state
changes into a wait, a failure, or a completed turn that ran for 15 seconds or
longer. It closes itself after about six seconds; clicking it also returns to
the window.

## Click and drag

- Click the pill or a card: activates the DeepSeek Harness window (restoring it
  when minimized).
- Drag the pill: reposition it. The position is remembered in
  `%USERPROFILE%\.dsh\desktop-capsule\prefs.json`.

## How it is wired

The host plugin mirrors agent state into
`%USERPROFILE%\.dsh\desktop-capsule\status.json` and spawns `capsule.ps1`
(Windows PowerShell, WPF). The script polls that file every 250 ms and stops
itself when the host heartbeat is more than 30 seconds old, so a crashed or
closed app leaves no window behind.

The plugin observes `agent/status`, `agent/error`, `session/event`,
`approval/request` and `user-questions/request`. The two request waterfalls are
observed without changing their outcome: every listener delegates with
`next()`.

## Limitations

- Windows only; the pill process is Windows PowerShell and WPF.
- The click restores the app window; it does not switch to a specific session
  when several sessions are open.
- Approval and question detection covers the tool-approval and
  `ask_user_question` flows; a plan-review prompt appears as an answer request.
- A status file is shared through the user profile, so the capsule must run as
  the same Windows user as the app.
