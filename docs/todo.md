# bibi: parked work

Status as of 2026-10-26. The Swift rewrite, the harness, the web UI and chat (with the graph store and skill learning) are done.
Five skills are implemented: `storage.optimize`, `net.identify`, `dev.cleanup`, `sys.health` and `sec.audit`.
The items below are parked.

## sw.inventory (software inventory and maintenance)

Partly written; not registered in `Sources/BibiSkills/All.swift`.

Done:
- `Sources/BibiSkills/Sw/Collect.swift`:
  - apps: Info.plist, Mach-O architecture, last-used date via Spotlight, App Store receipt
  - Homebrew JSON parser, plus a local reverse-dependency map
  - global npm and pipx parsers
  - runtimes on PATH with their install source
- `Sources/BibiSkills/Sw/Specs.swift`: `brew_upgrade`, `brew_uninstall` (leaves only), `npm_global_uninstall`
- Online clients in core: `PackageManagers` (brew, npm, pip, softwareupdate), `EndOfLife`, `OSV`, `Version.bump`

To do:
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

## Other open items

- Remove the Python implementation (`bibi/`, `tests/test_bibi.py`) after a final side-by-side run. The Swift port has parity.
- Tests for `sec.audit` parsers: `SecParse.firewall`, `lsof -F` and `persistenceFlags` with fixtures.
- Check the web UI in a real browser: approve, execute, the admin password dialog, undo, and the Changes page.
- `net.identify` by MAC: macOS hides the ARP table from processes without Local Network permission (sysctl returns 0 bytes). Look into a signed or bundled helper, or document how to grant the permission.

## Chat and learning: next steps

Chat, the graph store (`bibi.db`) and skill learning shipped. Still open:
- Check chat in a real browser: streaming replies, approving an admin step (password dialog), dry run, and accepting a candidate from the chat card.
- Chat with the on-device model is good at single read-only commands and at mapping to registry actions. It is weaker at multi-step plans and sometimes adds unrequested extra steps. Watch the approval statistics on the Skills page and add starter examples (`Sources/BibiCore/Graph/Seeds.swift`) for requests it gets wrong.
- Retrieval uses skill keywords plus NaturalLanguage sentence embeddings. Embeddings barely separate short requests (cosine 0.3–0.5 for related and unrelated alike), so keywords do most of the work. Let learned skills grow their keywords from their example requests.
- Facts from compaction are filtered by grounding, but are still noisy. Consider showing remembered facts on the Skills page so they can be deleted.
- A terminal chat (`bibi chat`) reusing the approval prompt.
- Chat about a finished run ("explain F3", "undo what you did yesterday") through read-only tools over history and reports.
