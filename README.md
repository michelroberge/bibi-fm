# bibi: a local agent on the macOS Foundation Model

`bibi` is a small command-line agent that runs tasks ("skills") with the on-device Apple Foundation Model through the `fm` CLI. Analysis and reasoning happen on your Mac. A skill contacts the internet only if it is marked `[web]`.

```
bibi <command> [arguments]
```

> [!WARNING]
> **Experimental software, provided "as is", with no warranty of any kind.** bibi is a personal experiment in local agentic workflows. The model can be wrong, and sometimes confidently wrong. Some skills can delete files or run system commands when you ask them to. Read every recommendation before you approve it, keep backups (Time Machine or similar), and start with `--dry-run`. **Use at your own risk.** The authors accept no liability for data loss or any other damage.

## Requirements

- macOS with Apple Intelligence and the `fm` CLI (`fm available` should print "System model available")
- Python 3.10+ (standard library only; nothing to install)

## Install

```sh
make install          # symlinks bin/bibi into ~/.local/bin (override with PREFIX=/opt/homebrew/bin)
bibi list
```

Or run it in place with `./bin/bibi`.

## Commands

Skills are grouped into namespaces: `bibi list` shows all of them, and `bibi storage` shows one group.

| Command | What it does |
| --- | --- |
| `storage.optimize [path]` | Analyzes disk usage and recommends the top N cleanup actions. You choose which ones to run. |
| `net.identify <mac\|ip\|name>` `[web]` | Identifies a device on your network. |

Options shared by every command:

| Option | Meaning |
| --- | --- |
| `--dry-run` | Shows what would run without changing anything |
| `--select 1,2,5` / `all` / `none` | Answers the "run which?" prompt up front (for scripts) |
| `-v, --verbose` | Prints each model verdict as it comes in |

### storage.optimize

```sh
bibi storage.optimize               # analyze ~, recommend the top 5
bibi storage.optimize ~/dev -n 10   # another folder, top 10
bibi storage.optimize --dry-run -v  # watch the reasoning without risk
```

`optimize-storage` still works as an alias.

How it works:

1. A single `du` pass measures the folder tree.
2. Each entry larger than `--min-size` (default 200M) goes to fm in its own small prompt. fm returns one of three verdicts: *act*, *descend* (look inside) or *skip*, with a safety and a confidence rating.
3. bibi descends into *descend* entries, up to `--depth` levels (default 3).
4. On the way back up, each level merges duplicates and drops overlapping suggestions. It can also ask fm whether several cache folders should become one "clear the parent" action. Each level passes only its best candidates up.
5. You get the top `-n` actions (default 5) and answer `1,2,5`, `all` or `none`.

Safety rules:

- fm never writes shell commands. It picks an action type, and bibi builds the command from a fixed catalog: move to Trash, clear a known cache, `brew`/`npm`/`pip`/`go`/`docker`/`simctl` cleanup, empty the Trash, or review in Finder.
- Permanent deletion is used only on paths a built-in rule recognizes as regenerable (caches, logs, build output, `node_modules`, virtualenvs). Everything else goes to the Trash. You still need to empty the Trash to reclaim the space.
- System folders, app bundles, iCloud, Mail, Messages, Photos, Keychains, device backups and git repositories can only be *reviewed*, whatever the model says.
- Moving an unknown item to the Trash is never rated above 6/10 safety.

Note: macOS only lets the terminal measure Desktop, Documents, Downloads and similar folders if the terminal app has **Full Disk Access**. Without it, those sizes are under-reported.

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
