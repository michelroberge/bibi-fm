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

## After notes and the look loop, 2026-10-28 (commit b9a3b3f and the fixes after it)

The non-look cases are unchanged (same proposals, same failures: those are retrieval and routing, slice 4 in
`docs/todo.md`). The five multi-step cases now run with "Let bibi look":

| case | before (proposal only) | first loop | after per-program cap and 1–2 extraction calls |
| --- | --- | --- | --- |
| which folder under ~ takes the most space? | no answer | 8 calls, 72 s, "79G /Users/michelroberge" | 6 calls, 61 s (60 s is `du -sh ~` itself), same answer |
| is anything listening on port 8080? | no answer | 18 calls, 52 s, `ps` five times | 6 calls, 17 s, still `ps`, never `lsof` |
| how many files in Downloads, how big? | no answer | 5 calls, 10 s, "total 0" | 5 calls, 12 s, "total 0" (no Full Disk Access for the eval process) |
| which process uses the most memory? | no answer | 14 calls, 46 s, "MTLCompilerService using 49026 KB" | 6 calls, 14 s, "2374 6.6 1100416" (a real `ps` line, no name) |
| do I have Node, which version? | no answer | 4 calls, 7 s, "v25.8.0" | 5 calls, 10 s, "v25.8.0" |

What the loop fixed: a question that needs a result before it can be answered now gets one, from real output, with
no card for read-only steps. What it showed:
- **The model copies the examples it is shown.** The `command` tool line lists `df`, `sw_vers`, `ps`, `du`; it reached
  for `ps` to find a port even when the instructions name `lsof`. Examples retrieved for the request (seeds) would
  steer it better than the fixed list: the retrieval item in `docs/todo.md`.
- **Extraction is where the calls go.** One result used to cost up to three calls; now one, two at most, and the
  answer is as good. Output clipped to a chunk of 1500 characters keeps every call near 1k tokens.
- **A per-program cap is needed.** "Never run again a program whose result is in the notes" is ignored by a 3B model;
  the cap of two runs per program per task did what the instruction couldn't.

## Settings refactor, 2026-10-28 (knobs, prompt catalog, Test bench)

Every constant chat used became a Settings knob with the old value as its built-in, and the remaining hardcoded prompt
text moved into the prompt book with the same text. With no overrides the prompts are byte for byte the same, and so are the proposals: the 22
single-request cases give the same 16 passes and the same 6 failures as the baseline above (17/27 overall). The look
cases vary from run to run on both builds: "do I have Node installed" answered `v25.8.0` once (7 calls) and
`/opt/homebrew/bin/Node` the next time (4 calls, 925 tokens), and the commit before this change (f5790f7) does exactly the same.
