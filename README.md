# bibi: a local agent on the macOS Foundation Model

`bibi` is a small agent that runs tasks ("skills") on your Mac. It uses Apple's on-device Foundation Model, called directly through the FoundationModels framework. Analysis and reasoning happen on your Mac. Nothing goes to the internet unless a skill is marked `[web]` or you pass `--online`.

```
bibi <command> [arguments]
bibi ui
```

> [!WARNING]
> **Experimental software, provided "as is", with no warranty of any kind.** bibi is a personal experiment in local agentic workflows. The model can be wrong, and sometimes confidently wrong. Some skills can delete files, change system settings or run commands when you approve them. Read every recommendation before you approve it, keep backups (Time Machine or similar), and start with `--dry-run`. **Use at your own risk.** The authors accept no liability for data loss or any other damage.

## Requirements

- macOS 26 or later with Apple Intelligence turned on
- Swift 6.2+ (the Command Line Tools are enough; Xcode is not required)

## Install

```sh
make install          # release build into ~/.local/libexec/bibi, symlinked as ~/.local/bin/bibi (override with PREFIX=...)
bibi list
```

For development, `./bin/bibi` builds if needed and runs from the repo. Run the tests with `make test` (`swift run bibi-tests`).

## Commands

Skills are grouped into namespaces: `bibi list` shows all of them, and `bibi storage` shows one group.

| Command | What it does |
| --- | --- |
| `storage.optimize [path]` | Analyzes disk usage and recommends the top N cleanup actions |
| `dev.cleanup` | Finds build folders, Docker leftovers, package caches, unused SDKs and stale git worktrees |
| `sys.health` | Checks CPU, memory, disk I/O, battery, thermal state, login items, crashes and log faults, and links them into likely causes |
| `sec.audit` `[web]` `[admin]` | Audits the firewall, FileVault, Gatekeeper/SIP, updates, sharing services, listening ports, persistence and lock settings |
| `net.identify <mac\|ip\|name>` `[web]` | Identifies a device on your network |
| `ui` | Opens the web UI |
| `history`, `undo`, `diff` | Lists saved runs, undoes actions, and compares runs over time |

`[web]` = can contact internet services. `[admin]` = some of its actions need your password.

Options shared by every skill:

| Option | Meaning |
| --- | --- |
| `--dry-run` | Shows what would run without changing anything |
| `--select 1,2,5` / `all` / `none` | Answers the "run which?" prompt up front (for scripts) |
| `--online` | Allows internet lookups (pending updates, vendor docs, versions, advisories) |
| `--web` | Shows the run in the web UI instead of the terminal |
| `--since 7d` / `<run>` | Baseline to compare with (default: the newest run at least 6 days old) |
| `-v, --verbose` | Prints each model verdict as it comes in |

At the "Run which?" prompt, `d 3` shows the evidence for action 3 and `p 1,2` previews actions 1 and 2.

## How bibi decides

- **Evidence first.** Every skill collects observations (command output, files, system APIs), each recorded with its exact source. Deterministic rules turn them into findings with a severity and a confidence.
- **fm explains; it doesn't detect.** The model explains each finding and may link several findings into a hypothesis. bibi keeps only what cites real observations. The model can lower a rule's confidence, and raise it by at most 15 points, and only when it cited real evidence. Each finding shows its uncertainty (low, medium or high) and whether a rule or fm wrote the explanation.
- **Safe action registry.** fm never writes commands. Only actions registered in bibi can run, each with fixed parameters that are validated when it's recommended and again right before it runs. Read-only diagnostic commands come from a fixed catalog too.
- **Dry-run and undo.** Every action can be previewed. Reversible actions record how to reverse them:
  - Trash moves can be put back.
  - Login items are moved to `~/Library/Application Support/bibi/quarantine`, not deleted.
  - Firewall and sharing changes can be switched back.
  Irreversible actions are labeled as such.
- **Admin actions ask for your password every time.** In the terminal, bibi runs them with `sudo -k`. In the web UI, macOS shows its own password dialog. bibi and the browser never see the password, and each admin action also needs a separate confirmation first.
- **Audit history.** Each run is saved under `~/Library/Application Support/bibi/runs/` (override with `BIBI_HOME`) with:
  - the report: observations, findings, facts
  - every model prompt and response
  - every network request
  - a journal of what you selected, previewed and ran, with results, errors and undo records
- **Baselines.** Each run stores comparable facts (listeners, login items, sizes, versions, battery capacity...). The next run shows what changed. In `sec.audit`, a new listening port or startup item is a finding on its own.

```sh
bibi history                 # recent runs
bibi history show <run>      # findings, actions taken, model and network counts
bibi undo <run>              # reverse what a run did (asks which)
bibi diff sec.audit --since 30d
```

## Web UI

```sh
bibi ui                      # or: bibi sys.health --web
```

The web UI starts a server on `127.0.0.1` and opens your browser with a one-time access token in the URL. From there you can:
- launch any skill from a form
- watch its progress live
- expand the evidence behind each finding and run or copy its diagnostic commands
- **Approve** or **Skip** each recommendation, preview it, then run the approved ones (optionally as a dry run)
- browse **History** (with undo) and **Changes** (baseline diffs)

The server only answers requests that carry the token, and refuses any whose Host or Origin isn't the server itself. Everything is served from the binary, with no CDN, so it works offline.

### storage.optimize

```sh
bibi storage.optimize               # analyze ~, recommend the top 5
bibi storage.optimize ~/dev -n 10   # another folder, top 10
bibi storage.optimize --dry-run -v  # watch the reasoning without risk
```

1. A single `du` pass measures the folder tree.
2. Each entry larger than `--min-size` (default 200M) goes to fm in its own small prompt. fm returns *act*, *descend* (look inside) or *skip*, with a safety and a confidence rating.
3. bibi descends into *descend* entries, up to `--depth` levels (default 3).
4. On the way back up, it merges duplicates, drops overlapping suggestions, and can ask fm whether several cache folders should become one "clear the parent" action.

Safety rules:

- Permanent deletion is used only on paths a built-in rule recognizes as regenerable (caches, logs, build output, `node_modules`, virtualenvs). Everything else goes to the Trash, which `bibi undo` can reverse.
- System folders, app bundles, iCloud, Mail, Messages, Photos, Keychains, device backups and git repositories can only be *reviewed*, whatever the model says.
- Moving an unknown item to the Trash is never rated above 6/10 safety.

Note: macOS only lets the terminal measure Desktop, Documents, Downloads and similar folders if the terminal app has **Full Disk Access**.

### dev.cleanup

```sh
bibi dev.cleanup                         # looks in ~/dev, ~/src, ~/code, ~/projects, ~/work, ~/Developer...
bibi dev.cleanup --root ~/clients --active-days 60
```

- **Active projects are never touched.** That means projects with uncommitted changes or activity within `--active-days`.
- **Build folders are deleted only when they can be rebuilt.** The folder's manifest must be there (`package.json`, `pyproject.toml`, `Cargo.toml`, `Package.swift`...). Without a lockfile, the safety rating drops because a reinstall may pick newer versions.
- **SDK versions stay if anything uses them.** A runtime version pinned by a project (`.python-version`, `.nvmrc`, `.tool-versions`...), set as the global default, or the only version a manager has is never suggested for removal.
- **Docker:**
  - unused images, only when no container (running or stopped) uses them
  - dangling images
  - build cache
  - orphaned volumes, rated low-safety because they can hold data
- **Git worktrees:** stale records are pruned. Clean worktrees whose branch is merged can be removed; the branch is kept.

### sys.health

```sh
bibi sys.health
bibi sys.health --no-log          # skip the system log scan (faster)
```

What it samples:
- `top` for CPU and memory per process
- memory pressure and swap
- `iostat`, plus per-process disk I/O from the kernel's own accounting
- free disk space
- battery condition, capacity and cycles
- thermal throttling
- login and background items (launchd)
- crash, hang and Jetsam reports
- faults in the system log

fm explains each finding, suggests read-only diagnostics (`sample`, `fs_usage`, `powermetrics`, `log show`...), and links findings into hypotheses, for example "kernel_task busy + CPU speed limit + battery service → heat". Possible actions: quit one of your own processes, or disable a failing or leftover login item (reversible).

### sec.audit

```sh
bibi sec.audit
bibi sec.audit --online           # also checks pending macOS updates and looks up unknown startup items
```

Every check is deterministic:
- firewall and stealth mode
- FileVault, Gatekeeper and SIP
- automatic security updates
- screen lock, guest account and auto-login
- Remote Login, Screen Sharing, File Sharing and Remote Apple Events
- listening ports, checked against code signatures
- launch agents and daemons: unsigned or ad-hoc programs, hidden or temporary folders, scripts
- cron, system extensions and MDM enrollment

Admin actions: turn on the firewall or stealth mode, and turn off sharing services. All of them can be undone. Settings bibi doesn't change itself open the right System Settings pane.

Without admin rights, `lsof` can't see ports held by root daemons. The `lsof_listen_all` diagnostic shows them, after a password prompt.

### net.identify

```sh
bibi net.identify 00:dd:1f:e2:aa:44
bibi net.identify 10.0.0.42
bibi net.identify printer.local --offline
```

It gathers evidence locally first: the ARP cache, a ping sweep of your /24 if the MAC isn't cached (turn off with `--no-sweep`), reverse DNS, mDNS, NetBIOS, common TCP ports, and web page titles. It then looks up the vendor and runs a web search. fm combines all of it into a best guess with a confidence level and ways to confirm it.

Privacy: the vendor lookup (macvendors.com) receives only the first 3 bytes of the MAC (the manufacturer prefix). The web search (DuckDuckGo) receives the vendor name and generic device hints, never your hostnames or addresses. `--offline` turns both off.

If the ARP table comes back empty, allow your terminal app under **System Settings › Privacy & Security › Local Network**.

## Adding a skill

Create a module under `bibi/skills/<namespace>/`. It is discovered automatically:

```python
# bibi/skills/net/ping.py
from bibi.registry import Context, Skill, SkillResult, skill

@skill("net.ping", help="Check whether a host is up")
class Ping(Skill):
    def add_arguments(self, p):
        p.add_argument("host")

    def run(self, args, ctx: Context) -> SkillResult:
        verdict = ctx.llm.respond(prompt, instructions, schema)  # structured JSON from fm
        return SkillResult(summary="...", actions=[...])         # actions get the "run which?" prompt
```

- `ctx.llm.respond(prompt, instructions, schema)` returns a dict that matches your JSON schema. Keep prompts small: the on-device model's context is only about 4k tokens.
- Return `Action`s (see `bibi/actions.py`). The front end displays them, asks which to run, and calls `execute()`.
- Mark a skill `uses_web=True` if it contacts internet services.

## Layout

```
bin/bibi            shell shim (symlink target)
bibi/cli.py         command-line front end
bibi/registry.py    @skill, Context, SkillResult, discovery
bibi/llm.py         fm client (fm respond --schema)
bibi/actions.py     Action, selection grammar, executor
bibi/ui.py          terminal output and prompts
bibi/skills/        storage/optimize/, net/identify.py, ...
tests/              python3 -m unittest discover -s tests   (or: make test)
```

Skills return data (`SkillResult`, `Action`) and never print directly, so a chat or web front end can reuse them unchanged. `fm serve` already exposes an OpenAI-compatible API for that.

Note: macOS hides the ARP table from apps without **Local Network** access, so looking a device up by MAC may fail. Allow the app that runs bibi under System Settings > Privacy & Security > Local Network, or look the device up by IP.

## Privacy of online lookups

| Source | When | What is sent |
| --- | --- | --- |
| macvendors.com | `net.identify` (unless `--offline`) | the first 3 bytes of the MAC |
| DuckDuckGo | `net.identify`; `sec.audit --online` | vendor or startup-item names and generic hints, never your hostnames or addresses |
| Apple Software Update | `sec.audit --online` | the usual `softwareupdate -l` request |
| endoflife.date, OSV.dev, package registries | planned for `sw.inventory --online` | product names; package names and versions |

Every request is logged in the run's audit history. Parked and planned work is listed in [docs/todo.md](docs/todo.md).
