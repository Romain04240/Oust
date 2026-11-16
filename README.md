<p align="center">
  <img src="Design/oust-icon-1024.png" width="128" alt="Oust! icon">
</p>

<h1 align="center">Oust!</h1>

<p align="center">
  <strong>Clear out your Mac, safely.</strong><br>
  A native macOS app that shows where your disk space went, explains every item,
  lets you choose, and cleans up properly — with an honest report and a history you can undo.
</p>

<p align="center">
  macOS 26 · Apple Silicon & Intel · offline analysis · no telemetry
</p>

![Overview](docs/screenshots/overview.png)

---

## Why Oust!

Most cleaners show a big flattering number, delete things for good, and phone home.
Oust! is built the other way round.

- **Honest numbers.** Oust! counts allocated size, not logical size; hard links and APFS
  clones are counted once; space held back by local Time Machine snapshots is shown
  separately. It only announces what will really come back.
- **The bin first.** Personal content goes to the Mac's Trash and into a history with its
  original path, so it can be restored. Only what rebuilds itself (caches, build artifacts)
  is removed on the spot.
- **Revalidated right before acting.** Every item is checked again just before it goes:
  it still exists, hasn't changed since the scan, no process is working in it, and its path
  passes a guard. When in doubt, the item is protected and Oust! says why.
- **Understands developer tools.** `node_modules`, `.build`, DerivedData, simulators,
  package caches, AI models, Claude Code and Codex histories and worktrees — with the
  rebuild cost of each item and automatic protection of anything with unique state
  (uncommitted changes, unpushed commits, a running process).
- **Local analysis.** No analytics, no file inventory sent, no third-party dependency. Manual update checks and installer downloads contact GitHub only when requested.

## Features

| | |
|---|---|
| **Overview** | Storage gauge with used, purgeable and selected space, one-click analysis of the startup disk or any other disk. |
| **Development & AI** | Project artifacts, Xcode, simulators, package caches, AI models, coding-agent leftovers, grouped by owner, each with its rebuild cost. |
| **Explorer** | Every folder from largest to smallest, a sunburst, file types, ages, largest files and growth since the last scan. |
| **Large & old files** | What you haven't opened in years, filtered by size and age. |
| **Duplicates** | Byte-for-byte duplicates that are aware of APFS clones (and can be turned into clones instead of deleted), plus similar images outside the Photos library. |
| **Photos** | Videos, screenshots, exact duplicates, similar shots and "useful" photos (receipts, labels, documents) through PhotoKit — never by opening the library package. |
| **Cloud** | The largest, oldest and duplicate files of iCloud Drive and File Provider services, read from the placeholders on your Mac, without downloading anything. |
| **System** | The Mac's Trash, downloads, application caches, iOS backups and virtual machines. |
| **Time Machine** | Local snapshots, APFS sizes, chronological review and a limited administrator component you can authorize once in macOS. |
| **Storage advice** | A plan with suggestions below it; expand each suggestion to inspect its files and choose an action. |
| **Move to a drive** | Copy files or folders to an external drive, verify their contents, then send originals to the Mac's Trash. An error keeps the originals. |
| **Applications** | Uninstall with leftovers, and leftovers offered as soon as you drag an app to the Trash. |
| **Browsers** | Cache, history and cookies per profile, kept separate; never passwords. |
| **Disks** | One pill per mounted disk in the toolbar: free space, breakdown, rename, eject, format and partition external disks. |
| **Maintenance** | A scheduled check that tells you what can be recovered, a low-disk alert and a menu bar panel. |

![Development & AI](docs/screenshots/development.png)

![Explorer](docs/screenshots/explorer.png)

![Duplicates](docs/screenshots/duplicates.png)

![Disk panel](docs/screenshots/disk-panel.png)

<p align="center">
  <img src="docs/screenshots/pill.png" width="640" alt="Low-disk alert pill"><br>
  <em>The low-disk alert, a floating pill whose outline is the gauge.</em>
</p>

<p align="center">
  <img src="docs/screenshots/settings.png" width="560" alt="Settings">
</p>

## Install

1. Download the latest `Oust-x.y.z.dmg` from [Releases](../../releases).
2. Drag **Oust!** to **Applications** and open it.
3. Oust! works without Full Disk Access, and tells you what it can't see. To analyze
   Mail, Messages, Safari and the Trash too, grant it in **System Settings › Privacy &
   Security › Full Disk Access**.

## Safety model

Every item belongs to a safety class:

| Class | Meaning |
|---|---|
| **Safe** | Rebuilds itself or is clearly disposable. May be preselected. |
| **Rebuilds** | Comes back with a command or a download. Preselected only after a recency guard. |
| **Review** | Yours to decide (AI models, histories, downloads, similar duplicates). Never preselected. |
| **Protected** | Not selectable, with the reason shown. |

Deletion only ever goes through one module (`OustClean`), using the right tool when there is
one (`git worktree remove`, `xcrun simctl`, `tmutil`). The only deletion that bypasses the
Trash is formatting an external disk, behind its own guards (never an internal or startup disk,
disk name typed, nothing open on it). See [RULES.md](RULES.md).

## Build from source

Requirements: Xcode 27 and [XcodeGen](https://github.com/yonaskolb/XcodeGen)
(`brew install xcodegen`).

```bash
xcodegen generate && open Oust.xcodeproj
```

The Xcode project is generated from `project.yml` and is not versioned. Modules build and
test on their own:

```bash
Scripts/run-tests.sh   # every test target
Scripts/verify.sh      # lint, release build, tests, signed app build
Scripts/run-app.sh     # build and launch a signed development copy
```

`run-app.sh` verifies the Developer ID signature, keeps the previous app under
`build/PreviousInstalledApp.*`, and replaces `/Applications/Oust.app` on the same
volume before launching it. The administrator component is authorized through
macOS; after its executable changes, Settings › Advanced offers an explicit repair.
The app never stores an administrator password.

The administrator component requires a notarized app. `run-app.sh` signs its build
but does not notarize it; a changed build needs a new notarization ticket. To test
the component, notarize and staple that exact build before installing or repairing
the component.

Release build, signed with Developer ID, then the disk image:

```bash
Scripts/release.sh && Scripts/dmg.sh
```

### Architecture

| Module | Role |
|---|---|
| `OustCore` | Pure domain: items, sizes, safety classes, methods |
| `OustScan` | `getattrlistbulk` traversal, tree, accurate sizes, never leaving the volume |
| `OustVolume` | Volumes, capacities, snapshots, space reclaim |
| `OustSafety` | Path guard, running processes, git inspection |
| `OustRules` | Rule catalog and finders |
| `OustClean` | Deletion, history, restore |
| `OustDuplicates` | Duplicates aware of APFS clones, similar images |
| `OustPhotos`, `OustClouds`, `OustBrowsers`, `OustUninstall`, `OustWatch` | Photos, cloud, browsers, applications, maintenance |
| `OustModel` | Application state |
| `OustAgent` | `oust`, the command line and MCP server |
| `Feature*` | One section of the interface each |

## Command line & MCP

Coding agents leave `node_modules`, `.build`, DerivedData, worktrees and caches behind.
`oust` gives them Oust!'s engines — the same rules, the same revalidation, the same history —
as a command line tool and an MCP server that only talks over stdin/stdout.

```bash
mkdir -p ~/.local/bin && ln -sf /Applications/Oust.app/Contents/MacOS/oust-cli ~/.local/bin/oust
oust scan --json --path . --finders projectArtifacts
```

| Command | What it does |
|---|---|
| `oust scan [--json] [--finders NAME,…] [--path PATH]… [--limit N]` | Dry-run analysis: each item with its freeable size, safety class, method, rebuild cost and protections. Returns a preview token valid for 30 minutes. |
| `oust explain ID [--json]` | What it is, how it comes back, what Oust! will do, why it is protected. |
| `oust clean ID… [--token TOKEN] [--allow-review] [--dry-run] [--json]` | Cleans items shown by a recent scan, through `OustClean`. |
| `oust mcp` | MCP server on stdio with the `scan`, `explain` and `clean` tools. |

Register it with an MCP client, for example:

```bash
claude mcp add --scope user oust -- "$HOME/.local/bin/oust" mcp
```

```toml
# ~/.codex/config.toml
[mcp_servers.oust]
command = "/Users/you/.local/bin/oust"
args = ["mcp"]
```

Agents can only clean what a scan of the last 30 minutes showed, never anything protected,
never anything needing an administrator password, and "review" items only with
`--allow-review`. Everything goes into Oust!'s history.

## Privacy

Oust! analyzes files and generates recommendations locally, with no analytics or file inventory sent.
Update checks and installer downloads contact GitHub only when you request them. Downloads are
verified against the publisher's Developer ID signature before opening; quit Oust! and replace
it in Applications through Finder. In the Photos preview, downloading an original from iCloud
also requires your confirmation and is performed by Photos.

## License

The Oust! source code is licensed under the [GNU General Public License, version 3](LICENSE) (GPL-3.0-only).

Copyright © 2026 Daniel-Romain BLANC EI — BLANC-Conseil · [blanc-conseil.fr](https://blanc-conseil.fr)
