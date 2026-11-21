<div align="center">
  <h1><img src="docs/hero.svg" width="864" alt="Hold to Dictate" /></h1>
  <p><strong>Hold a shortcut. Say it. Release to paste.</strong></p>
  <p>Push-to-talk dictation that puts your words in the app you were already using.</p>
  <p>
    <a href="https://github.com/slpkbt/hold-to-dictate/actions/workflows/macos.yml"><img src="https://github.com/slpkbt/hold-to-dictate/actions/workflows/macos.yml/badge.svg" alt="macOS build" /></a>
    <a href="https://github.com/slpkbt/hold-to-dictate/actions/workflows/windows.yml"><img src="https://github.com/slpkbt/hold-to-dictate/actions/workflows/windows.yml/badge.svg" alt="Windows build" /></a>
    <a href="LICENSE"><img src="https://img.shields.io/badge/license-MIT-3584d7" alt="MIT license" /></a>
  </p>
  <p>
    <a href="#get-started"><strong>Get started</strong></a>
    &nbsp;·&nbsp;
    <a href="#speech-engines"><strong>Speech engines</strong></a>
    &nbsp;·&nbsp;
    <a href="#settings"><strong>Settings</strong></a>
    &nbsp;·&nbsp;
    <a href="README-RU.md"><strong>Русский</strong></a>
  </p>
</div>

---

## How it feels

| 1. Hold | 2. Speak | 3. Release |
| :--- | :--- | :--- |
| Press and hold your shortcut. | The overlay shows your mic level and available partial text. | The final text goes to your clipboard. With auto-paste enabled, it goes into the original field when the target is still safe. |

<p align="center">
  <img src="docs/preview.png" width="690" alt="Hold to Dictate on macOS: a floating overlay with a waveform and live transcription" />
  <br /><sub>The macOS overlay. The banner above is an illustration.</sub>
</p>

**No text is sent for you.** Hold to Dictate does not press Enter. Audio recordings and transcript history are not written to disk by the app. The finished text remains in your system clipboard.

## Get started

| Platform | Default shortcut | How to start |
| :--- | :--- | :--- |
| **macOS 13+** · Apple Silicon / Intel | <kbd>⌘</kbd> <kbd>⇧</kbd> <kbd>K</kbd> | [Download for Mac](https://github.com/slpkbt/hold-to-dictate/releases) or [build from source](#macos) |
| **Windows 11** / [supported Windows 10](https://learn.microsoft.com/en-us/dotnet/core/install/windows#supported-versions) · x64 | <kbd>Ctrl</kbd> <kbd>Shift</kbd> <kbd>K</kbd> | [Build and set up Windows](#windows) |

### macOS

1. Download the ZIP from [Releases](https://github.com/slpkbt/hold-to-dictate/releases), extract it, and move **Hold to Dictate.app** to **Applications**. The published build uses ad-hoc signing and is not notarized by Apple. If you prefer, build it yourself with Xcode Command Line Tools.
2. Open the app and click the waveform in the menu bar. Use the permissions item to allow **Microphone** and, for auto-paste, **Accessibility**. Without Accessibility, the finished text still goes to the clipboard.
3. Hold <kbd>⌘</kbd> <kbd>⇧</kbd> <kbd>K</kbd> to try it. To start automatically at sign-in, enable the launch-at-login option in the same menu.

<details>
<summary><strong>Build, run, or preview on Mac</strong></summary>

```bash
./scripts/build.sh
./scripts/run.sh
./scripts/run.sh --preview
```

The preview uses sample text. No mic, network connection, or permissions are needed.

</details>

### Windows

1. For a local build, install the [.NET 10 SDK](https://dotnet.microsoft.com/download/dotnet/10.0), clone this repository and run in PowerShell:

   ```powershell
   .\scripts\build-windows.ps1 -Check
   ```

   The script writes the self-contained x64 ZIP and SHA-256 to `dist\windows\`. Extract the entire ZIP to a folder you intend to keep. The ZIP doesn't need a separate .NET installation; it is not code-signed. CI packages this port in [Windows Actions](https://github.com/slpkbt/hold-to-dictate/actions/workflows/windows.yml), not the macOS-only release ZIP.
2. Run **HoldToDictate.exe**. Open **Hold to Dictate** in the notification area (including **Show hidden icons**) and choose **Settings…**. Hold <kbd>Ctrl</kbd> <kbd>Shift</kbd> <kbd>K</kbd>, speak, and release either the letter or a modifier to finish. <kbd>Esc</kbd> cancels. Windows defaults to copy-only; press <kbd>Ctrl</kbd> <kbd>V</kbd> to paste, or turn on auto-paste in Settings.
3. If needed, [allow desktop apps to access the microphone](https://support.microsoft.com/en-us/windows/privacy/turn-on-app-permissions-for-your-microphone-in-windows). For the local engine, choose an installed speech recognizer in Settings. **A display language alone may not include a desktop speech recognizer.**

Try **Preview overlay** in the tray menu without the mic. If the hotkey is reserved, choose another one in Settings. If an elevated window rejects auto-paste, paste manually instead of running the dictation app as administrator.

## Speech engines

| Platform | Engine | Where the audio goes |
| :--- | :--- | :--- |
| macOS | **Codex** (default) | PCM audio streams to ChatGPT while you hold the shortcut. Partial text appears as the service returns segments. |
| macOS | **On-device** | Apple Speech keeps audio on your Mac. The chosen language needs a local speech model. |
| Windows | **On-device** (default) | Windows speech recognition processes audio locally using an installed matching speech recognizer. |
| Windows | **Codex** (opt in) | The app streams audio to ChatGPT using an existing file-based Codex sign-in. |

<details>
<summary><strong>How Codex sign-in works</strong></summary>

The app uses your existing Codex ChatGPT sign-in from `$CODEX_HOME/auth.json`, or `~/.codex/auth.json` on Mac / `%USERPROFILE%\.codex\auth.json` on Windows if `CODEX_HOME` is not set. It connects to ChatGPT directly using a private dictation protocol observed in Desktop 26.1111.21308, not a stable public API. Availability depends on your account and may change. The app never logs or separately saves sign-in credentials. Codex manages login and refresh; if your session expires, open Codex and sign back in. Keychain-backed sessions are not supported.

</details>

## Settings

### macOS

Choose **Open Settings** from the waveform menu, edit the JSON, and then choose **Apply Settings**. You can keep only the overrides you want. See the [default settings](Resources/settings.json).

| Option | What it controls |
| :--- | :--- |
| `shortcut` | For example, `cmd+shift+k` or `ctrl+opt+space`. Modifiers: `cmd`, `shift`, `opt`, `ctrl`. Keys: A–Z, 0–9, Space, F1–F12, using the physical layout. |
| `engine` | `codex` or `onDevice`. |
| `language` | Locale for local recognition. In Codex mode, the server detects the language. |
| `pasteAutomatically` | Paste into the original field when safe. The final text is copied either way. |
| `playSound`, `startSound` | Enable the recording-start cue, and select a system sound or an absolute file path. |
| `appearance.textColor` | Text and waveform color as `#RRGGBB`. |
| `appearance.backgroundOpacity` | Panel opacity, 0.42–1. |
| `appearance.width`, `appearance.textSize` | Text block width in points and text size from 12 to 24 points. |
| `appearance.maxLines` | Show up to 14 lines. Longer recordings show the latest lines. |
| `appearance.verticalOffset`, `appearance.horizontalOffset` | Offsets from screen center in points. |
| `appearance.reduceMotion` | Disable overlay animation. The overlay also respects the system Reduce Motion setting. |

### Windows

Right-click the tray icon → **Settings…**. Preferences are saved to `%LOCALAPPDATA%\HoldToDictate\settings.json`. Windows settings are separate from the Mac JSON.

| Setting | What it controls |
| :--- | :--- |
| **Global shortcut** | Default `Ctrl+Shift+K`; supports Ctrl, Alt, Shift, Win and A–Z, 0–9, Space, F1–F11. Reserved or unavailable combinations are rejected. |
| **Recognition engine**, **Windows Speech language** | On-device by default. Blank language uses the matching Windows UI language or the first installed desktop recognizer. Codex is opt-in. |
| **Paste into the original field when safe** | Off by default. Requires the original window and focused control to still match; otherwise the text is copied only. |
| **Overlay accent**, **Overlay width** | Hex color and width in device-independent units. |
| **Play a sound**, **Launch at sign-in** | Both off by default. Sign-in startup points to the executable’s current path. |

Hold-to-talk is limited to 60 seconds per take on Windows.

## Development

On macOS, run `./scripts/check.sh` for local checks and `./scripts/release.sh` for the universal ZIP and SHA-256 in `dist/`. The version comes from `Resources/Info.plist`. The macOS workflow checks the archive and publishes a GitHub Release for a `v<version>` tag. See the [Windows port design and QA checklist](docs/windows-port.md).

Report bugs or suggest improvements in [GitHub Issues](https://github.com/slpkbt/hold-to-dictate/issues). Please include your OS version, recognition engine, and whether the problem is with recording, recognition, or pasting. Don’t attach audio, transcripts, or sign-in files unless you explicitly want to share that data; never attach credentials.

## License

[MIT](LICENSE)
