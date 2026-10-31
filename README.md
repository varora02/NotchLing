<p align="center">
  <img src=".github/assets/hero.png" alt="Rex beside the MacBook notch, with a panel showing three coding agents and what each one needs" width="900">
</p>

<h1 align="center">NotchLing</h1>

<p align="center">
  <b>Your AI coding agents, at a glance.</b><br>
  A tiny pet beside your MacBook notch. It naps while nothing runs, works when an agent works, and waves when one needs you.
</p>

<p align="center">
  <a href="../../releases/latest"><img src=".github/assets/download.svg" alt="Download for macOS" height="56"></a>
</p>

<p align="center">
  <img src=".github/assets/badge-macos.svg" alt="macOS 14 or later">
  <img src=".github/assets/badge-chip.svg" alt="Apple Silicon and Intel">
  <img src=".github/assets/badge-signed.svg" alt="Signed and notarized">
  <img src=".github/assets/badge-license.svg" alt="MIT license">
</p>

---

## Meet your NotchLing

<p align="center">
  <img src=".github/assets/states.png" alt="Rex the T-Rex and Ellie the elephant in five moods: resting, working, needs you, and two peeks" width="860">
</p>

Pick **Rex** the T-Rex or **Ellie** the elephant from **••• → Appearance…**. They share the same moves, so you always read them the same way.

## How it works

```mermaid
flowchart LR
    A["Claude Code<br/>Codex<br/>Cursor<br/>Antigravity"] -->|"a tiny local hook"| B["notchling-bridge"]
    B -->|"one line of status"| C["NotchLing"]
    C --> D(("Rex or Ellie<br/>reacts"))
```

Everything happens on your Mac. NotchLing needs no account and no API keys, and it never asks for Screen Recording, Accessibility or Full Disk Access.

## Set up in under a minute

<table>
  <tr>
    <td align="center" width="33%"><img src=".github/assets/install.png" alt="The installer window: drag NotchLing to Applications"></td>
    <td align="center" width="33%"><img src=".github/assets/setup-1-welcome.png" alt="NotchLing's welcome screen"></td>
    <td align="center" width="33%"><img src=".github/assets/setup-2-companion.png" alt="Choosing Rex or Ellie"></td>
  </tr>
  <tr>
    <td align="center"><b>1.</b> Drag it to Applications</td>
    <td align="center"><b>2.</b> Open it</td>
    <td align="center"><b>3.</b> Pick a companion, then connect your tools</td>
  </tr>
</table>

## Works with

| Agent | Where it works |
|---|---|
| **Claude Code** | Terminal, and the Code tab in the Claude desktop app |
| **Codex** | Codex CLI and the ChatGPT desktop app. Trust the hooks once in Codex **Settings → Hooks** |
| **Cursor** | Cursor's agent hooks |
| **Antigravity** | Antigravity's agent hooks |

> [!NOTE]
> Chats that don't run hooks aren't supported. That includes regular Claude and ChatGPT chats outside Claude Code and Codex.

<details>
<summary><b>Requirements</b></summary>

<br>

macOS 14 (Sonoma) or later, on a MacBook with a notch. Apple Silicon and Intel are both supported.

</details>

<details>
<summary><b>Uninstall</b></summary>

<br>

1. Open **••• → Connections…** and click **Disconnect** on each tool. This removes NotchLing's hooks from your agents' settings.
2. Quit NotchLing from the **•••** menu and move it to the Trash.
3. Optional: delete `~/Library/Application Support/NotchLing`.

You can also remove every hook from Terminal before trashing the app:

```bash
/Applications/NotchLing.app/Contents/Helpers/notchling-bridge uninstall all
```

</details>

<details>
<summary><b>Build from source</b></summary>

<br>

```bash
xcodebuild -project NotchLing.xcodeproj -scheme NotchLing -configuration Release build
./Scripts/check-notchlings && ./Scripts/test-integrations
```

</details>

## License

[MIT](LICENSE)
