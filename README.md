# bibi: a local agent on the macOS Foundation Model

`bibi` runs tasks ("skills") on your Mac with Apple's on-device Foundation Model. Reasoning stays on your Mac: nothing goes to the internet unless a skill is marked `[web]` or you pass `--online`.

Run a skill from the terminal, or **chat with bibi** in the web UI. bibi proposes exact steps, and nothing runs until you approve them. When the same request keeps coming back, it offers to save it as a new skill.

> [!WARNING]
> **Experimental software, provided "as is", with no warranty.** The model can be confidently wrong, and some skills can delete files, change settings or run commands once you approve them. Read every recommendation, keep backups, and start with `--dry-run`. **Use at your own risk.**

## Requirements and install

- macOS 26+ with Apple Intelligence turned on
- Swift 6.2+ (Command Line Tools are enough)

```sh
make install                 # ~/.local/bin/bibi (override with PREFIX=...)
make signing-identity        # once: keeps macOS permissions across rebuilds
bibi list
bibi ui                      # web UI, opens on Chat
```

Development: `./bin/bibi` builds and runs from the repo. `make test` runs the tests, `make eval` scores chat against the real model ([docs/eval.md](docs/eval.md)), and `make ci` is what a pull request to `main` must pass. `make bump V=x.y.z` changes the version; pushing a matching `v<version>` tag publishes a release.

## Commands

| Command | What it does |
| --- | --- |
| `storage.optimize [path]` | Recommends the top cleanup actions for a folder tree |
| `dev.cleanup` | Finds build folders, Docker leftovers, package caches, unused SDKs and stale worktrees |
| `sys.health` | Checks CPU, memory, disk, battery, thermals, login items, crashes and log faults |
| `sec.audit` `[web]` `[admin]` | Audits firewall, FileVault, Gatekeeper/SIP, updates, sharing, ports and persistence |
| `net.identify <mac\|ip\|name>` `[web]` | Identifies a device on your network |
| `ui` | Web UI: Chat, Run, History, Settings |
| `history`, `undo <run>`, `diff <skill>` | Saved runs, undo, and changes since a baseline |
| `skills [candidates\|accept\|dismiss\|disable\|enable <name>]` | Skills, including ones learned in chat |
| `skills.create <description>` | Drafts a new skill from a description |
| `apps [scan\|show <app>\|permissions]` | Apps chat can use, and their macOS permissions |

`[web]` can contact internet services; `[admin]` has actions that ask for your password. Every skill takes `--dry-run`, `--select 1,2|all|none`, `--online`, `--web` (show in the web UI) and `-v`.

## How it stays safe

- **Evidence first.** Skills collect observations with their exact source; deterministic rules turn them into findings. The model only explains findings, and only claims that cite real observations are kept.
- **Registered actions only.** In skills, the model never writes commands: only actions registered in bibi can run, validated when proposed and again right before they run.
- **Chat commands are checked by rules, not the model.** One program and its arguments, never a shell (pipes, `;`, `sh -c`, `do shell script` are refused). Each gets a class (read-only, network, writes, admin) shown on its card. `rm` becomes a move to the Trash.
- **Undo and audit.** Reversible actions record how to undo them. Each run is saved under `~/Library/Application Support/bibi/runs/` with every model call, network request and action. Admin actions ask for your password each time through `sudo -k` or the macOS dialog; bibi never sees it.

## Chat

Ask in plain words: "how much free disk space do I have?", "my Mac is slow, check why", "email Marie that the repo is ready", "remind me to call the bank at 4pm", "launch GarageBand".

- bibi retrieves the relevant skills, past examples and remembered facts, and the model proposes up to four steps: a skill, a registered action, an app action or a command. Each one is a card you **Approve** or **Skip**.
- The model never sees raw output. Long output is reduced to a few lines copied from it (from the first chunk, and from the last only if the first had nothing), and bibi answers from those notes.
- **Let bibi look** runs read-only steps without a card, for up to three rounds, with each program run at most twice. Anything that changes something still gets a card. **Work it out** plans in plain words when no tool fits.
- **Apps.** Mail, Calendar, Reminders, Contacts, FaceTime and Messages are built in. Other scriptable apps are discovered from their `.sdef`, and bibi writes the AppleScript, not the model. Recipients must be people you named, resolved to exact addresses before you approve. Outbound steps show the full text.

## Learning

bibi stores statistics, skills, prompts, examples and facts in `~/Library/Application Support/bibi/bibi.db` (set `BIBI_HOME` to move it). Skills you approve more often rank higher. Skipping a step with a reason adds an "Avoid:" note to that skill's guidance. Three similar successful requests become a candidate skill (`learned.<name>`) that you can accept.

## Settings

Everything that shapes bibi lives under **Settings** in the web UI. Each value ships built in. What you change is an override, marked **Overridden** next to its built-in value, and **Revert** brings the built-in back.

- **Test bench**: type a request and see what chat would retrieve, the exact prompt and its estimated tokens out of the model's ~4k, the model's answer, and the steps bibi's rules keep. Nothing is saved or run.
- **Model & context**: the context budget and the size of each prompt section, retrieval limits, repairs, look rounds, notes, learning thresholds and timeouts.
- **Prompts**: every instruction bibi gives the model, with version history and approval rates. **Try** sends an edited prompt to the model with a sample input. When bibi's built-in text changes after you overrode it, the prompt says so.
- **Skills** and **Examples**: what chat matches each skill on, the example requests the model copies, learned skills, and new skills (described, or written step by step).
- **Tools**: turn actions or scriptable apps off for chat, preview an action, add programs to the read-only list or block them, and check how a command would be classified. bibi's own rules can't be loosened.
- **Memory**: the facts bibi remembered.
- **Data**: `bibi.db` statistics, events, raw nodes and edges, backups, and export or import of your overrides.
- **Cleanup**: revert overrides, or forget learned skills, examples, facts, statistics, chats or old runs, up to a factory reset. Each operation shows its count first and backs up `bibi.db` before it runs.

## Online lookups

| Source | When | What is sent |
| --- | --- | --- |
| macvendors.com | `net.identify` (unless `--offline`) | the first 3 bytes of the MAC |
| DuckDuckGo | `net.identify`, `sec.audit --online` | vendor or startup-item names, never your hostnames or addresses |
| Apple Software Update | `sec.audit --online` | the usual `softwareupdate -l` request |

Chat sends nothing by itself; commands you approve that can are labeled **network**.

## License

[PolyForm Noncommercial 1.0.0](LICENSE): free for non-commercial use; commercial use needs a separate license.
