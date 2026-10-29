"use strict";
// Settings: everything that shapes bibi on this Mac. Each value ships built in; what you change here is an override
// stored in bibi.db, marked as such everywhere, and can be reverted. Loaded before app.js; uses its helpers at call time.

const enc = encodeURIComponent;
const stepsText = (steps) => JSON.stringify(steps || [], null, 1);

function parseJSON(text, what) {
  try { return JSON.parse(text); } catch (e) { throw new Error(`${what} isn't valid JSON: ${e.message}`); }
}

// Runs a change and re-renders with what it returns; a refusal shows in `out`.
function change(out, fn, then) {
  return async () => {
    try {
      const r = await fn();
      if (then) await then(r);
    } catch (e) { out.replaceChildren(failBox(e.message)); }
  };
}

const SECTIONS = [
  ["bench", "Test bench", "See what chat would do with a request, without running anything."],
  ["model", "Model & context", "How much the on-device model is given, and how hard bibi tries."],
  ["prompts", "Prompts", "Every instruction bibi gives the model."],
  ["skills", "Skills", "What chat can run, what it matches them on, and skills it learned."],
  ["examples", "Examples", "Requests and the steps that answered them: the model copies their shape."],
  ["tools", "Tools", "Actions, scriptable apps, and which commands may run."],
  ["memory", "Memory", "Facts bibi remembered from your chats."],
  ["data", "Data", "bibi.db, its events and raw contents, backups, export and import."],
  ["cleanup", "Cleanup", "Put things back to built-in, or forget what bibi learned."],
];

let settingsOverview = null;

async function refreshSettingsBadge() {
  try {
    settingsOverview = await api("settings/overview");
    const b = document.getElementById("settings-badge");
    b.textContent = settingsOverview.candidates;
    b.title = `${settingsOverview.candidates} proposed skill(s) to review`;
    b.hidden = !settingsOverview.candidates;
  } catch (_) { /* no bibi.db: Settings says so */ }
}

// --- shared pieces ----------------------------------------------------------------------------------
// Built-in or overridden, the same everywhere.
function origin(overridden, stale) {
  return [overridden ? pill("Overridden", "accent", { title: "Your value; the built-in one is shown below" }) : h("span", { class: "builtin" }, "Built-in"),
    stale ? pill("Built-in changed", "warn", { title: "bibi's built-in value changed since you overrode it" }) : null];
}

// A line diff of the built-in text against yours (longest common subsequence; prompts are short).
function lineDiff(a, b) {
  const x = a.split("\n"), y = b.split("\n");
  const m = x.length, n = y.length;
  const L = Array.from({ length: m + 1 }, () => new Array(n + 1).fill(0));
  for (let i = m - 1; i >= 0; i--) for (let j = n - 1; j >= 0; j--) L[i][j] = x[i] === y[j] ? L[i + 1][j + 1] + 1 : Math.max(L[i + 1][j], L[i][j + 1]);
  const out = [];
  let i = 0, j = 0;
  while (i < m || j < n) {
    if (i < m && j < n && x[i] === y[j]) { out.push(h("div", {}, "  " + x[i])); i++; j++; }
    else if (j < n && (i >= m || L[i][j + 1] >= L[i + 1][j])) { out.push(h("div", { class: "change-added" }, "+ " + y[j])); j++; }
    else { out.push(h("div", { class: "change-removed" }, "− " + x[i])); i++; }
  }
  return h("pre", { class: "diff" }, out);
}

function overriddenOnly(key, onChange) {
  let on = false;
  try { on = localStorage.getItem("bibi-only-" + key) === "1"; } catch (_) {}
  const box = h("input", { type: "checkbox", checked: on });
  box.addEventListener("change", () => {
    try { localStorage.setItem("bibi-only-" + key, box.checked ? "1" : "0"); } catch (_) {}
    onChange(box.checked);
  });
  return { el: h("label", { class: "check small" }, box, "Show overridden only"), get on() { return box.checked; } };
}

// Runs a Cleanup operation from a section ("Revert all…"), after showing what it touches.
async function cleanupNow(op, out, then, days) {
  const preview = await api(`settings/cleanup/${op}`, { dryRun: true, days });
  if (!preview.count) { out.replaceChildren(h("div", { class: "result ok" }, "Nothing to do: everything is already built-in.")); return; }
  const ok = await confirmDialog(`${preview.count} item(s)`, [
    h("p", {}, "bibi backs up bibi.db first; Settings → Data can restore it."),
    h("ul", { class: "small" }, preview.items.map((i) => h("li", {}, i)), preview.count > preview.items.length ? h("li", { class: "muted" }, `and ${preview.count - preview.items.length} more`) : null),
  ], "Continue", true);
  if (!ok) return;
  const r = await api(`settings/cleanup/${op}`, { days });
  out.replaceChildren(h("div", { class: "result ok" }, `Done: ${r.count} item(s). Backup ${r.backup}.`));
  await refreshSettingsBadge();
  if (then) await then(r);
}

function revertAll(op, label, out, then) {
  return h("button", { class: "small", onclick: () => cleanupNow(op, out, then).catch((e) => out.replaceChildren(failBox(e.message))) }, label);
}

// The model's context window and what a call takes of it (estimated tokens: characters / 4).
function tokenBar(t) {
  const part = (n, cls, label) => h("i", { class: cls, style: `width:${Math.min(100, (n / t.window) * 100)}%`, title: `${label}: ~${n} tokens` });
  return h("div", { class: "tokens" },
    h("div", { class: "tokenbar" }, part(t.instructions, "ti", "Instructions"), part(t.schema, "ts", "Schema"), part(t.prompt, "tp", "Prompt")),
    h("div", { class: "row small muted" }, h("span", { class: "key ti" }, `instructions ~${t.instructions}`), h("span", { class: "key ts" }, `schema ~${t.schema}`),
      h("span", { class: "key tp" }, `prompt ~${t.prompt}`), `≈ ${t.total} of ${t.window} tokens`, t.total > t.window * 0.75 ? pill("little room for the answer", "warn") : null));
}

// --- page --------------------------------------------------------------------------------------------
async function showSettings(id) {
  const [section, ...rest] = (id || "").split("/");
  const sec = SECTIONS.find((s) => s[0] === section) || SECTIONS[0];
  const item = rest.join("/");
  await refreshSettingsBadge();
  if (!settingsOverview) {
    app().replaceChildren(h("h1", {}, "Settings"), errorBox(new Error("Settings needs bibi.db, which could not be opened.")));
    return;
  }
  const o = settingsOverview;
  const counts = { model: o.knobs, prompts: o.prompts, skills: o.skills, examples: o.examples, tools: o.tools + o.policy };
  const content = h("div", { class: "settings-main" });
  app().replaceChildren(
    h("h1", {}, "Settings"),
    h("p", { class: "muted" }, "Everything that shapes bibi on this Mac. Each value ships built in; what you change here is an override, marked ",
      pill("Overridden", "accent"), ", that you can revert at any time."),
    o.total ? h("div", { class: "panel overview row small" }, h("strong", {}, `${o.total} override${o.total === 1 ? "" : "s"}:`),
      [["model", o.knobs, "setting"], ["prompts", o.prompts, "prompt"], ["skills", o.skills, "skill"], ["examples", o.examples, "example"], ["tools", o.tools + o.policy, "tool rule"]]
        .filter(([, n]) => n).map(([s, n, w]) => h("a", { href: "#/settings/" + s }, `${n} ${w}${n === 1 ? "" : "s"}`)),
      o.stalePrompts ? pill(`${o.stalePrompts} prompt(s): built-in changed`, "warn") : null)
      : null,
    h("div", { class: "settings" },
      h("aside", {}, SECTIONS.map(([key, label]) => h("a", { href: "#/settings/" + key, class: key === sec[0] ? "on" : "" },
        h("span", {}, label),
        key === "skills" && o.candidates ? h("span", { class: "badge", title: "proposed skills" }, o.candidates) : null,
        counts[key] ? h("span", { class: "count", title: "overridden" }, counts[key]) : null))),
      content));
  content.replaceChildren(h("h2", {}, sec[1]), h("p", { class: "muted small" }, sec[2]), h("span", { class: "spinner" }));
  const body = await ({ bench: benchSection, model: modelSection, prompts: promptsSection, skills: skillsSection, examples: examplesSection,
    tools: toolsSection, memory: memorySection, data: dataSection, cleanup: cleanupSection }[sec[0]])(item);
  content.replaceChildren(...[body].flat());
}

const rerenderSettings = () => showSettings(location.hash.split("/").slice(2).map(decodeURIComponent).join("/"));

// --- test bench --------------------------------------------------------------------------------------
function benchSection(item) {
  const q = h("textarea", { rows: 2, placeholder: "A request, like: how much free disk space do I have?" });
  q.value = item || "";
  const out = h("div", {});
  const go = (model) => fill(out, async () => {
    if (!q.value.trim()) throw new Error("type a request");
    out.replaceChildren(h("span", { class: "spinner" }), model ? " Asking the on-device model…" : "");
    return benchResult(await api("settings/test", { request: q.value, model }));
  });
  q.addEventListener("keydown", (e) => { if (e.key === "Enter" && (e.metaKey || e.ctrlKey)) go(true); });
  if (item) setTimeout(() => go(false));
  return [h("div", { class: "panel" }, q,
    h("div", { class: "row" }, h("button", { class: "small", onclick: () => go(false) }, "Retrieve only"),
      h("button", { class: "small primary", onclick: () => go(true) }, "Ask the model"),
      h("span", { class: "muted small" }, "Nothing is saved, proposed or run.")),
    h("p", { class: "muted small" }, "Uses the saved prompts and settings: change one, then come back and test again.")), out];
}

function benchResult(r) {
  const list = (label, items, f) => h("div", { class: "row small" }, h("span", { class: "muted" }, label), items.length ? items.map(f) : h("span", { class: "muted" }, "none"));
  return [
    h("div", { class: "panel" },
      h("h3", {}, "Retrieved"),
      r.english ? h("p", { class: "small muted" }, "Translated for retrieval: ", r.english) : null,
      list("Skills:", r.skills, (s) => h("a", { href: "#/settings/skills/" + enc(s) }, pill(s))),
      list("Tools offered:", r.tools, (t) => h("code", {}, t)),
      list("Examples:", r.examples, (e) => h("div", { class: "small mono" }, e))),
    h("div", { class: "panel" },
      h("div", { class: "spread" }, h("h3", {}, "What the model is sent"), h("a", { class: "small", href: "#/settings/model" }, "Budgets →")),
      tokenBar(r.tokens),
      h("table", { class: "small" }, h("tr", {}, h("th", {}, "Section"), h("th", {}, "Chars"), h("th", {}, "Cap"), h("th", {}, "")),
        r.sections.map((s) => h("tr", { class: s.dropped ? "muted" : "" }, h("td", {}, s.title), h("td", {}, s.chars), h("td", {}, s.cap),
          h("td", {}, s.dropped ? pill("dropped to fit", "warn") : s.chars > s.cap ? pill("clipped", "warn") : null)))),
      h("p", { class: "small muted" }, `Prompt budget for this call: ${r.budget} characters.`),
      h("details", {}, h("summary", {}, "Instructions ", h("a", { href: "#/settings/prompts/chat.system", class: "small" }, "edit")), h("pre", {}, r.instructions)),
      h("details", {}, h("summary", {}, "Prompt"), h("pre", {}, r.prompt))),
    r.answer || r.error ? h("div", { class: "panel" },
      h("div", { class: "spread" }, h("h3", {}, "The model's answer"), r.seconds != null ? h("span", { class: "small muted" }, `${r.seconds.toFixed(1)} s`) : null),
      r.error ? failBox(r.error) : h("pre", {}, JSON.stringify(r.answer, null, 2)),
      r.steps ? [h("h3", {}, "After bibi's rules"),
        r.steps.length ? h("ul", {}, r.steps.map((s) => h("li", {}, h("code", {}, s.command || s.title), " ", pill(s.kind),
          s.problems ? h("div", { class: "small problem" }, Object.entries(s.problems).map(([k, v]) => `${k}: ${v}`).join("; ")) : null)))
          : h("p", { class: "small muted" }, "No runnable steps."),
        (r.refusals || []).length ? h("div", {}, h("div", { class: "small muted" }, "Refused:"), h("ul", { class: "small" }, r.refusals.map((x) => h("li", {}, x)))) : null] : null)
      : null,
  ];
}

// --- model & context ---------------------------------------------------------------------------------
async function modelSection() {
  const [knobs, model] = await Promise.all([api("settings/knobs"), api("settings/model")]);
  const out = h("div", {}), list = h("div", {});
  const only = overriddenOnly("model", () => draw());
  const draw = () => {
    const groups = {};
    for (const k of knobs.filter((k) => !only.on || k.overridden)) (groups[k.knob.group] ||= []).push(k);
    list.replaceChildren(...Object.entries(groups).map(([g, ks]) => [h("div", { class: "ns" }, g), h("div", { class: "panel" }, ks.map(knobRow))]).flat(),
      Object.keys(groups).length ? "" : h("p", { class: "muted small" }, "Nothing overridden."));
  };
  const knobRow = (k) => {
    const kn = k.knob;
    const input = h("input", { type: "number", value: k.value, min: kn.min, max: kn.max, step: kn.integer ? 1 : 0.05, style: "width: 110px" });
    const msg = h("span", { class: "small" });
    const save = (value) => change(msg, () => api("settings/knobs", { id: kn.id, value }), (all) => { knobs.splice(0, knobs.length, ...all); draw(); refreshSettingsBadge(); });
    return h("div", { class: "knob" + (k.overridden ? " over" : "") },
      h("div", { class: "spread" }, h("div", { class: "row" }, h("strong", {}, kn.label), origin(k.overridden)),
        h("div", { class: "row" }, input, h("span", { class: "muted small" }, kn.unit),
          h("button", { class: "small", onclick: () => save(Number(input.value))() }, "Save"),
          k.overridden ? h("button", { class: "small", onclick: save(null) }, "Revert") : null)),
      h("div", { class: "small muted" }, kn.help, ` Built-in: ${kn.builtIn}${kn.unit ? " " + kn.unit : ""}; ${kn.min}–${kn.max}.`), msg);
  };
  draw();
  return [
    h("div", { class: "panel" }, h("div", { class: "spread" },
      h("div", {}, h("strong", {}, "On-device model: "), model.unavailable ? h("span", { class: "problem" }, model.unavailable) : pill("available", "ok")),
      h("a", { href: "#/settings/bench", class: "small" }, "Test a request →")),
      h("p", { class: "small muted" }, "Apple's Foundation Model has about 4,096 tokens per call for instructions, prompt, schema and answer. bibi works in characters (about 4 per token).")),
    h("div", { class: "row" }, only.el, revertAll("knobs", "Revert all to built-in", out, rerenderSettings)), out, list,
  ];
}

// --- prompts -----------------------------------------------------------------------------------------
async function promptsSection(item) {
  if (item) return promptDetail(await api("settings/prompts/" + enc(item)));
  const all = await api("settings/prompts");
  const out = h("div", {}), list = h("div", {});
  const q = h("input", { type: "search", placeholder: "Search prompts" });
  const only = overriddenOnly("prompts", () => draw());
  const draw = () => {
    const words = q.value.toLowerCase().split(/\s+/).filter(Boolean);
    const shown = all.filter((p) => (!only.on || p.overridden) && words.every((w) => (p.id + " " + p.title + " " + p.purpose).toLowerCase().includes(w)));
    const groups = {};
    for (const p of shown) (groups[p.group] ||= []).push(p);
    list.replaceChildren(...Object.entries(groups).map(([g, ps]) => [h("div", { class: "ns" }, g),
      h("div", { class: "panel list" }, ps.map((p) => h("a", { class: "item" + (p.overridden ? " over" : ""), href: "#/settings/prompts/" + enc(p.id) },
        h("div", { class: "spread" }, h("div", { class: "row" }, h("strong", {}, p.title), h("code", { class: "muted" }, p.id)), h("div", { class: "row" }, origin(p.overridden, p.stale))),
        h("div", { class: "small muted" }, p.purpose))))]).flat(), shown.length ? "" : h("p", { class: "muted small" }, "No prompt matches."));
  };
  q.addEventListener("input", draw);
  draw();
  return [h("div", { class: "row" }, q, only.el, revertAll("prompts", "Revert all to built-in", out, rerenderSettings)), out, list];
}

function promptDetail(p) {
  const out = h("div", {});
  const text = h("textarea", { rows: Math.min(18, Math.max(4, p.text.split("\n").length + 2)), class: "prompt" });
  text.value = p.text;
  const diffBox = h("div", {});
  const showDiff = () => diffBox.replaceChildren(text.value !== p.builtIn ? lineDiff(p.builtIn, text.value) : h("p", { class: "small muted" }, "Same as the built-in."));
  text.addEventListener("input", () => { if (diffBox.childNodes.length) showDiff(); });
  const reload = (np) => fill(app().querySelector(".settings-main"), () => promptDetail(np));
  const saved = () => api("settings/prompts/" + enc(p.id), { text: text.value });
  const revert = () => api(`settings/prompts/${enc(p.id)}/revert`, {});
  const after = async (np) => { await refreshSettingsBadge(); reload(np); };
  return [
    h("a", { href: "#/settings/prompts", class: "small" }, "← Prompts"),
    h("div", { class: "row" }, h("h2", {}, p.title), h("code", { class: "muted" }, p.id), origin(p.overridden, p.stale)),
    h("p", { class: "muted" }, p.purpose),
    p.stale ? h("div", { class: "panel warnbox" }, h("p", {}, "bibi's built-in text changed since you overrode this prompt. Yours is still the one used."),
      h("div", { class: "row" }, h("button", { class: "small", onclick: () => { diffBox.replaceChildren(lineDiff(p.builtIn, p.text)); } }, "Compare"),
        h("button", { class: "small", onclick: change(out, () => api("settings/prompts/" + enc(p.id), { text: p.text }), after) }, "Keep mine"),
        h("button", { class: "small primary", onclick: change(out, revert, after) }, "Take the new built-in"))) : null,
    h("div", { class: "panel" + (p.overridden ? " over" : "") },
      h("label", { class: "field" }, h("span", {}, p.overridden ? "Your text (used)" : "Text (built-in; editing it creates an override)"), text),
      h("div", { class: "row" },
        h("button", { class: "small primary", onclick: change(out, saved, after) }, "Save"),
        p.overridden ? h("button", { class: "small", onclick: change(out, revert, after) }, "Revert to built-in") : null,
        h("button", { class: "small", onclick: showDiff }, "Compare with built-in")),
      diffBox,
      p.overridden ? h("details", {}, h("summary", { class: "small" }, "Built-in text"), h("pre", {}, p.builtIn || "(empty)")) : null,
      p.fields.length ? h("details", {}, h("summary", { class: "small" }, "Answer fields (the model reads these too; they stay in code)"),
        h("ul", { class: "small mono" }, p.fields.map((f) => h("li", {}, f)))) : null,
      out),
    tryPanel(p, text),
    versionsPanel(p, reload),
  ];
}

function tryPanel(p, text) {
  const out = h("div", {});
  if (p.id === "chat.system" || p.id.startsWith("skill.") || !p.tryable && p.id !== "chat.extract") {
    return h("div", { class: "panel" }, h("h3", {}, "Try it"),
      h("p", { class: "small muted" }, p.id.startsWith("skill.") || p.id === "chat.system" || p.group === "Chat"
        ? "This text is part of every chat turn. Save it, then try a request: " : "This text is put inside another call's prompt, so it can't be tried alone. "),
      h("a", { href: "#/settings/bench" }, "Open the Test bench →"));
  }
  if (p.id === "chat.extract") {
    const purpose = h("input", { type: "text", value: "free disk space" });
    const output = h("textarea", { rows: 6, class: "mono", placeholder: "Paste a command's output" });
    output.value = (p.sample.split("Output:\n")[1] || "");
    return h("div", { class: "panel" }, h("h3", {}, "Try it on real output"),
      h("p", { class: "small muted" }, "Runs bibi's notes step with the saved prompt: short output is kept as is; for long output, only lines that really are in it are kept."),
      h("label", { class: "field" }, h("span", {}, "Purpose"), purpose), h("label", { class: "field" }, h("span", {}, "Output"), output),
      h("button", { class: "small primary", onclick: () => fill(out, async () => {
        out.replaceChildren(h("span", { class: "spinner" }));
        const r = await api(`settings/prompts/${enc(p.id)}/try`, { input: output.value, purpose: purpose.value });
        return h("ul", { class: "mono small" }, r.lines.map((l) => h("li", {}, l)));
      }) }, "Extract"), out);
  }
  const input = h("textarea", { rows: 4, class: "mono" });
  input.value = p.sample;
  return h("div", { class: "panel" }, h("h3", {}, "Try it"),
    h("p", { class: "small muted" }, "Sends the text above (saved or not) with this input to the on-device model. Nothing is recorded."),
    h("label", { class: "field" }, h("span", {}, "Input"), input),
    h("button", { class: "small primary", onclick: () => fill(out, async () => {
      out.replaceChildren(h("span", { class: "spinner" }), " Asking the on-device model…");
      const r = await api(`settings/prompts/${enc(p.id)}/try`, { text: text.value, input: input.value });
      return [tokenBar(r.tokens), h("div", { class: "small muted" }, `${r.seconds.toFixed(1)} s`), r.error ? failBox(r.error) : h("pre", {}, JSON.stringify(r.answer, null, 2))];
    }) }, "Try"), out);
}

function versionsPanel(p, reload) {
  const out = h("div", {});
  if (!p.versions?.length) return h("p", { class: "small muted" }, "Not used yet: no versions.");
  return h("div", { class: "panel" }, h("h3", {}, "Versions"),
    h("p", { class: "small muted" }, "Each save is a version. bibi rolls back automatically when a new version is approved clearly less often than the one before."),
    h("table", { class: "small" }, h("tr", {}, h("th", {}, "#"), h("th", {}, "Why"), h("th", {}, "When"), h("th", {}, "Approved / skipped"), h("th", {}, "")),
      p.versions.map((v) => h("tr", { class: v.active ? "on" : "" }, h("td", {}, v.n),
        h("td", {}, v.reason === "default" ? "built-in" : v.reason, v.status !== "active" ? [" ", pill(v.status, "warn")] : null),
        h("td", {}, when(v.created)),
        h("td", {}, `${v.stats.approved || 0} / ${v.stats.skipped || 0}`, (v.stats.approved || v.stats.skipped) ? [" ", meter(Math.round(v.approvalRate * 100))] : null),
        h("td", {}, v.active ? pill("active", "ok") : h("button", { class: "small", onclick: change(out, () => api(`settings/prompts/${enc(p.id)}/activate`, { version: v.id }), reload) }, "Use this one")),
      ))),
    h("details", {}, h("summary", { class: "small" }, "Texts"), p.versions.map((v) => [h("div", { class: "small muted" }, `#${v.n}`), h("pre", {}, v.text)])),
    out);
}

// --- skills ------------------------------------------------------------------------------------------
const tunePath = (name, rest) => `graph/tune/${enc(name)}${rest ? "/" + rest : ""}`;

async function skillsSection(item) {
  if (item) return skillDetail(await api(tunePath(item)));
  const all = await api("graph/skills");
  const out = h("div", {});
  const tuned = new Set((await api("settings/examples?source=none").catch(() => [])).map(() => ""));
  void tuned;
  const proposed = all.filter((s) => s.status === "candidate");
  const learned = all.filter((s) => s.source === "learned" && s.status !== "candidate");
  const builtin = all.filter((s) => s.source !== "learned");
  const card = (s) => h("a", { class: "card", href: "#/settings/skills/" + enc(s.name) },
    h("div", { class: "row" }, h("strong", {}, s.name), s.source === "learned" ? pill("learned", "accent") : null,
      s.status !== "active" ? pill(s.status === "candidate" ? "proposed" : s.status, s.status === "candidate" ? "warn" : "") : null),
    h("div", { class: "muted small" }, s.help),
    (s.stats?.approved || s.stats?.skipped) ? h("div", { class: "small" }, meter(Math.round(s.approvalRate * 100))) : null);
  const decide = (s, verb) => change(out, () => api(`graph/skills/${enc(s.name)}/${verb}`, {}), async () => { await refreshSettingsBadge(); rerenderSettings(); });
  return [
    h("div", { class: "row" }, h("a", { href: "#/settings/bench" }, "Test which skill a request picks →"),
      revertAll("skillTuning", "Revert all skill tuning", out, rerenderSettings)),
    out,
    proposed.length ? [h("h3", {}, "Proposed"), h("p", { class: "small muted" }, "bibi noticed you asked for these several times, or drafted them from your description."),
      proposed.map((s) => h("div", { class: "panel candidate" },
        h("div", { class: "spread" }, h("a", { href: "#/settings/skills/" + enc(s.name) }, h("strong", {}, s.name)), pill("proposed", "warn")),
        h("p", { class: "small" }, s.help), skillSteps(s),
        h("div", { class: "row" }, h("button", { class: "small primary", onclick: decide(s, "accept") }, "Keep this skill"),
          h("button", { class: "small", onclick: decide(s, "dismiss") }, "Dismiss"))))] : null,
    newSkillPanel(out),
    h("h3", {}, "Learned"),
    learned.length ? h("div", { class: "grid" }, learned.map(card)) : h("p", { class: "small muted" }, "None yet. bibi proposes one when the same request keeps coming back."),
    h("h3", {}, "Built-in"),
    h("div", { class: "grid" }, builtin.map(card)),
  ];
}

function newSkillPanel(out) {
  const describe = h("textarea", { rows: 2, placeholder: "e.g. show free disk space and the 10 biggest files in a folder I name" });
  const name = h("input", { type: "text", placeholder: "check free disk space" });
  const help = h("input", { type: "text", placeholder: "Shows how much space is left on the startup disk" });
  const keywords = h("input", { type: "text", placeholder: "disk space free full storage" });
  const params = h("input", { type: "text", placeholder: "path (comma-separated; use {path} in steps)" });
  const steps = h("textarea", { rows: 4, class: "mono" });
  steps.value = stepsText([{ tool: "command", args: ["df", "-h", "/"], purpose: "free space" }]);
  return h("details", { class: "panel" }, h("summary", {}, h("strong", {}, "New skill")),
    h("div", { class: "cols" },
      h("div", {}, h("h3", {}, "Describe it"),
        h("p", { class: "small muted" }, "bibi drafts the steps with the tools chat has and keeps only steps its rules accept. It appears under Proposed."),
        describe,
        h("button", { class: "small primary", onclick: change(out, async () => {
          if (!describe.value.trim()) throw new Error("describe what the skill should do");
          return api("runs", { skill: "skills.create", argv: [describe.value.trim()] });
        }, (r) => { location.hash = `#/run/${enc(r.id)}`; }) }, "Draft it")),
      h("div", {}, h("h3", {}, "Write it"),
        h("label", { class: "field" }, h("span", {}, "Name"), name),
        h("label", { class: "field" }, h("span", {}, "What it does"), help),
        h("label", { class: "field" }, h("span", {}, "Keywords chat matches"), keywords),
        h("label", { class: "field" }, h("span", {}, "Parameters"), params),
        h("label", { class: "field" }, h("span", {}, "Steps (JSON: tool is command, action:<id>, skill:<name> or app:<App>)"), steps),
        h("button", { class: "small primary", onclick: change(out, () => api("settings/skills", {
          name: name.value, help: help.value, keywords: keywords.value,
          params: params.value.split(",").map((p) => p.trim()).filter(Boolean), steps: parseJSON(steps.value, "Steps"),
        }), (s) => { location.hash = "#/settings/skills/" + enc(s.name); }) }, "Create"))));
}

function skillDetail(v) {
  const s = v.skill;
  const out = h("div", {});
  const rerender = (nv) => fill(app().querySelector(".settings-main"), () => skillDetail(nv));
  const reloadView = async () => rerender(await api(tunePath(s.name)));
  const decide = (verb) => change(out, () => api(`graph/skills/${enc(s.name)}/${verb}`, {}), async () => { await refreshSettingsBadge(); reloadView(); });
  const st = s.stats || {};
  const buttons = {
    candidate: [["accept", "Keep this skill", "primary"], ["dismiss", "Dismiss", ""]],
    active: s.source === "learned" ? [["disable", "Disable", ""]] : s.namespace ? [["disable", "Hide from chat", ""]] : [],
    disabled: [["enable", s.source === "learned" ? "Enable" : "Show in chat", ""]],
    dismissed: [["accept", "Keep it after all", ""]],
  }[s.status] || [];
  return [
    h("a", { href: "#/settings/skills", class: "small" }, "← Skills"),
    h("div", { class: "spread" },
      h("div", { class: "row" }, h("h2", {}, s.name), pill(s.source === "learned" ? "learned" : "built-in", s.source === "learned" ? "accent" : ""),
        s.status !== "active" ? pill(s.status, s.status === "candidate" ? "warn" : "") : null, origin(v.tuned.length > 0)),
      h("div", { class: "row small" }, pill(`proposed ${st.proposed || 0}`), pill(`approved ${st.approved || 0}`, "ok"), pill(`skipped ${st.skipped || 0}`),
        st.failed ? pill(`failed ${st.failed}`, "bad") : null, (st.approved || st.skipped) ? meter(Math.round(s.approvalRate * 100)) : null)),
    h("p", { class: "muted" }, s.help),
    h("div", { class: "row" }, buttons.map(([verb, label, cls]) => h("button", { class: "small " + cls, onclick: decide(verb) }, label)),
      s.source === "learned" ? h("button", { class: "small danger", onclick: change(out, async () => {
        if (!await confirmDialog(`Delete ${s.name}?`, [h("p", {}, "The skill is removed. Its statistics stay; the requests it came from stay as examples.")], "Delete", true)) return false;
        return api("settings/skills/" + enc(s.name), undefined, "DELETE");
      }, (r) => { if (r) location.hash = "#/settings/skills"; }) }, "Delete") : null,
      h("a", { class: "small", href: "#/settings/prompts/" + enc("skill." + s.name) }, "Guidance prompt →")),
    out,
    matchingPanel(v, rerender),
    retrievalPanel(s.name),
    s.source === "learned" ? stepsPanel(v, rerender) : null,
    examplesPanel(v, rerender),
    actionsPanel(v, rerender),
  ];
}

function overrideField(v, key, label, input, rerender, out) {
  const tuned = v.tuned.includes(key);
  const base = key === "text" ? v.defaultText : v.defaultKeywords;
  return h("label", { class: "field" + (tuned ? " over" : "") }, h("span", {}, label, " ", origin(tuned)), input,
    h("div", { class: "row small muted" }, `Built-in: ${base || "(none)"}`,
      tuned ? h("button", { class: "small", type: "button", onclick: change(out, () => api(tunePath(v.skill.name, "override"), { [key]: "" }), rerender) }, "Revert") : null));
}

function matchingPanel(v, rerender) {
  const out = h("div", {});
  const keywords = h("input", { type: "text", value: v.keywords });
  const text = h("textarea", { rows: 3 });
  text.value = v.text;
  return h("div", { class: "panel" },
    h("h3", {}, "What chat matches"),
    h("p", { class: "muted small" }, "A request that shares a word with these is offered this skill; approvals then rank it."),
    overrideField(v, "keywords", "Keywords", keywords, rerender, out),
    overrideField(v, "text", "Description", text, rerender, out),
    h("button", { class: "primary small", onclick: change(out,
      () => api(tunePath(v.skill.name, "override"), { keywords: keywords.value, text: text.value }), async (nv) => { await refreshSettingsBadge(); rerender(nv); }) }, "Save"),
    out);
}

// What a request would retrieve, without asking the model.
function retrievalPanel(highlight) {
  const q = h("input", { type: "search", placeholder: "Would this request pick it? e.g. how much space is left" });
  const out = h("div", { class: "small" });
  const go = () => fill(out, async () => {
    if (!q.value.trim()) return [];
    const r = await api(`graph/preview?q=${enc(q.value)}`);
    const hit = r.skills.includes(highlight);
    return [
      h("div", {}, hit ? pill("picked", "ok") : pill("not picked", "warn"), " ", h("a", { href: "#/settings/bench/" + enc(q.value) }, "Open in the Test bench →")),
      h("div", { class: "row" }, h("span", { class: "muted" }, "Skills:"), r.skills.length ? r.skills.map((n) => pill(n, n === highlight ? "ok" : "")) : h("span", { class: "muted" }, "none")),
      h("div", { class: "row" }, h("span", { class: "muted" }, "Tools offered:"), r.tools.map((t) => h("code", {}, t))),
    ];
  });
  q.addEventListener("keydown", (e) => { if (e.key === "Enter") go(); });
  return h("div", { class: "panel" }, h("h3", {}, "Test it"), h("div", { class: "row" }, q, h("button", { class: "small", onclick: go }, "Retrieve")), out);
}

function examplesPanel(v, rerender) {
  const out = h("div", {});
  const name = v.skill.name;
  const rows = v.examples.map((e) => {
    const text = h("input", { type: "text", value: e.text });
    const weight = h("input", { type: "number", value: e.weight, min: 0, step: 1, style: "width: 80px" });
    const steps = h("textarea", { rows: 3, class: "mono" });
    steps.value = stepsText(e.steps);
    const save = () => {
      const b = { id: e.id };
      if (text.value !== e.text) b.text = text.value;
      if (Number(weight.value) !== e.weight) b.weight = Number(weight.value);
      if (steps.value !== stepsText(e.steps)) b.steps = parseJSON(steps.value, "Steps");
      return api(tunePath(name, "example"), b);
    };
    return h("tr", { class: (e.status === "disabled" ? "muted" : "") + (e.tuned.length ? " over" : "") },
      h("td", {}, text, h("details", {}, h("summary", {}, `Steps (${e.steps.length})`), steps)),
      h("td", {}, pill(e.source === "seed" ? "starter" : e.source, e.source === "manual" ? "accent" : ""), e.source === "seed" ? [" ", origin(e.tuned.length > 0)] : null,
        e.status === "disabled" ? [" ", pill("disabled")] : null),
      h("td", {}, weight),
      h("td", {}, h("div", { class: "row" },
        h("button", { class: "small", onclick: change(out, save, rerender) }, "Save"),
        h("button", { class: "small", onclick: change(out, () => api(tunePath(name, "example"), { id: e.id, status: e.status === "disabled" ? "active" : "disabled" }), rerender) },
          e.status === "disabled" ? "Enable" : "Disable"),
        h("button", { class: "small", onclick: change(out, () => api(tunePath(name, "example"), { id: e.id, remove: true }), rerender) }, "Remove"))));
  });
  const text = h("input", { type: "text", placeholder: "A request this skill should answer" });
  const steps = h("textarea", { rows: 3, class: "mono" });
  steps.value = stepsText([v.skill.namespace ? { tool: "skill:" + name, args: [], purpose: "" } : { tool: "command", args: ["df", "-h", "/"], purpose: "" }]);
  return h("div", { class: "panel" },
    h("h3", {}, "Example requests"),
    h("p", { class: "muted small" }, "Chat shows the model a few examples that share words with a request, and the small model copies their shape. Weight is how often one matched: higher ranks first."),
    rows.length ? h("table", {}, h("thead", {}, h("tr", {}, h("th", {}, "Request"), h("th", {}, "Source"), h("th", {}, "Weight"), h("th", {}, ""))), h("tbody", {}, rows))
      : h("p", { class: "muted small" }, "No examples yet."),
    h("details", {}, h("summary", {}, "Add an example"),
      h("label", { class: "field" }, h("span", {}, "Request"), text),
      h("label", { class: "field" }, h("span", {}, "Steps (JSON)"), steps),
      h("button", { class: "small primary", onclick: change(out, () => api(tunePath(name, "examples"), { text: text.value, steps: parseJSON(steps.value, "Steps") }), rerender) }, "Add")),
    out);
}

function actionsPanel(v, rerender) {
  const out = h("div", {});
  const name = v.skill.name;
  const free = catalog.actions.filter((a) => a.selectable && !v.actions.includes(a.id));
  const pick = h("select", {}, free.map((a) => h("option", { value: a.id }, `${a.id}: ${a.summary}`)));
  return h("div", { class: "panel" },
    h("h3", {}, "Actions"),
    h("p", { class: "muted small" }, "Proposals using a linked action count toward this skill's statistics. Actions its code declares stay linked."),
    h("div", { class: "row" }, v.actions.length ? v.actions.map((a) => v.codeActions.includes(a) ? pill(a) :
      h("span", { class: "pill accent" }, a, " ", h("a", { href: "#", title: "Unlink", onclick: (e) => { e.preventDefault(); change(out, () => api(tunePath(name, "actions"), { action: a, linked: false }), rerender)(); } }, "×")))
      : h("span", { class: "muted small" }, "none")),
    free.length ? h("div", { class: "row" }, pick,
      h("button", { class: "small", onclick: change(out, () => api(tunePath(name, "actions"), { action: pick.value, linked: true }), rerender) }, "Link")) : null,
    out);
}

function stepsPanel(v, rerender) {
  const out = h("div", {});
  const params = h("input", { type: "text", value: (v.skill.params || []).join(", "), placeholder: "path, count" });
  const steps = h("textarea", { rows: 8, class: "mono" });
  steps.value = stepsText(v.skill.steps);
  return h("div", { class: "panel" },
    h("h3", {}, "Steps"),
    h("p", { class: "muted small" }, "What the learned skill runs. Put {name} where a parameter goes. Read-only commands run by themselves; anything else comes back for approval."),
    h("label", { class: "field" }, h("span", {}, "Parameters (comma-separated)"), params),
    h("label", { class: "field" }, h("span", {}, "Steps (JSON)"), steps),
    h("button", { class: "primary small", onclick: change(out, () => api(tunePath(v.skill.name, "steps"),
      { steps: parseJSON(steps.value, "Steps"), params: params.value.split(",").map((p) => p.trim()).filter(Boolean) }), rerender) }, "Save steps"),
    out);
}

// --- examples ----------------------------------------------------------------------------------------
async function examplesSection() {
  const skillsList = await api("graph/skills");
  const out = h("div", {}), list = h("div", {});
  const q = h("input", { type: "search", placeholder: "Search requests" });
  const source = h("select", {}, [["", "Any source"], ["seed", "Starter"], ["manual", "Added by you"], ["learned", "Learned"]].map(([v, l]) => h("option", { value: v }, l)));
  const skill = h("select", {}, h("option", { value: "" }, "Any skill"), skillsList.map((s) => h("option", { value: s.name }, s.name)));
  const only = overriddenOnly("examples", () => load());
  const load = () => fill(list, async () => {
    const all = await api(`settings/examples?q=${enc(q.value)}&source=${enc(source.value)}&skill=${enc(skill.value)}`);
    const shown = all.filter((e) => !only.on || e.overridden);
    if (!shown.length) return h("p", { class: "muted small" }, "No example matches.");
    return h("div", { class: "panel list" }, shown.map(exampleRow));
  });
  const exampleRow = (e) => {
    const msg = h("div", {});
    const text = h("input", { type: "text", value: e.text });
    const steps = h("textarea", { rows: 3, class: "mono" });
    steps.value = stepsText(e.steps);
    const edit = h("details", {}, h("summary", { class: "small" }, "Edit"),
      h("label", { class: "field" }, h("span", {}, "Request"), text),
      h("label", { class: "field" }, h("span", {}, "Steps (JSON)"), steps),
      e.overridden && e.source === "seed" ? h("div", { class: "small muted" }, "Built-in: ", e.builtIn, " → ", h("code", {}, stepsText(e.builtInSteps))) : null,
      h("button", { class: "small primary", onclick: change(msg, () => {
        const b = { id: e.id };
        if (text.value !== e.text) b.text = text.value;
        if (steps.value !== stepsText(e.steps)) b.steps = parseJSON(steps.value, "Steps");
        return api(tunePath(e.skill, "example"), b);
      }, async () => { await refreshSettingsBadge(); load(); }) }, "Save"));
    return h("div", { class: "item" + (e.overridden ? " over" : "") + (e.status === "disabled" ? " muted" : "") },
      h("div", { class: "spread" },
        h("div", {}, h("div", {}, e.text), h("div", { class: "small mono muted" }, e.steps.map((s) => `${s.tool} ${s.args.join(" ")}`).join("; "))),
        h("div", { class: "row" }, pill(e.source === "seed" ? "starter" : e.source === "manual" ? "added" : "learned", e.source === "manual" ? "accent" : ""),
          e.source === "seed" ? origin(e.overridden) : null, e.status === "disabled" ? pill("disabled") : null,
          h("a", { class: "small", href: "#/settings/skills/" + enc(e.skill) }, e.skill))),
      h("div", { class: "row" }, edit,
        h("button", { class: "small", onclick: change(msg, () => api(tunePath(e.skill, "example"), { id: e.id, status: e.status === "disabled" ? "active" : "disabled" }), async () => { await refreshSettingsBadge(); load(); }) },
          e.status === "disabled" ? "Enable" : "Disable"),
        e.overridden && e.source === "seed" ? h("button", { class: "small", onclick: change(msg, () => api(`settings/examples/revert?id=${enc(e.id)}`, {}), async () => { await refreshSettingsBadge(); load(); }) }, "Revert") : null,
        e.source !== "seed" ? h("button", { class: "small", onclick: change(msg, () => api(`settings/examples?id=${enc(e.id)}`, undefined, "DELETE"), load) }, "Delete") : null,
        h("a", { class: "small", href: "#/settings/bench/" + enc(e.text) }, "Test")),
      msg);
  };
  const addText = h("input", { type: "text", placeholder: "A request" });
  const addSkill = h("select", {}, skillsList.filter((s) => s.status === "active").map((s) => h("option", { value: s.name }, s.name)));
  const addSteps = h("textarea", { rows: 3, class: "mono" });
  addSteps.value = stepsText([{ tool: "command", args: ["df", "-h", "/"], purpose: "free space" }]);
  for (const el of [q]) el.addEventListener("keydown", (e) => { if (e.key === "Enter") load(); });
  for (const el of [source, skill]) el.addEventListener("change", load);
  load();
  return [
    h("div", { class: "row" }, q, source, skill, only.el, revertAll("seedExamples", "Revert starter examples", out, rerenderSettings)),
    h("details", { class: "panel" }, h("summary", {}, h("strong", {}, "Add an example")),
      h("label", { class: "field" }, h("span", {}, "Request"), addText),
      h("label", { class: "field" }, h("span", {}, "Skill it belongs to"), addSkill),
      h("label", { class: "field" }, h("span", {}, "Steps (JSON)"), addSteps),
      h("button", { class: "small primary", onclick: change(out, () => api(tunePath(addSkill.value, "examples"), { text: addText.value, steps: parseJSON(addSteps.value, "Steps") }), () => { addText.value = ""; load(); }) }, "Add")),
    out, list,
  ];
}

// --- tools -------------------------------------------------------------------------------------------
async function toolsSection(item) {
  const tab = ["actions", "apps", "commands", "diagnostics"].includes(item) ? item : "actions";
  const tabs = h("div", { class: "row" }, h("span", { class: "seg" }, [["actions", "Actions"], ["apps", "Apps"], ["commands", "Commands"], ["diagnostics", "Diagnostics"]]
    .map(([k, l]) => h("button", { class: k === tab ? "on" : "", onclick: () => { location.hash = "#/settings/tools/" + k; } }, l))));
  return [tabs, await ({ actions: actionsTab, apps: appsTab, commands: commandsTab, diagnostics: diagnosticsTab }[tab])()];
}

async function actionsTab() {
  let all = await api("settings/tools");
  const out = h("div", {}), list = h("div", {});
  const only = overriddenOnly("actions", () => draw());
  const draw = () => list.replaceChildren(h("div", { class: "panel list" }, all.filter((a) => !only.on || !a.enabled).map(actionRow)));
  const actionRow = (a) => {
    const msg = h("div", {});
    const inputs = {};
    const form = a.fields.length ? a.fields.map((f) => h("label", { class: "field" }, h("span", {}, f.label, f.required ? " *" : ""),
      inputs[f.key] = f.options ? h("select", {}, h("option", { value: "" }, ""), f.options.map((o) => h("option", { value: o }, o)))
        : h("input", { type: "text", placeholder: f.placeholder || "" })))
      : [h("label", { class: "field" }, h("span", {}, "Parameters (one key=value per line)"), inputs[""] = h("textarea", { rows: 2, class: "mono", placeholder: a.hint || "" }))];
    const params = () => {
      if (inputs[""]) return Object.fromEntries(inputs[""].value.split("\n").map((l) => l.trim()).filter(Boolean).map((l) => [l.split("=")[0], l.split("=").slice(1).join("=")]));
      return Object.fromEntries(Object.entries(inputs).filter(([, el]) => el.value).map(([k, el]) => [k, el.value]));
    };
    const preview = h("div", {});
    return h("div", { class: "item" + (a.enabled ? "" : " over") },
      h("div", { class: "spread" },
        h("div", {}, h("div", { class: "row" }, h("strong", { class: "mono" }, a.id), pill(a.privilege, a.privilege === "admin" ? "warn" : ""),
          a.reversible ? pill("undoable", "ok") : null, a.enabled ? h("span", { class: "builtin" }, "On") : pill("Turned off", "accent")),
          h("div", { class: "small muted" }, a.summary),
          a.words ? h("div", { class: "small muted" }, "Offered in chat when a request says: ", h("em", {}, a.words)) : null,
          a.skills.length ? h("div", { class: "small muted" }, "Used by ", a.skills.join(", ")) : null),
        h("button", { class: "small", onclick: change(msg, () => api("settings/tools/" + enc(a.id), { enabled: !a.enabled }), async (r) => { all = r; await refreshSettingsBadge(); draw(); }) },
          a.enabled ? "Turn off" : "Turn on")),
      h("details", {}, h("summary", { class: "small" }, "Try it (preview, nothing runs)"), form,
        h("button", { class: "small primary", onclick: () => fill(preview, async () => {
          const p = await api(`settings/tools/${enc(a.id)}/preview`, { params: params() });
          return p.error ? failBox(p.error) : h("ul", { class: "small" }, p.steps.map((s) => h("li", {}, s)));
        }) }, "Preview"), preview),
      msg);
  };
  draw();
  return [h("p", { class: "small muted" }, "Everything chat can propose besides commands, skills and app tools. A turned-off action is never offered or run."),
    h("div", { class: "row" }, only.el, revertAll("tools", "Turn everything back on", out, rerenderSettings)), out, list];
}

async function appsTab() {
  let all = await api("settings/apps");
  const out = h("div", {}), list = h("div", {});
  const q = h("input", { type: "search", placeholder: "Search apps" });
  const draw = () => list.replaceChildren(h("table", {}, h("tr", {}, h("th", {}, "App"), h("th", {}, "Commands"), h("th", {}, "")),
    all.filter((a) => !q.value || a.name.toLowerCase().includes(q.value.toLowerCase())).map((a) => h("tr", { class: a.enabled ? "" : "over" },
      h("td", {}, h("strong", {}, a.name), h("div", { class: "small mono muted" }, a.bundleID)),
      h("td", { class: "small" }, `${a.commands.length} commands, ${a.classes} kinds of items`, h("div", { class: "muted" }, a.commands.slice(0, 8).join(", "), a.commands.length > 8 ? "…" : "")),
      h("td", {}, a.enabled ? null : pill("Turned off", "accent"), " ",
        h("button", { class: "small", onclick: change(out, () => api("settings/apps/" + enc(a.bundleID), { enabled: !a.enabled }), async (r) => { all = r; await refreshSettingsBadge(); draw(); }) },
          a.enabled ? "Turn off" : "Turn on"))))));
  q.addEventListener("input", draw);
  draw();
  return [h("p", { class: "small muted" }, "Scriptable apps bibi found on this Mac. Chat offers an app's tools when a request names the app or matches what it can do."),
    h("div", { class: "row" }, q, h("button", { class: "small", onclick: change(out, () => api("settings/apps/rescan", {}), (r) => { all = r; draw(); }) }, "Rescan apps")), out, list];
}

async function commandsTab() {
  const p = await api("settings/policy");
  const out = h("div", {}), result = h("div", {});
  const test = h("input", { type: "text", placeholder: "Type a command, like: ioreg -l -w0" });
  const check = () => fill(result, async () => {
    const r = await api("settings/policy/test", { command: test.value });
    return h("div", { class: "result " + (r.refusal ? "fail" : "ok") }, h("code", {}, r.argv.join(" ")), " → ",
      r.refusal ? ["refused: ", r.refusal] : r.rewrite.length ? ["becomes ", r.rewrite.join(", ")] : [h("strong", {}, r.cls), r.cls === "read-only" ? " (can run without a card with \"Let bibi look\")" : " (needs your approval)"]);
  });
  test.addEventListener("keydown", (e) => { if (e.key === "Enter") check(); });
  const allow = h("textarea", { rows: 4, class: "mono", placeholder: "one program per line" });
  allow.value = p.allow.join("\n");
  const block = h("textarea", { rows: 4, class: "mono", placeholder: "one program per line" });
  block.value = p.block.join("\n");
  const lines = (t) => t.value.split("\n").map((l) => l.trim()).filter(Boolean);
  return [
    h("div", { class: "panel" }, h("h3", {}, "Test a command"),
      h("p", { class: "small muted" }, "How bibi's rules treat a command the model proposes. Nothing runs."),
      h("div", { class: "row" }, test, h("button", { class: "small primary", onclick: check }, "Check")), result),
    h("div", { class: "panel" + (p.allow.length || p.block.length ? " over" : "") },
      h("div", { class: "row" }, h("h3", {}, "Your rules"), origin(p.allow.length + p.block.length > 0)),
      h("div", { class: "cols" },
        h("label", { class: "field" }, h("span", {}, "Also read-only"), allow,
          h("span", { class: "small muted" }, "Programs that only read. bibi's rules still apply: no shells, interpreters, file-changing or mail commands.")),
        h("label", { class: "field" }, h("span", {}, "Never run"), block, h("span", { class: "small muted" }, "Refused whatever the arguments."))),
      h("div", { class: "row" }, h("button", { class: "small primary", onclick: change(out, () => api("settings/policy", { allow: lines(allow), block: lines(block) }), async () => {
        await refreshSettingsBadge(); out.replaceChildren(h("div", { class: "result ok" }, "Saved."));
      }) }, "Save"), revertAll("policy", "Clear both lists", out, rerenderSettings)), out),
    h("details", { class: "panel" }, h("summary", {}, h("strong", {}, "bibi's built-in rules"), h("span", { class: "builtin" }, " (fixed)")),
      Object.entries(p.rules).map(([k, v]) => h("div", { class: "small" }, h("div", { class: "ns" }, k), h("div", { class: "mono" }, v.join(" "))))),
  ];
}

async function diagnosticsTab() {
  const all = await api("settings/diagnostics");
  return [h("p", { class: "small muted" }, "Read-only checks the model may suggest to confirm a finding. They are part of bibi's code."),
    h("table", { class: "small" }, h("tr", {}, h("th", {}, "Id"), h("th", {}, "What"), h("th", {}, "Command"), h("th", {}, "")),
      all.map((d) => h("tr", {}, h("td", { class: "mono" }, d.id), h("td", {}, d.title), h("td", { class: "mono" }, d.argv.join(" ")),
        h("td", {}, d.admin ? pill("admin", "warn") : null, " ", `${d.timeout}s`))))];
}

// --- memory ------------------------------------------------------------------------------------------
async function memorySection() {
  const out = h("div", {}), list = h("div", {});
  const q = h("input", { type: "search", placeholder: "Search facts" });
  const load = () => fill(list, async () => {
    const facts = await api("settings/facts?q=" + enc(q.value));
    if (!facts.length) return h("p", { class: "muted small" }, q.value ? "Nothing found." : "bibi hasn't remembered anything yet.");
    return h("div", { class: "panel list" }, facts.map((f) => {
      const subject = h("input", { type: "text", value: f.subject });
      const statement = h("input", { type: "text", value: f.statement });
      const msg = h("div", {});
      return h("div", { class: "item" },
        h("div", { class: "spread" }, h("div", {}, h("strong", {}, f.subject), h("div", {}, f.statement)),
          h("div", { class: "row small muted" }, when(f.updated), f.conversation ? h("a", { href: "#/chat/" + enc(f.conversation) }, "chat") : null,
            h("button", { class: "small", onclick: change(msg, () => api("settings/facts?id=" + enc(f.id), undefined, "DELETE"), load) }, "Forget"))),
        h("details", {}, h("summary", { class: "small" }, "Edit"), h("div", { class: "row" }, subject, statement,
          h("button", { class: "small primary", onclick: change(msg, () => api("settings/facts", { id: f.id, subject: subject.value, statement: statement.value }), load) }, "Save"))),
        msg);
    }));
  });
  q.addEventListener("keydown", (e) => { if (e.key === "Enter") load(); });
  const subject = h("input", { type: "text", placeholder: "Subject, like: backup disk" });
  const statement = h("input", { type: "text", placeholder: "Statement, like: Time Machine backs up to the disk named Vault" });
  load();
  return [
    h("p", { class: "small muted" }, "Chat shows the model the facts that relate to a request. Wrong facts mislead it: forget them here."),
    h("div", { class: "row" }, q, h("button", { class: "small", onclick: load }, "Search"), revertAll("facts", "Forget all", out, load)),
    h("details", { class: "panel" }, h("summary", {}, h("strong", {}, "Add a fact")), h("div", { class: "row" }, subject, statement,
      h("button", { class: "small primary", onclick: change(out, () => api("settings/facts", { subject: subject.value, statement: statement.value }), () => { subject.value = statement.value = ""; load(); }) }, "Add"))),
    out, list,
  ];
}

// --- data --------------------------------------------------------------------------------------------
async function dataSection() {
  const [d, backups] = await Promise.all([api("settings/data"), api("settings/backups")]);
  const out = h("div", {});
  const download = (learned) => change(out, async () => {
    const data = await api("settings/export" + (learned ? "?learned=1" : ""));
    const a = h("a", { href: URL.createObjectURL(new Blob([JSON.stringify(data, null, 1)], { type: "application/json" })), download: `bibi-settings${learned ? "-and-learned" : ""}.json` });
    document.body.append(a);
    a.click();
    a.remove();
  });
  const file = h("input", { type: "file", accept: "application/json,.json" });
  file.addEventListener("change", change(out, async () => {
    const f = file.files[0];
    if (!f) return;
    const r = await api("settings/import", parseJSON(await f.text(), "The file"));
    const rep = r.report;
    out.replaceChildren(h("div", { class: "result ok" }, `Imported ${rep.knobs} settings, ${rep.prompts} prompts, ${rep.tuned} tunings, ${rep.lists} lists, ${rep.disabled} turned off, ${rep.nodes} skills/examples/facts. Backup ${r.backup}.`,
      rep.skipped.length ? h("div", { class: "small" }, "Skipped: " + rep.skipped.join(", ")) : null));
    await refreshSettingsBadge();
  }));
  const restore = (b) => change(out, async () => {
    if (!await confirmDialog(`Restore ${b.name}?`, [h("p", {}, "bibi.db is replaced with this backup. The current one is backed up first.")], "Restore", true)) return;
    const r = await api("settings/backups/restore", { name: b.name });
    out.replaceChildren(h("div", { class: "result ok" }, `Restored. The previous database is in ${r.name}.`));
    await refreshSettingsBadge();
  });
  const kinds = Object.entries(d.kinds).sort((a, b) => b[1] - a[1]);
  return [
    h("div", { class: "panel" },
      h("div", { class: "spread" }, h("div", {}, h("strong", {}, "bibi.db"), " ", h("span", { class: "small mono muted" }, d.path)), h("span", {}, human(d.bytes))),
      h("div", { class: "row small" }, kinds.map(([k, n]) => pill(`${n} ${k}`)), pill(`${d.events} events`), pill(`${d.settings} setting overrides`)),
      h("div", { class: "small muted" }, `${d.chats} chats and ${d.runs} skill runs are saved next to it (see History).`)),
    h("div", { class: "panel" }, h("h3", {}, "Export and import"),
      h("p", { class: "small muted" }, "An export holds your overrides only (settings, prompts, tuning, turned-off tools, command rules): bring your fine-tuning to another Mac. Built-in values are never exported."),
      h("div", { class: "row" }, h("button", { class: "small", onclick: download(false) }, "Export overrides"),
        h("button", { class: "small", onclick: download(true) }, "Export overrides + learned skills, examples and facts"),
        h("label", { class: "small" }, "Import: ", file))),
    h("div", { class: "panel" }, h("div", { class: "spread" }, h("h3", {}, "Backups"),
      h("div", { class: "row" }, h("button", { class: "small primary", onclick: change(out, () => api("settings/backups", {}), () => rerenderSettings()) }, "Back up now"),
        h("button", { class: "small", onclick: change(out, () => api("settings/backups/reveal", {})) }, "Show in Finder"))),
      h("p", { class: "small muted" }, "Cleanup, import and restore always back up first."),
      backups.length ? h("table", { class: "small" }, backups.map((b) => h("tr", {}, h("td", { class: "mono" }, b.name), h("td", {}, when(b.created)), h("td", {}, human(b.bytes)),
        h("td", {}, h("button", { class: "small", onclick: restore(b) }, "Restore"))))) : h("p", { class: "small muted" }, "No backups yet.")),
    out,
    eventsPanel(),
    await rawPanel(),
  ];
}

function eventsPanel() {
  const kind = h("input", { type: "text", placeholder: "kind, like approved" });
  const node = h("input", { type: "text", placeholder: "node id, like skill:sys.health" });
  const list = h("div", {});
  const load = () => fill(list, async () => {
    const ev = await api(`settings/events?kind=${enc(kind.value)}&node=${enc(node.value)}`);
    if (!ev.length) return h("p", { class: "small muted" }, "No events.");
    return h("table", { class: "small" }, ev.map((e) => h("tr", {}, h("td", {}, when(e.time)), h("td", {}, pill(e.kind)), h("td", { class: "mono" }, e.node),
      h("td", { class: "muted" }, e.payload != null ? JSON.stringify(e.payload).slice(0, 80) : ""))));
  });
  for (const el of [kind, node]) el.addEventListener("keydown", (e) => { if (e.key === "Enter") load(); });
  return h("details", { class: "panel" }, h("summary", {}, h("strong", {}, "Events"), h("span", { class: "small muted" }, " what was asked, proposed, approved, skipped, tuned")),
    h("div", { class: "row" }, kind, node, h("button", { class: "small", onclick: load }, "Show")), list);
}

// Every node and edge in bibi.db (the raw view).
async function rawPanel() {
  const kinds = await api("graph/kinds");
  const kind = h("select", {}, h("option", { value: "" }, "Any kind"), Object.keys(kinds).sort().map((k) => h("option", { value: k }, `${k} (${kinds[k]})`)));
  const q = h("input", { type: "search", placeholder: "Search names and text" });
  const list = h("div", {}), detail = h("div", {});
  const load = () => fill(list, async () => {
    if (!kind.value && !q.value) return h("p", { class: "muted small" }, "Pick a kind or search.");
    const nodes = await api(`graph/nodes?kind=${enc(kind.value)}&q=${enc(q.value)}`);
    if (!nodes.length) return h("p", { class: "muted small" }, "Nothing found.");
    return h("table", { class: "small" }, h("tr", {}, h("th", {}, "Id"), h("th", {}, "Name"), h("th", {}, "Status")),
      nodes.map((n) => h("tr", { class: "click", onclick: () => openNode(n.id) }, h("td", { class: "mono" }, n.id), h("td", {}, n.name), h("td", {}, n.status))));
  });
  const openNode = (id) => fill(detail, async () => nodePanel(await api(`graph/node?id=${enc(id)}`), openNode, load));
  kind.addEventListener("change", load);
  q.addEventListener("keydown", (e) => { if (e.key === "Enter") load(); });
  return h("details", { class: "panel" }, h("summary", {}, h("strong", {}, "Raw contents"), h("span", { class: "small muted" }, " every node and edge, for when nothing else fits")),
    h("p", { class: "small muted" }, "Built-in skills, starter examples, actions and namespaces are rebuilt from bibi's code, so only their status can change here."),
    h("div", { class: "row" }, kind, q, h("button", { class: "small", onclick: load }, "Search")), detail, list);
}

function nodePanel(v, openNode, reload) {
  const n = v.node, out = h("div", {});
  const name = h("input", { type: "text", value: n.name, disabled: !!v.locked });
  const text = h("textarea", { rows: 4, disabled: !!v.locked && n.kind !== "prompt" });
  text.value = n.text;
  const status = h("select", {}, ["active", "candidate", "dismissed", "disabled", "retired"].map((s) => h("option", { value: s, selected: s === n.status }, s)));
  const props = h("textarea", { rows: 6, class: "mono", disabled: !!v.locked });
  props.value = JSON.stringify(n.props, null, 1);
  const refresh = () => { openNode(n.id); reload(); };
  const save = change(out, () => api("graph/node", v.locked
    ? { id: n.id, status: status.value, ...(n.kind === "prompt" && text.value !== n.text ? { text: text.value } : {}) }
    : { id: n.id, name: name.value, text: text.value, status: status.value, props: parseJSON(props.value, "Props") }), refresh);
  const remove = change(out, async () => {
    if (!await confirmDialog(`Delete ${n.id}?`, [h("p", {}, "The node and its edges are removed. Its statistics stay.")], "Delete", true)) return null;
    return api(`graph/node?id=${enc(n.id)}`, undefined, "DELETE");
  }, (r) => { if (r) { reload(); out.closest(".panel")?.remove(); } });
  const edgeRow = (e, other) => {
    const w = h("input", { type: "number", value: e.weight, min: 0, step: 1, style: "width: 80px" });
    return h("tr", {},
      h("td", {}, e.kind),
      h("td", {}, h("a", { href: "#", class: "mono small", onclick: (ev) => { ev.preventDefault(); openNode(other); } }, other)),
      h("td", {}, w),
      h("td", {}, h("div", { class: "row" },
        h("button", { class: "small", onclick: change(out, () => api("graph/edge", { src: e.src, dst: e.dst, kind: e.kind, weight: Number(w.value) }), refresh) }, "Save"),
        h("button", { class: "small", onclick: change(out, () => api("graph/edge", { src: e.src, dst: e.dst, kind: e.kind, remove: true }), refresh) }, "Remove"))));
  };
  const edges = (title, list, other) => list.length ? [h("h3", {}, title), h("table", {}, h("tbody", {}, list.map((e) => edgeRow(e, other(e)))))] : null;
  const newKind = h("select", {}, ["child_of", "uses", "contains", "matched", "example", "used", "has_version", "derived_from", "from"].map((k) => h("option", { value: k }, k)));
  const newDst = h("input", { type: "text", placeholder: "target node id" });
  const link = n.kind === "skill" ? h("a", { href: "#/settings/skills/" + enc(n.name), class: "small" }, "Open this skill →")
    : n.kind === "prompt" ? h("a", { href: "#/settings/prompts/" + enc(n.name), class: "small" }, "Open this prompt →") : null;
  return h("div", { class: "panel" },
    h("div", { class: "spread" }, h("div", { class: "row" }, h("h3", { class: "mono" }, n.id), pill(n.kind)), link),
    v.locked ? h("p", { class: "muted small" }, "Locked: ", v.locked, ".") : null,
    h("div", { class: "row small" }, Object.entries(v.stats).map(([k, c]) => pill(`${k} ${c}`))),
    h("label", { class: "field" }, h("span", {}, "Name"), name),
    h("label", { class: "field" }, h("span", {}, n.kind === "prompt" ? "Text (saving adds a version)" : "Text"), text),
    h("label", { class: "field" }, h("span", {}, "Status"), status),
    h("details", {}, h("summary", {}, "Props (JSON)"), props),
    h("div", { class: "row" }, h("button", { class: "primary small", onclick: save }, "Save"),
      v.locked || n.kind === "prompt" ? null : h("button", { class: "small danger", onclick: remove }, "Delete")),
    edges("Edges out", v.out, (e) => e.dst),
    edges("Edges in", v.into, (e) => e.src),
    h("div", { class: "row" }, h("span", { class: "small muted" }, "New edge from this node:"), newKind, newDst,
      h("button", { class: "small", onclick: change(out, () => api("graph/edge", { src: n.id, dst: newDst.value.trim(), kind: newKind.value }), refresh) }, "Add")),
    out);
}

// --- cleanup -----------------------------------------------------------------------------------------
async function cleanupSection() {
  const ops = await api("settings/cleanup");
  const groups = {};
  for (const o of ops) (groups[o.group] ||= []).push(o);
  return [
    h("p", { class: "small muted" }, "Each operation shows how many items it touches. bibi backs up bibi.db before running one; restore it from Data if you change your mind."),
    Object.entries(groups).map(([g, list]) => [h("div", { class: "ns" }, g), h("div", { class: "panel list" }, list.map(cleanupRow))]),
  ];
}

function cleanupRow(o) {
  const out = h("div", {});
  const days = o.takesDays ? h("input", { type: "number", value: 30, min: 0, step: 1, style: "width: 80px" }) : null;
  const count = h("span", {}, pill(String(o.count), o.count ? "accent" : ""));
  const nDays = () => days ? Number(days.value) : undefined;
  if (days) days.addEventListener("change", async () => {
    const r = await api(`settings/cleanup/${o.op}`, { dryRun: true, days: nDays() }).catch(() => null);
    if (r) count.replaceChildren(pill(String(r.count), r.count ? "accent" : ""));
  });
  const run = async () => {
    try {
      const preview = await api(`settings/cleanup/${o.op}`, { dryRun: true, days: nDays() });
      if (!preview.count) { out.replaceChildren(h("div", { class: "result ok" }, "Nothing to do.")); return; }
      let typed = null;
      const body = [h("p", {}, o.detail),
        h("ul", { class: "small" }, preview.items.map((i) => h("li", {}, i)), preview.count > preview.items.length ? h("li", { class: "muted" }, `and ${preview.count - preview.items.length} more`) : null),
        h("p", { class: "small muted" }, "bibi.db is backed up first.")];
      if (o.op === "factory") body.push(h("label", { class: "field" }, h("span", {}, "Type reset to confirm"), typed = h("input", { type: "text" })));
      if (!o.safe && !await confirmDialog(o.title + "?", body, o.title.split(" ")[0], true)) return;
      if (typed && typed.value.trim().toLowerCase() !== "reset") { out.replaceChildren(failBox("Not reset: type reset to confirm.")); return; }
      const r = await api(`settings/cleanup/${o.op}`, { days: nDays() });
      out.replaceChildren(h("div", { class: "result ok" }, `Done: ${r.count} item(s). Backup ${r.backup} `, h("a", { href: "#/settings/data" }, "(restore from Data)"), "."));
      count.replaceChildren(pill("0"));
      await refreshSettingsBadge();
    } catch (e) { out.replaceChildren(failBox(e.message)); }
  };
  return h("div", { class: "item" },
    h("div", { class: "spread" }, h("div", {}, h("strong", {}, o.title), h("div", { class: "small muted" }, o.detail)),
      h("div", { class: "row" }, days ? [h("span", { class: "small muted" }, "older than"), days, h("span", { class: "small muted" }, "days")] : null, count,
        h("button", { class: "small " + (o.op === "factory" ? "danger" : ""), onclick: run }, o.safe ? "Tidy" : o.group === "Back to built-in" ? "Revert" : "Delete"))),
    out);
}
