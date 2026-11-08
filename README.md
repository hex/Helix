<div align="center">
    <img src="AppIcon/v8_1.png" width="180" height="180" alt="Helix app icon">
    <h1>Helix</h1>
    <p>A native macOS menu bar app for managing <a href="https://mutagen.io">mutagen</a> file sync and network forwarding sessions.</p>
</div>

<p align="center">
    <img src="https://img.shields.io/badge/platform-macOS-blue?style=flat-square" alt="Platform">
    <img src="https://img.shields.io/badge/requirements-macOS%2014%2B-fa4e49?style=flat-square" alt="Requirements">
    <img src="https://img.shields.io/badge/swift-5.9-F05138?style=flat-square" alt="Swift">
    <img src="https://img.shields.io/badge/version-2026.11.1-blue?style=flat-square" alt="Version">
    <a href="https://helix.hexul.com"><img src="https://img.shields.io/badge/website-helix.hexul.com-4A90D9?style=flat-square" alt="Website"></a>
</p>

---

## Features

- **Menu bar status** -- Live icon reflects overall session health at a glance (healthy, syncing or connecting, paused, a warning for conflicts or a session that cannot connect, errors); pick a monochrome icon set (Arrows, Helix, H Mark) or the colored Legacy one in Settings
- **Menu bar menu** -- Double-click the icon to open the main window. Right-click the icon to open Helix, pause every running sync session, pause them for the minutes you enter, or quit; Resume restores only the sessions Pause All paused, and a timed pause resumes on its own, even after you quit and reopen Helix. Helix records each confirmed pause before starting the next one, even if Mutagen reports a save error. When you edit a session paused by Pause All, the replacement inherits its pause and deadline. Pause All waits for a conflict resolve to finish before pausing that session. It asks you to wait if an edit is running. Resume checks for running sessions on the same endpoints. Local paths under `/tmp` and `/private/tmp` count as the same folder. If a manual Resume finds a match, Helix names it and offers Resume Anyway. A timed pause leaves the session paused and shows the reason until you dismiss it or resume the session. Edits and conflict resolves can restore sessions that were already running together when the operation began.
- **Session dashboard** -- Browse, search, and filter all sync and forward sessions in a three-column window
- **Connection errors** -- When a session cannot connect, the detail view shows mutagen's own reason under the status line
- **Sync diagnostics** -- See scan and transition errors by endpoint and path. The detail view shows how many problems and conflicts Mutagen omitted, and running sessions with problems show a warning in the status icon.
- **Transfer progress** -- While a session stages files, the detail view shows a progress bar, files and bytes received, and the file mutagen is sending; the session list and menu bar show the same percentage as `mutagen sync list -l`
- **Create sessions** -- The sync wizard warns when an existing session uses the same endpoints and offers Create Anyway. The warning treats local paths under `/tmp` and `/private/tmp` as the same folder. Port forwarding uses a separate form.
- **Session configuration** -- See settings that differ from Mutagen's defaults and overrides for Alpha and Beta.
- **Edit sessions** -- Rename a session or change its sync mode, ignore rules, symlinks, compression, and watch settings. Helix prepares a paused replacement before removing the original. The replacement starts with fresh sync history. Helix carries over the listed settings for the session and both endpoints. Recreating a session bypasses the current global defaults. If Mutagen cannot express an endpoint override, Helix names it and keeps the original. If Helix quits mid-edit, the main window identifies the sessions to inspect after relaunch. If Pause ends early, Helix continues the edit only when the original shows a paused status. After an interrupted Resume, Helix removes the original only after Mutagen reports both replacement endpoints connected. During recovery, Helix resumes the original only if the replacement shows a paused status or disappears from the list. If Mutagen still lists both sessions, Helix protects the original and offers Remove original in its details. When a sync Create reports an uncertain outcome, check for the named session before retrying. If an edit leaves the original paused, open its details and choose Remove original. Helix checks that the replacement is still listed and unpaused first. You can edit the replacement again, and Helix keeps the original protected across that edit.
- **Unique names** -- Rejects a name another session already holds, so `mutagen sync pause <name>` always resolves to one session
- **Labels** -- Tag sessions with key=value pairs and filter the dashboard by them
- **Connection testing** -- Check an SSH endpoint before creating a session, then browse the remote filesystem to pick a path
- **Interrupted operations** -- If a command ends early during an edit or conflict replacement, Helix saves the recovery record. Reopen Helix to review the edit or inspect the paths shown on a held session. If Helix cannot confirm removal of an incoming copy, it keeps the session paused and shows the path to check. Helix stages the incoming copy as `.helix-incoming-<uuid>` beside the destination. If it sets the original aside, it uses `.helix-replaced-<uuid>` in the same directory.
- **Command deadlines** -- Helix gives probes and queries 15 seconds, other operations 45 seconds, and transfers 15 minutes. The clock pauses while the Mac sleeps. Tree removal, sync Create, Resume, and Flush use the transfer limit. If Resume ends early, Helix checks the session list. If it cannot confirm the session is running, Helix skips Flush and asks you to check the session status. A timeout names the executable and its limit. Helix drains the remaining output if the command has exited and no process still holds its pipes open. On a timeout, Helix closes the pipes and gives the command 250 milliseconds to stop before sending SIGKILL. If the process still hasn't exited after another 100 milliseconds, Helix reports the timeout and keeps tracking the child for quit. On a normal quit or update relaunch, Helix asks its active commands to stop and waits up to three seconds. Recovery records remain for unfinished edits and replacements. A crash or a SIGKILL of Helix ends its timers and skips quit cleanup, so remaining commands depend on their own limits.
- **Conflict resolution** -- Inspect per-file conflicts side by side, keep either side with one click across local, SSH, and Docker endpoints; handles file-vs-directory type mismatches with confirmation before destructive operations; a replacement that fails partway keeps both versions for recovery, including when a directory appears at the destination during the move; when Helix cannot tell what is at the destination, the session stays paused and shows where the data is until you resume it yourself, and neither Resume after Pause All nor another resolve resumes it; if Helix quits or crashes during a replacement, the next launch keeps that session paused the same way and names the paths to check; while a resolve runs on a session Helix refuses to resume it, and while a resolve runs or Helix keeps the session paused it refuses to edit the session or add to its ignore list, since both recreate it; while Helix is editing a session it refuses to resolve the session's conflicts or to resume it, and Resume after Pause All leaves it for the next attempt. Polling updates conflict details and clears the badge when Mutagen stops reporting conflicts.
- **Diff viewer** -- Line and word-level diffs of conflicting files, backed by a Rust engine
- **Symlink awareness** -- Shows what each side of a symlink conflict points at, and replaces a symlink with a directory where that is the only resolution
- **Endpoint support** -- Local paths, SSH remotes, and Docker containers with transport-aware file operations
- **Git mismatch detection** -- Detects when a git repo exists on one sync endpoint but not the other, with automatic fix to initialize the missing side; checks only while mutagen reports both endpoints connected
- **Console log** -- Dark-themed (Tokyo Night) panel with timestamped, color-coded CLI output and full multi-line text selection
- **Keyboard shortcuts** -- `Cmd+N` new sync, `Cmd+Shift+N` new forward, `Cmd+R` refresh
- **CLI preview** -- Every create/edit form shows the exact `mutagen` command before you run it, with a copy button
- **Auto-update** -- Built-in Sparkle integration checks for updates from the menu bar
- **Launch at login** -- Optional login item via SMAppService
- **Configurable polling** -- Adjust refresh interval from 2 to 30 seconds
- **Daemon controls** -- After Stop, Helix does not start Mutagen until you choose Start. Login items and other tools can still start Mutagen. Helix checks for the daemon process at the usual polling interval. If Mutagen starts outside Helix, Manage Sessions takes over without sending a start command. Stop Again requests another stop. Session commands stay unavailable while you leave Helix stopped. Finish any edit, bulk pause or resume, or conflict resolve before stopping. Helix remembers Stop across relaunches and updates. If Stop returns an error, Helix checks the Mutagen process. If the check fails, Helix stays stopped and checks again at the next poll. Settings shows when Stop is waiting for running commands. Stop can wait up to 15 minutes for a transfer-class command, 45 seconds for the stop command, and 15 seconds to check status on failure. Each stage can add up to 350 milliseconds for signal handling and waiting for exit.
- **Background priority** -- Mutagen yields CPU and disk while the Mac is busy, which can slow transfers. Settings shows whether the priority applied and why it failed. Helix retries a saved request after a daemon restart. After Stop, Settings shows that a pending request will apply when Mutagen starts.
- **Text size** -- Adjustable text size (System Default, Small, Medium, Large, Extra Large) in Settings

## Install

### Homebrew

```sh
brew install --cask hex/tap/helix
```

### Manual

Download the latest `.dmg` from the [releases page](https://github.com/hex/Helix/releases).

### Build from Source

Requires [XcodeGen](https://github.com/yonaskolb/XcodeGen) and Xcode 16+.

```sh
git clone https://github.com/hex/Helix.git
cd Helix
xcodegen generate
xcodebuild -project Helix.xcodeproj -scheme Helix -configuration Release build
```

## Requirements

- macOS 14 (Sonoma) or later
- [mutagen](https://mutagen.io) installed (default path: `/opt/homebrew/bin/mutagen`, configurable in Settings)

## How It Works

Helix is a SwiftUI companion app that wraps the mutagen CLI. It does not embed mutagen or communicate with the daemon directly -- instead it shells out to `mutagen sync list --template '{{json .}}'` and friends, parsing the JSON output into native Swift models. For the background priority switch, Helix finds the daemon process with `pgrep` and lowers its priority with `taskpolicy`, which needs no sudo.

The architecture is split into two layers:

| Layer | Description |
|-------|-------------|
| **HelixKit** | Swift Package providing models, CLI wrapper, session state management, and cross-transport file operations |
| **App** | SwiftUI menu bar app with views, components, and keyboard commands |

HelixKit defines a `SessionProvider` protocol so the entire CLI surface can be swapped out for testing.

## Project Structure

```
Helix/
  App/
    HelixApp.swift          # Entry point, menu bar + window scenes
    Views/                  # Main window, detail views, create/edit sheets
    Components/             # Reusable UI (StatusBadge, EndpointPicker, etc.)
  Sources/HelixKit/
    CLI.swift               # Concrete mutagen CLI wrapper
    SessionStore.swift      # Observable state + polling
    DaemonProcess.swift     # Finds the daemon with pgrep, sets its priority with taskpolicy
    CommandBuilder.swift    # Typed option structs -> argument arrays
    FileTransport.swift     # Cross-endpoint copy/stat/remove
    Models/                 # SyncSession, ForwardSession, Endpoint, Conflict
  Tests/HelixKitTests/    # Unit and integration tests
  Package.swift             # SPM package for HelixKit
  project.yml               # XcodeGen project definition
```

## License

[MIT License](LICENSE) -- Copyright (c) 2026 [hexul](https://hexul.com)
