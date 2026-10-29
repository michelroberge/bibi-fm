# Chat eval

`make eval` (`swift run bibi-eval`) sends the requests in `tests/BibiEval/Cases.swift` to chat with the real
on-device model, in a scratch `BIBI_HOME`, and scores the proposal (or, with look, the answer). It prints one
line per case, the totals, and writes `.build/eval/last.json`. `--filter <text>` keeps the cases whose request or
tags contain it, `--look` turns "Let bibi look" on for every case, `-v` prints replies and notes.

Tokens are estimated (`Text.estimatedTokens`: characters / 4 over instructions, prompt and schema); the framework
doesn't count them. Overflows are the calls the model refused for size, so they calibrate the estimate.

## Baseline, 2026-10-28 (commit 5ed4aed, before notes and the look loop)

| | |
| --- | --- |
| pass | 17 / 27 |
| model calls per case | 1.1 |
| seconds per case | 3.2 |
| overflows | 0 |
| largest call, estimated tokens | 1018 |

What failed, and why it matters:
- **Invented Linux commands.** "is my firewall on?" and "is FileVault turned on?" got `systemctl`, refused by the
  rules. Both have a seed example, but a request shares only one word with it ("firewall"), and retrieval wants
  two, or one plus a tool the words select. Retrieval, not the model, lost these.
- **Thorough tools for quick facts.** Battery and "last restart" went to `sys.health` or a settings pane instead of
  `system_profiler` and `uptime`.
- **Steps where an answer was wanted.** "what does kernel_task do?" and "hello" got steps (`ps`, `dmesg`,
  `net.identify`, `contacts_find`): a small model picks from whatever is listed.
- **Multi-step questions** stop at the proposal: without the look loop, chat can't run a step and continue.
- **Noise in the tool list:** Microsoft Word's "speak text" and "show dialog" capabilities were offered for
  unrelated requests and then refused.

Calls stay far below the 4k-token window (about 1k estimated), so the budget has room; the pressure comes from
command output, which is what the notes address.
