# macOS Setup Scripts

Automated setup that makes macOS keyboard behavior feel like Windows (with
Linux‑style shortcuts inside the Terminal, and correct modifier handling
inside Microsoft Remote Desktop / Windows App). Installs and configures:

- **Karabiner‑Elements** — with the complex modification rules defined in
  [`windows-karabiner.json`](./windows-karabiner.json).
- **Rectangle** — window manager whose Recommended preset binds
  `Ctrl+Option+Left/Right/Up` for Left Half / Right Half / Maximize.
  Karabiner’s tiling rule sends exactly those keys when you press
  `Option+Left/Right/Up`.
- **Two macOS symbolic hotkeys** the Karabiner rules depend on:
  - `Cmd+Shift+L` → Show Launchpad
  - `Cmd+Shift+D` → Show Desktop

Everything is user‑scoped. Do **not** run these scripts with `sudo`.
`common.sh` refuses to run as root and on non‑Darwin systems.

## Requirements

- macOS (built and tested on Tahoe / 26.x)
- [Homebrew](https://brew.sh/) — used to install `jq`, `karabiner-elements`,
  and `rectangle`
- A regular user account (not root)

## Quick start

```zsh
cd osx
./setup.sh
```

That will:

1. Install any missing dependencies via Homebrew (`jq`, `karabiner-elements`,
   `rectangle`).
2. Configure the two macOS symbolic hotkeys.
3. Launch Rectangle so you can accept the **Recommended** preset and grant
   it Accessibility permission.
4. Merge the rules from `windows-karabiner.json` into every profile in
   `~/.config/karabiner/karabiner.json`, replacing any prior versions.
5. Run a post‑install sanity check and print a ✅/⚠/✗ summary.

Re‑run any time. Everything is idempotent: unchanged files are left alone
and existing rules are replaced in place, not duplicated.

### On first run you will need to click through two GUI prompts

- **Karabiner‑Elements**: grant Input Monitoring + Accessibility + approve
  a system extension in System Settings → Privacy & Security.
- **Rectangle**: click **Recommended** in its welcome window, then grant
  Accessibility.

Neither can be automated from a script; macOS forbids it.

## Scripts

| Script | Purpose |
|---|---|
| [`setup.sh`](./setup.sh) | Orchestrator. Runs the three step scripts, then a sanity check. |
| [`common.sh`](./common.sh) | Shared logging + helpers. Refuses to run as root / on non‑macOS. |
| [`keyboard-shortcuts.sh`](./keyboard-shortcuts.sh) | Configures `com.apple.symbolichotkeys` for Launchpad and Show Desktop. |
| [`tiling-window-manager.sh`](./tiling-window-manager.sh) | Installs Rectangle, launches it, prints first‑run instructions if unconfigured. |
| [`karabiner-install.sh`](./karabiner-install.sh) | Validates the source JSON, installs Karabiner‑Elements, merges rules into every profile of `karabiner.json`. |
| [`diagnose-tiling.sh`](./diagnose-tiling.sh) | Read‑only diagnostic. Prints everything relevant to why `Option+Arrow` tiling might not be working. |

## Flags

```
./setup.sh                     apply everything (safe defaults)
./setup.sh --debug             verbose logging
./setup.sh --force-shortcuts   overwrite custom bindings for the macOS
                               shortcuts we manage
./setup.sh --reset-shortcuts   remove our managed macOS shortcut entries
                               (revert to macOS defaults); Karabiner
                               install step still runs
./setup.sh --diagnose          run diagnose-tiling.sh and exit
```

## How the Karabiner merge stays clean

Every rule in `windows-karabiner.json` has its `description` prefixed with
`[windows-karabiner]`. `karabiner-install.sh`:

1. Validates the source JSON is well‑formed.
2. Refuses to run if any rule is missing the prefix (prevents shipping a
   rule that would silently pile up as a duplicate on every re‑run).
3. Refuses to run if two rules in the source share a description
   (they would collapse into one on install).
4. In each profile of `karabiner.json`, deletes any rule whose description:
   - starts with `[windows-karabiner]`, OR
   - matches a current description with the prefix stripped (handles the
     one‑time transition from unprefixed to prefixed rules), OR
   - appears in the hardcoded `LEGACY_DESCRIPTIONS` list (rules we shipped
     under a different name in the past and have since renamed).
5. Appends the fresh set of rules.

When renaming a rule in `windows-karabiner.json`, add its **old** description
to `LEGACY_DESCRIPTIONS` in [`karabiner-install.sh`](./karabiner-install.sh)
so re‑running the installer cleans the stale copy out of every user’s
`karabiner.json`.

## Diagnosing problems

```zsh
./diagnose-tiling.sh
```

Reports:

- Whether Karabiner‑Elements processes are running.
- Which Karabiner profile is active and whether the tiling rule is present
  with the correct `to`.
- Which devices have `modify_events` disabled.
- Whether Rectangle is installed, running, and has shortcuts bound.
- Whether Rectangle has Accessibility permission (best‑effort).
- The last 20 lines of the Karabiner user‑server log.

## Reset / uninstall

- **macOS keyboard shortcuts back to defaults**:
  `./setup.sh --reset-shortcuts`
- **Karabiner rules only**: delete rules whose description starts with
  `[windows-karabiner]` from the active profile in
  `~/.config/karabiner/karabiner.json`, or uninstall Karabiner‑Elements
  via `brew uninstall --cask karabiner-elements`.
- **Rectangle**: `brew uninstall --cask rectangle`.
