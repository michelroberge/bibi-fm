# bibi: next steps

As of 2026-10-28. What shipped is in the README; `make eval` and its numbers are in [eval.md](eval.md).

## Chat, in order

- **Retrieval.** A seed that shares one word with the request is lost ("is my firewall on?" vs "is the firewall
  on"), so the model invents (`systemctl`) or copies the fixed examples in the `command` tool line (`ps` for a
  port). Sentence embeddings barely separate short requests (cosine 0.3–0.5 for related and unrelated alike), so
  keywords do the work. Try `NLContextualEmbedding` (multilingual, better on short text) behind `Embedder` and
  BM25 for examples; keep whichever the eval scores higher. Multilingual vectors could also drop the translation
  call for retrieval. Let learned skills grow their keywords from their example requests.
- **Routing.** A tiny call ahead of `ChatTurn` (answer / one step / several steps), so "hello" and "what does
  kernel_task do?" get an answer instead of whatever tool is listed, and multi-step requests go straight to the
  look loop.
- **Seeds for what the eval gets wrong**: firewall and FileVault state, battery (`system_profiler`), last restart
  (`uptime`). The model still adds unrequested steps now and then: watch the approval statistics.
- **Episodic memory.** Store each chat's final summary as a node with a vector, and retrieve the top two into new
  chats as "Earlier chats".
- A terminal chat (`bibi chat`) reusing the approval prompt.
- Chat about a finished run ("explain F3", "undo what you did yesterday") through read-only tools over history and
  reports.

## sw.inventory (software inventory and maintenance)

`Sources/BibiSkills/Sw/Collect.swift`, `Sw/Specs.swift` and the online clients (`PackageManagers`, `EndOfLife`,
`OSV`, `Version.bump`) exist; the skill itself isn't written or registered in `Sources/BibiSkills/All.swift`.

- `Sw/Inventory.swift` skill. Findings:
  - duplicate apps (same bundle id in two places)
  - Intel-only apps on Apple Silicon
  - apps unused for more than `--unused-days` (180): `trash_path` with `app=true` if deletable, otherwise `reveal`
  - several installs of the same runtime on PATH, noting which one wins
  - unused runtimes (reuse `SDKs.unused` and `PinScanner`)
  - deprecated or disabled Homebrew formulae
  - `brew autoremove --dry-run` candidates (add a `brew-autoremove` entry to `Tools`)
- Outdated packages:
  - Offline: Homebrew's `outdated` flag.
  - Online: `PackageManagers`.
  - Rule-based risk: a major bump, many dependents, or projects pinning the runtime's current version all raise it.
  - One fm call proposes an upgrade order; its item ids must be validated.
- Online: endoflife.date for every runtime cycle and for macOS, and OSV for global npm (npm) and pipx (PyPI) packages.
- Facts: apps `{name: version}`, brew `{name: version}`, runtimes set.
- Register the action specs, add fixture tests (brew JSON, npm, pipx, Mach-O headers) and a README section.

## Other

- Check in a real browser: approve, execute, the admin password dialog, undo; in chat, streaming
  replies, dry run, accepting a candidate from the chat card, "Work it out", and "Let bibi look" (no card for
  read-only steps, a card for a write, every auto-run command in the run's journal).
- Remove the Python implementation (`bibi/`, `tests/test_bibi.py`) after a final side-by-side run. The Swift port
  has parity.
- Tests for `sec.audit` parsers: `SecParse.firewall`, `lsof -F` and `persistenceFlags` with fixtures.
- `net.identify` by MAC: macOS hides the ARP table from processes without Local Network permission (sysctl returns
  0 bytes). Look into a signed or bundled helper, or document how to grant the permission.
