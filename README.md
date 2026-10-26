# bibi: a local agent on the macOS Foundation Model

`bibi` is a small agent that runs tasks ("skills") on your Mac. It uses Apple's on-device Foundation Model, called directly through the FoundationModels framework. Analysis and reasoning happen on your Mac. Nothing goes to the internet unless a skill is marked `[web]` or you pass `--online`.

You can run a skill directly, or **chat with bibi** in the web UI: ask about anything on your Mac or ask it to do something. bibi proposes the exact steps, and nothing runs until you approve them. bibi keeps statistics on what you ask. When the same request keeps coming back, it offers to save it as a new skill.

```
bibi <command> [arguments]
bibi ui                      # web UI, including Chat
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

For development, `./bin/bibi` builds if needed and runs from the repo. Run the tests with `make test` (`swift run bibi-tests`). `make ci` runs everything a merge to `main` needs: a strict build where any warning in bibi's code is an error, the tests, a release build and an install into a scratch folder that is then run. GitHub Actions runs it on every pull request (`.github/workflows/ci.yml`), and `main` only accepts pull requests whose `ci` check passed. Pushing a tag `v<version>` matching `VERSION` publishes a release with the built binary. The version lives in `VERSION` and `Sources/BibiCore/Version.swift` (a test checks that they match); change both with `make bump V=x.y.z`.

## Commands

Skills are grouped into namespaces: `bibi list` shows all of them, and `bibi storage` shows one group.

| Command | What it does |
| --- | --- |
| `storage.optimize [path]` | Analyzes disk usage and recommends the top N cleanup actions |
| `dev.cleanup` | Finds build folders, Docker leftovers, package caches, unused SDKs and stale git worktrees |
| `sys.health` | Checks CPU, memory, disk I/O, battery, thermal state, login items, crashes and log faults, and links them into likely causes |
| `sec.audit` `[web]` `[admin]` | Audits the firewall, FileVault, Gatekeeper/SIP, updates, sharing services, listening ports, persistence and lock settings |
| `net.identify <mac\|ip\|name>` `[web]` | Identifies a device on your network |
| `ui` | Opens the web UI, including **Chat** |
| `history`, `undo`, `diff` | Lists saved runs, undoes actions, and compares runs over time |
| `skills [candidates\|show\|accept\|dismiss\|disable\|enable <name>]` | The skill tree with statistics, and skills learned in chat |
| `learned.<name> --<param> …` | A skill bibi learned in chat and you accepted |
| `apps [scan\|show <app>\|permissions]` | The apps chat can use, and the macOS permissions they need |

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
- **Safe action registry.** In skills, fm never writes commands. Only actions registered in bibi can run, each with fixed parameters that are validated when it's recommended and again right before it runs. Read-only diagnostic commands come from a fixed catalog too.
- **The chat exception.** In chat, the model may propose a command of its own (see [Chat with bibi](#chat-with-bibi)). bibi's rules check it, show it word for word with its risk class, and run it only if you approve it.
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

The web UI starts a server on `127.0.0.1` and opens your browser with a one-time access token in the URL. It opens on **Chat**. From there you can:
- chat with bibi, or start one of your most-used skills from **Quick run** on the right. It starts the same run as the **Run** page's button, with default options, and opens it.
- launch any skill with all its options from **Run**
- watch its progress live
- expand the evidence behind each finding and run or copy its diagnostic commands
- **Approve** or **Skip** each recommendation, preview it, then run the approved ones (optionally as a dry run)
- browse **History** (with undo) and **Changes** (baseline diffs)

The server only answers requests that carry the token, and refuses any whose Host or Origin isn't the server itself. Everything is served from the binary, with no CDN, so it works offline.

## Chat with bibi

Open **Chat** in the web UI and ask in plain words: "how much free disk space do I have?", "is my firewall on?", "clean my npm cache", "my Mac is slow, check why".

Each turn:

1. **Retrieve.** bibi looks up what is relevant in its graph (see [bibi.db](#bibidb)). A request that isn't in English is translated first, keeping names, addresses and links as written, because examples, facts and embeddings are in English; the model still answers your own words.
   - skills whose keywords match the request, ranked by how often you approved their proposals
   - up to three example requests that worked before, with the steps that answered them. An example shares at least two words with your request, or one word and a tool your words select.
   - facts it remembered from earlier chats
2. **Propose.** The model replies with the steps it wants to run, at most four. A step can be:
   - one of bibi's skills, for a thorough analysis
   - a registry action (Trash a file, reveal it in Finder, open a settings pane, a tool's own cleanup)
   - any other command, as a program and its arguments
3. **Check.** bibi's rules, not the model, decide what each step is and how risky it is (details below).
4. **Approve.** Each step is a card with **Approve** / **Skip** and **Preview**. If you skip a step and say why, bibi adds an "Avoid:" note to that skill's guidance for next time.
5. **Run and answer.** Approved steps run through the same harness as skills, so they are journaled and undoable where possible. Their output becomes evidence, and bibi answers from it. If a skill ran, its own recommendations come back as a new proposal to approve.
6. **Compact.** Only the last four messages stay word for word. Older ones are folded into a running summary, because the on-device model has a context of about 4k tokens. Facts confirmed in the conversation are stored, but only if their words and numbers appear in what was said or seen. A request is not evidence: asking for an email doesn't make "an email was sent" a fact.

How commands from chat are checked:
- **One program with its arguments, never a shell.**
  - `sh -c`, pipes, redirections, `;`, `&&` and `$(…)` are refused.
  - Interpreters (`python3`, `node`…) may only print their version.
  - AppleScript `do shell script` is refused.
- **Each command gets a class:**
  - **read-only**: an allow-list of programs and subcommands, such as `df`, `ps`, `sw_vers`, `defaults read`, `launchctl print`, `brew list`, `git status`
  - **network**: `curl`, `ping`, `dig`…
  - **writes**: anything else
  - **admin**: the command starts with `sudo`. bibi asks you to confirm, then macOS asks for your password; bibi never sees it.
- **Deletes go to the Trash.** `rm <path>` becomes "move to Trash", which `bibi undo` can reverse. Destructive file commands (`mv`, `cp`, `chmod`…) may not touch protected paths.
- **Checked again at run time.** The check runs a second time just before the command does, so a command stored in a report can't skip it.
- **Only the latest proposal can be approved.** Sending a new message supersedes the open one.

Each chat is saved as a run in History, with the full transcript, every model call, the journal of what ran, and undo. **Details** on a chat opens that run. The chat list can be searched (titles and every message). Deleting a chat removes its transcript and run, but what bibi learned from it (statistics, examples, facts) stays.

### Apps: email, calendar, reminders, calls, messages and more

Ask "email Marie that the repo is ready", "what's on my calendar tomorrow?", "remind me to call the bank at 4pm", "call Marie", "text Paul I'm on my way". bibi proposes the step and nothing happens until you approve it, as for everything else.

Built in (fixed scripts and Apple frameworks, so they behave the same every time):

| Action | Uses | Class | Undo |
| --- | --- | --- | --- |
| `mail_send`, `mail_accounts` | Mail.app, any account configured in it (`from=` picks one) | outbound / read-only | — |
| `calendar_list`, `calendar_add` | EventKit (repeating events included) | read-only / writes | removes the event |
| `reminders_list`, `reminder_add`, `reminder_complete` | EventKit | read-only / writes | removes or reopens it |
| `contacts_find` | Contacts | read-only | — |
| `facetime_call` | FaceTime audio or video, or a phone call through your iPhone (`via=`) | outbound | — |
| `message_send` | Messages (iMessage) | outbound | — |

- **Only people you named.** Every recipient must appear in the conversation: a name or address the model made up is refused.
- **Cards you fill in.** Email, message, call, event and reminder steps are cards with their fields (to, from, subject, message; title, start, calendar…). Fill in or change any field on the card; pick from live choices (the addresses Mail sends from, your calendars, your reminder lists); or say it in chat ("mets plutôt le sujet: …"), which changes only that field on the same card. A field you typed yourself stays yours unless you ask to change it. Problems show under their field (nothing to say yet, a name that matches two people, a link that never came up in the conversation), and Approve only becomes available once there are none. While a card is open, the model sees the card instead of the messages that led to it.
- **The model fixes what it can first.** If a step is refused, or a card has gaps your request already answers (writing the email from "tell him to look at the repo"), the model gets one more try with the reasons. Anything only you know stays on the card for you. If your step is refused and only a step you didn't ask for is left (one an example brought in), that step isn't proposed on its own: the model retries yours.
- **Names become exact addresses before you approve.** "Marie" is looked up in Contacts. The card shows `Marie Dupont <marie@example.com>`, or bibi says the name matches several people (or a person has several addresses) and asks which one.
- **Dates become exact times when proposed.** "tomorrow 3pm" is shown as `2026-10-27 15:00`, so the card says exactly what will be created.
- **Outbound steps show everything.** The card and the confirmation dialog show the recipients and the full text, and say it can't be taken back.

**Other apps are discovered.** bibi reads the scripting dictionary (`.sdef`) of every scriptable app in `/Applications`, `/System/Applications` and `~/Applications` (`bibi apps` lists them; `bibi apps show Notes` shows what one offers). It indexes each command and class in bibi.db, so chat finds them like skills: "add a note called groceries", "play my running playlist", "list my Keynote documents". For those:

- The model fills in a structured call (`app:Notes ["make=note", "name=Groceries"]`). It never writes script text: bibi writes the AppleScript from the app's dictionary, checks each value's type, and passes values as arguments, never as script source.
- bibi's rules give the call a class: read verbs (`get`, `count`, `exists`) are read-only; `make` and most commands write; `delete`, `quit`, `empty`… are destructive; `send`, `reply`, `forward`, `post`, `call`… are outbound.
- Refused: commands that run code or drive the screen (`do shell script`, `do JavaScript`, `keystroke`…), apps that exist to run scripts (Terminal, Script Editor, System Events, Automator), and properties that look like credentials (Mail's account `password`). Raw `osascript … tell application …` from chat is refused too, and so are `mail`/`sendmail`, which can't deliver email on a Mac.
- Something bibi created with `make` can be undone when the app gives it an id (Reminders, Notes…).
- New Outlook ignores the scripting dictionary it still ships, so bibi leaves it out; add your accounts to Mail.app to send from them.

**Permissions.** macOS asks once for each: Calendars, Reminders, Contacts, and Automation for each app bibi controls. Run `bibi apps permissions` to answer the dialogs up front; you can change them later in System Settings > Privacy & Security.

macOS normally charges a permission to the app a program was started from (Terminal, VS Code…), and those apps carry no Contacts or Calendars text, so macOS would refuse without asking. `bibi ui` and `bibi apps` therefore relaunch themselves as their own "responsible process": macOS asks on behalf of **bibi** and remembers the answer for bibi. macOS keeps those answers per code identity. A plain build is ad-hoc signed and gets a new identity each time, so macOS forgets them after every rebuild. Run `make signing-identity` once: it creates a self-signed "bibi local code signing" certificate in your login keychain, and `make build`, `make install` and `bin/bibi` then sign bibi with it, so the permissions stay. Remove it with `security delete-identity -c "bibi local code signing"`.

## How bibi learns skills

bibi records an event for everything that happens in chat: what you asked, what it proposed, and what you approved, skipped, ran or saw fail. These statistics feed back into chat:

- **Ranking.** Skills whose proposals you approve more often rank higher. The rate is the posterior mean (approved + 1) / (decided + 2).
- **Examples.** A request that worked becomes an example for similar requests later. Only the steps your words asked for are kept as its answer: an app action that ran but that the request didn't select is left out.
- **Guidance.** Each skill has guidance text that is part of its prompt. It is versioned. Skipping with a reason adds an "Avoid:" line, up to five, kept newest first. You can also edit it on the **Skills** page.
- **Rollback.** After ten decisions, if the current guidance is approved clearly less often than the previous version, bibi switches back to the previous version and logs it.

**New skills.** A cluster forms when three successful requests:
- have similar wording, and
- ran the same kind of steps (the same tools and programs).

When that happens, bibi drafts a skill:
- Arguments that differ between the requests become parameters. For example, three `du -sh <folder>` requests become `learned.folder-size --path …`.
- The model names the skill.

bibi then asks you in chat whether to keep it. It also appears under **Skills** and in `bibi skills candidates`. Once you accept it, it works everywhere:

```sh
bibi skills candidates
bibi skills accept learned.folder-size
bibi learned.folder-size --path ~/Downloads
bibi skills disable learned.folder-size
```

A learned skill only runs read-only commands by itself, and their output becomes evidence. Anything that changes the Mac comes back as a recommendation to approve. Dismissed candidates are not proposed again until the same request has worked twice as many times.

## bibi.db

`~/Library/Application Support/bibi/bibi.db` (it moves with `BIBI_HOME`) is a single SQLite file. It is a small property graph:

| Kind | What | Linked by |
| --- | --- | --- |
| `skill`, `namespace` | the skill tree: `generic` (chat) → namespaces → skills, built-in and learned | `child_of`, `uses` (actions) |
| `action` | registry actions | |
| `intent` | each request asked in chat (in English; your words are kept too), its steps and outcome, plus starter examples | `contains` (conversation), `matched`, `example`, `used` (the actions and skills that answered it) |
| `prompt`, `prompt_version` | every model instruction, versioned: chat, translation, compaction, skill guidance, built-in skill prompts | `has_version`, `derived_from` |
| `fact` | durable facts confirmed in chats | `from` (conversation) |
| `conversation` | one chat | |

It also holds:
- an append-only `events` table with the statistics
- on-device sentence embeddings (NaturalLanguage) for similarity
- a full-text index

Built-in skills and their prompts are synced into it at startup. The prompts in the code are the defaults: a revised version you or bibi made is kept when the code changes.

To start over, quit bibi and delete `bibi.db`. Your run history is kept separately in `runs/`.

## Skills

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

A skill is a type that conforms to `Skill`. Register it in `Sources/BibiSkills/All.swift`, and bibi syncs it into the graph at startup:

```swift
public struct Ping: Skill {
    public init() {}
    public let name = "net.ping"
    public let help = "Check whether a host is up"
    public let keywords = "ping reachable up down host online"   // helps chat find it
    public var params: [Param] { [.positional("host", help: "name or address")] }

    public func run(_ args: Args, _ ctx: SkillContext) async throws -> SkillResult {
        let ev = Evidence()
        let out = await Command.run(["ping", "-c", "3", args.string("host")!])
        let o = ev.observe(out, out.ok ? "host answered" : "no answer")
        ev.find("net", "Host is down", severity: .medium, cites: [o], confidence: 80, explanation: "...")
        return SkillResult(summary: "...", observations: ev.allObservations, findings: ev.allFindings)
    }
}
```

- `ctx.model.respond(prompt, instructions: ctx.prompts.text("net.ping", default: ...), schema:)` returns structured output. Routing the instructions through `ctx.prompts` makes them tunable in `bibi.db`. Keep prompts small: the on-device model's context is about 4k tokens.
- Recommendations are `BoundAction`s that call a registered `ActionSpec`. The terminal, the web UI and chat all show them, ask for approval, and run them through the `Harness`. To add a new kind of change, add an `ActionSpec` with `validate`, a side-effect-free `plan`, and `execute`, returning an undo call where possible.
- Set `usesWeb` if the skill contacts internet services.

## Layout

```
Sources/BibiCore/     no UI
  Harness.swift       runs skills, previews/executes/undoes actions, saves history
  Actions/            ActionSpec registry, built-in actions, diagnostics, safety policy
  Apps/               app catalog (.sdef discovery), AppleScript writer, mail/calendar/reminders/calls actions
  Chat/               ChatEngine (the generic skill), CommandPolicy, Planner, ContextBuilder
  Graph/              GraphStore (SQLite), PromptBook, GraphSync, Seeds, embeddings
  Learn/              SkillMiner, GraphSkill (learned skills), SkillLibrary
  Model/              LanguageModel, FoundationModel, Explainer
  History/ Report/ Enrich/ System/
Sources/BibiSkills/   storage, dev, sys, sec, net (and sw, parked)
Sources/BibiWeb/      Hummingbird server, JSON API, SSE; Static/ (index.html, app.js, chat.js, style.css)
Sources/bibi/         command-line front end; Info.plist (permission texts, embedded at link time)
Tests/BibiTests/      swift-testing suites (make test)
```

Note: macOS hides the ARP table from apps without **Local Network** access, so looking a device up by MAC may fail. Allow the app that runs bibi under System Settings > Privacy & Security > Local Network, or look the device up by IP.

## Privacy of online lookups

| Source | When | What is sent |
| --- | --- | --- |
| macvendors.com | `net.identify` (unless `--offline`) | the first 3 bytes of the MAC |
| DuckDuckGo | `net.identify`; `sec.audit --online` | vendor or startup-item names and generic hints, never your hostnames or addresses |
| Apple Software Update | `sec.audit --online` | the usual `softwareupdate -l` request |
| endoflife.date, OSV.dev, package registries | planned for `sw.inventory --online` | product names; package names and versions |

Chat never sends anything to the internet by itself. A command you approve can do so: those are labeled **network**. Every request is logged in the run's audit history. Parked and planned work is listed in [docs/todo.md](docs/todo.md).

## License

bibi is licensed under the [PolyForm Noncommercial License 1.0.0](LICENSE): free for non-commercial use. Commercial use requires a separate license from the copyright holder.
