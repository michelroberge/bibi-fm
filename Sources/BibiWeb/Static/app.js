"use strict";
// bibi web UI: hash-routed views over the local JSON API. No dependencies, no build step.

// --- token: passed once in ?token=, then kept in sessionStorage --------------------------------
const params = new URLSearchParams(location.search);
if (params.get("token")) {
  try { sessionStorage.setItem("bibi-token", params.get("token")); } catch (_) {}
  window.__token = params.get("token");
  history.replaceState(null, "", "/" + location.hash);
}
function token() {
  try { return window.__token || sessionStorage.getItem("bibi-token") || ""; } catch (_) { return window.__token || ""; }
}

// --- helpers -------------------------------------------------------------------------------------
function h(tag, attrs, ...children) {
  const el = document.createElement(tag);
  for (const [k, v] of Object.entries(attrs || {})) {
    if (v === null || v === undefined || v === false) continue;
    if (k.startsWith("on")) el.addEventListener(k.slice(2), v);
    else if (k === "class") el.className = v;
    else if (k === "html") throw new Error("no raw html");
    else el.setAttribute(k, v === true ? "" : v);
  }
  for (const c of children.flat(Infinity)) {
    if (c === null || c === undefined || c === false) continue;
    el.append(c instanceof Node ? c : document.createTextNode(String(c)));
  }
  return el;
}

async function api(path, body, method) {
  const opts = { method: method || (body !== undefined ? "POST" : "GET"), headers: { "X-Bibi-Token": token() } };
  if (body !== undefined) {
    opts.headers["Content-Type"] = "application/json";
    opts.body = JSON.stringify(body);
  }
  const res = await fetch("/api/" + path, opts);
  const text = await res.text();
  if (!res.ok) {
    let msg = text;
    try { msg = JSON.parse(text).error?.message || text; } catch (_) {}
    if (res.status === 401) msg = "This page needs the link bibi printed (it contains an access token). Run `bibi ui` again.";
    throw new Error(msg || res.statusText);
  }
  return text ? JSON.parse(text) : null;
}

function human(bytes) {
  let n = bytes;
  for (const u of ["B", "KB", "MB", "GB", "TB"]) {
    if (Math.abs(n) < 1024 || u === "TB") return u === "B" || u === "KB" ? `${Math.round(n)} ${u}` : `${n.toFixed(1)} ${u}`;
    n /= 1024;
  }
}
const when = (iso) => iso ? new Date(iso).toLocaleString() : "";
const app = () => document.getElementById("app");
const bar = () => document.getElementById("bar");

function errorBox(e) { return h("div", { class: "panel" }, h("strong", {}, "Something went wrong: "), String(e.message || e)); }
const failBox = (message) => h("div", { class: "result fail" }, message);
const pill = (text, kind, attrs) => h("span", { class: kind ? "pill " + kind : "pill", ...attrs }, text);
const runPath = (id, rest) => `runs/${encodeURIComponent(id)}/${rest}`;

// Fills `out` with what `render` returns, or with the error it throws.
async function fill(out, render) {
  try { out.replaceChildren(...[await render()].flat(Infinity).filter((c) => c != null && c !== false)); } catch (e) { out.replaceChildren(failBox(e.message)); }
}

let catalog = { diagnostics: [], actions: [] };
let skills = [];
let currentStream = null;

function confirmDialog(title, bodyNodes, okLabel, danger) {
  const d = document.getElementById("confirm");
  document.getElementById("confirm-title").textContent = title;
  const body = document.getElementById("confirm-body");
  body.replaceChildren(...bodyNodes);
  const ok = document.getElementById("confirm-ok");
  ok.textContent = okLabel || "Continue";
  ok.className = danger ? "danger" : "primary";
  return new Promise((resolve) => {
    d.addEventListener("close", () => resolve(d.returnValue === "ok"), { once: true });
    d.showModal();
  });
}

document.getElementById("version").addEventListener("click", () => document.getElementById("about").showModal());

// --- router --------------------------------------------------------------------------------------
// #/<view>/<id> -> [highlighted nav item, page]. Chat is the home page; the skill launcher lives at #/run.
// Settings ids have several parts (#/settings/prompts/chat.system), each encoded.
const routes = new Map([
  ["chat", ["chat", (id) => showChat(id)]],
  ["run", ["home", (id) => id ? showRun(id) : showHome()]],
  ["history", ["history", () => showHistory()]],
  ["settings", ["settings", (id) => showSettings(id)]],
]);
// The pages Settings replaced.
const moved = { skills: (id) => "#/settings/skills" + (id ? "/" + id : ""), graph: (id) => id === "advanced" ? "#/settings/data" : "#/settings/skills" + (id ? "/" + id : ""), diff: () => "#/history" };

async function route() {
  if (currentStream) { currentStream.close(); currentStream = null; }
  bar().hidden = true;
  const [, view, ...rest] = (location.hash.slice(1) || "/").split("/");
  const id = rest.map(decodeURIComponent).join("/");
  if (moved[view]) { location.replace(moved[view](rest.join("/"))); return; }
  const [section, page] = routes.get(view) || routes.get("chat");
  for (const a of document.querySelectorAll("nav a")) a.classList.toggle("active", a.dataset.nav === section);
  try {
    await page(id);
  } catch (e) {
    app().replaceChildren(errorBox(e));
  }
  if (section !== "chat") window.scrollTo(0, 0);
}
window.addEventListener("hashchange", route);

// --- home: pick a skill and run it -----------------------------------------------------------
async function showHome() {
  const byNs = {};
  for (const s of skills) (byNs[s.namespace] ||= []).push(s);
  const form = h("div", { class: "panel", id: "runform", hidden: true });
  const cards = [];
  const sections = Object.keys(byNs).sort().map((ns) => h("section", {},
    h("div", { class: "ns" }, ns),
    h("div", { class: "grid" }, byNs[ns].map((s) => {
      const card = h("button", { class: "card", type: "button", onclick: () => {
        cards.forEach((c) => c.classList.remove("selected"));
        card.classList.add("selected");
        renderForm(form, s);
      } },
        h("div", { class: "spread" }, h("h3", {}, s.name),
          h("span", { class: "row" }, s.usesWeb ? pill("web", "accent") : null, s.adminActions ? pill("admin", "warn") : null)),
        h("div", { class: "muted small" }, s.help));
      cards.push(card);
      return card;
    }))));
  app().replaceChildren(
    h("h1", {}, "What should bibi look at?"),
    h("p", { class: "muted" }, "Everything is analyzed on this Mac with the on-device model. Nothing changes until you approve it."),
    ...sections, form);
}

function paramInput(p) {
  if (p.kind === "flag") return h("input", { type: "checkbox" });
  return h("input", { type: p.kind === "int" ? "number" : "text", value: p.defaultValue ?? "",
    placeholder: p.kind === "list" ? "comma-separated" : (p.metavar || "") });
}

function paramField(p, input) {
  const label = h("code", { class: "muted" }, p.flags.at(-1) ?? p.key);
  if (p.kind === "flag") return h("label", { class: "check" }, input, h("span", {}, p.help), label);
  return h("label", { class: "field" }, h("span", {}, p.help, " ", label), input);
}

// The command-line arguments for what the form says; values left at their default are not passed.
function paramArgv(p, input) {
  if (p.kind === "flag") return input.checked ? [p.flags.at(-1)] : [];
  const v = input.value.trim();
  if (!v || v === (p.defaultValue ?? "")) return [];
  const values = p.kind === "list" ? v.split(",").map((x) => x.trim()).filter(Boolean) : [v];
  return values.flatMap((x) => p.flags.length ? [p.flags.at(-1), x] : [x]);
}

function renderForm(form, s) {
  const inputs = s.params.map(paramInput);
  const fields = s.params.map((p, i) => paramField(p, inputs[i]));
  const online = h("input", { type: "checkbox", checked: s.onlineByDefault });
  const verbose = h("input", { type: "checkbox" });
  const err = h("div", { class: "small", style: "color: var(--bad)" });
  const go = h("button", { class: "primary", type: "button", onclick: async () => {
    const argv = s.params.flatMap((p, i) => paramArgv(p, inputs[i]));
    go.disabled = true;
    try {
      const r = await api("runs", { skill: s.name, argv, online: online.checked, verbose: verbose.checked });
      location.hash = "#/run/" + encodeURIComponent(r.id);
    } catch (e) {
      err.textContent = e.message;
      go.disabled = false;
    }
  } }, "Run " + s.name);
  form.hidden = false;
  form.replaceChildren(
    h("h2", { style: "margin-top: 0" }, s.name), h("p", { class: "muted" }, s.help), ...fields,
    h("label", { class: "check" }, online, h("span", {}, "Allow internet lookups"),
      h("span", { class: "muted small" }, s.usesWeb ? "(this command uses them by default)" : "(advisories, versions, vendor docs; off = fully local)")),
    h("label", { class: "check" }, verbose, h("span", {}, "Show model reasoning in the log")),
    h("div", { class: "row" }, go), err);
  form.scrollIntoView({ behavior: "smooth", block: "nearest" });
}

// --- run view ------------------------------------------------------------------------------------
// A Map and prototype-less objects, so a run or action id like "__proto__" can never reach Object.prototype.
const decisions = new Map();  // runId -> { actionId: "approve" | "skip" }
function decisionsFor(id) {
  if (!decisions.has(id)) decisions.set(id, Object.create(null));
  return decisions.get(id);
}

async function showRun(id) {
  const view = await api("runs/" + encodeURIComponent(id));
  const running = !view.report || view.busy || (!view.meta.finished && !view.meta.error);
  const log = h("div", { class: "log" });
  const body = h("div", {});
  app().replaceChildren(
    h("div", { class: "spread" },
      h("div", {}, h("h1", {}, view.meta.skill), h("div", { class: "muted small mono" }, view.meta.args.join(" ") || "(default options)")),
      h("span", { class: "row" }, runStatus(view, running))),
    h("details", { open: !view.report || !!view.busy }, h("summary", {}, "Activity log"), log),
    body);

  let lastSeq = 0;
  const subscribe = () => {
    if (currentStream) currentStream.close();
    const es = new EventSource(`/api/${runPath(id, "events")}?from=${lastSeq}&token=${encodeURIComponent(token())}`);
    currentStream = es;
    es.onmessage = (m) => {
      const e = JSON.parse(m.data);
      lastSeq = e.seq;
      if (e.type !== "done") return appendLog(log, e);
      es.close();
      currentStream = null;
      if (e.phase === "run") showRun(id);
    };
  };

  if (!running) {
    log.append(h("div", { class: "muted" }, "Finished. Live output is only kept while bibi is running; the saved report is below."));
  } else {
    subscribe();
    if (!view.report) { body.replaceChildren(h("p", { class: "muted" }, "Collecting evidence and asking the model. This usually takes a minute.")); return; }
  }
  renderReport(view, body, id, subscribe);
}

function runStatus(view, busy) {
  const state = busy ? h("span", { class: "row muted" }, h("span", { class: "spinner" }), "working")
    : view.meta.error ? pill("failed", "bad") : pill("done", "ok");
  return [state, pill(view.meta.online ? "online" : "offline"), h("span", { class: "muted small" }, when(view.meta.started))];
}

// Consecutive progress lines replace each other; everything else is kept.
function appendLog(log, e) {
  const last = log.lastElementChild;
  if (e.type === "progress" && last?.classList.contains("progress")) last.remove();
  log.append(h("div", { class: e.type }, e.text));
  log.scrollTop = log.scrollHeight;
}

function renderReport(view, body, id, subscribe) {
  const r = view.report;
  if (!r) { body.replaceChildren(h("div", { class: "panel" }, view.meta.error ? "This run failed: " + view.meta.error : "No report.")); return; }
  const ctx = {
    view, id, subscribe,
    dec: decisionsFor(id),
    obsById: Object.fromEntries(r.observations.map((o) => [o.id, o])),
    executed: new Set(view.journal.filter((j) => j.event === "executed").map((j) => j.actionID)),
  };
  body.replaceChildren(
    summaryPanel(r),
    ...diffSection(r.diff),
    ...hypothesesSection(r.hypotheses, ctx.obsById),
    ...findingsSection(r.findings, ctx),
    ...journalSection(ctx),
    auditDetails(view));
  renderBar(view, id, ctx.dec, subscribe);
}

function summaryPanel(r) {
  return h("div", { class: "panel" }, h("pre", { style: "background:none;padding:0;margin:0;font:inherit" }, r.summary.trim()),
    (r.notes || []).map((n) => h("div", { class: "muted small" }, "note: " + n)));
}

const DIFF_PREVIEW = 30;

function diffSection(diff) {
  if (!diff) return [];
  const ch = diff.changes;
  const list = h("div", {}, changeList(ch.slice(0, DIFF_PREVIEW)));
  const more = h("button", { class: "small", onclick: () => { list.replaceChildren(changeList(ch)); more.remove(); } }, `Show all ${ch.length} changes`);
  return [h("h2", {}, `Changes since ${when(diff.baselineDate)}`),
    h("div", { class: "panel" }, ch.length ? list : h("span", { class: "muted" }, "Nothing changed."), ch.length > DIFF_PREVIEW ? more : null)];
}

function hypothesesSection(hypotheses, obsById) {
  if (!hypotheses?.length) return [];
  return [h("h2", {}, "Possible connections"),
    ...hypotheses.map((hy) => h("div", { class: "panel" },
      h("div", { class: "spread" }, h("h3", {}, hy.title), meter(hy.confidence)),
      h("p", {}, hy.explanation),
      h("div", { class: "muted small" }, "Links " + hy.findingIDs.join(", "), " · model hypothesis, check before acting"),
      evidence(hy.observationIDs, obsById)))];
}

const SEVERITY_ORDER = ["high", "medium", "low", "info"];

function findingsSection(findings, ctx) {
  const sorted = [...findings].sort((a, b) => SEVERITY_ORDER.indexOf(a.severity) - SEVERITY_ORDER.indexOf(b.severity));
  return [h("h2", {}, `Findings (${sorted.length})`),
    ...(sorted.length ? sorted.map((f) => findingCard(f, ctx)) : [h("div", { class: "panel muted" }, "Nothing to report.")])];
}

const JOURNAL_DONE = new Set(["executed", "failed", "undone", "undo-failed", "dry-run"]);
const JOURNAL_PILL = { failed: "bad", "undo-failed": "bad", undone: "warn" };

function journalSection({ view, id, subscribe }) {
  const done = view.journal.filter((j) => JOURNAL_DONE.has(j.event));
  if (!done.length) return [];
  return [h("h2", {}, "What was done"), h("div", { class: "panel" },
    h("table", {}, h("tr", {}, h("th", {}, "When"), h("th", {}, "What"), h("th", {}, "Result"), h("th", {}, "From")),
      done.map((j) => h("tr", {}, h("td", { class: "small" }, when(j.time)),
        h("td", {}, j.title || j.call?.spec, " ", pill(j.event, JOURNAL_PILL[j.event])),
        h("td", { class: "small" }, j.error || j.message || ""), h("td", { class: "small muted" }, j.frontend || "")))),
    view.undoable.length ? h("div", { class: "row", style: "margin-top: 12px" },
      h("button", { onclick: () => undo(view, id, subscribe) }, `Undo ${view.undoable.length} action(s)`),
      view.undoNeedsAdmin ? pill("asks for your password", "warn") : null) : null)];
}

function auditDetails(view) {
  const net = view.network;
  return h("details", {}, h("summary", {}, `Audit: ${view.modelCalls} model call(s), ${net.length} network request(s), run ${view.meta.id}`),
    net.length ? h("table", {}, net.map((n) => h("tr", {}, h("td", { class: "small" }, n.method),
      h("td", { class: "small mono" }, n.url), h("td", { class: "small" }, n.error || n.status || ""), h("td", { class: "small muted" }, n.sent || ""))))
      : h("p", { class: "muted small" }, view.meta.online ? "No network requests." : "Offline run: nothing left this Mac."));
}

function changeList(changes) {
  return h("div", {}, changes.map((c) => h("div", { class: "change-" + c.kind }, c.kind === "added" ? "+ " : c.kind === "removed" ? "− " : "~ ", changeText(c))));
}
function show(v) {
  if (v === null || v === undefined) return "nothing";
  if (typeof v === "number") return v >= 1048576 ? human(v) : (Number.isInteger(v) ? String(v) : v.toFixed(1));
  if (typeof v === "boolean") return v ? "yes" : "no";
  return typeof v === "string" ? v : JSON.stringify(v);
}
function changeText(c) {
  const item = c.item ? " " + c.item : "";
  if (c.kind === "added") return `${c.key}:${item} is new${c.to != null ? ` (${show(c.to)})` : ""}`;
  if (c.kind === "removed") return `${c.key}:${item} is gone${c.from != null ? ` (was ${show(c.from)})` : ""}`;
  return `${c.key}:${item} changed from ${show(c.from)} to ${show(c.to)}`;
}

function meter(pct) {
  return h("span", { class: "meter", title: "confidence" }, h("i", {}, h("b", { style: `width:${Math.max(0, Math.min(100, pct))}%` })), `${pct}%`);
}

function evidence(ids, obsById) {
  const items = ids.map((i) => obsById[i]).filter(Boolean);
  if (!items.length) return null;
  return h("details", {}, h("summary", {}, `Evidence (${items.length})`),
    items.map((o) => h("div", { class: "obs" }, h("span", { class: "id" }, o.id),
      o.text.length > 300 ? h("pre", {}, o.text) : h("span", {}, o.text), h("span", { class: "src" }, o.source))));
}

const UNCERTAINTY_PILL = { low: "ok", medium: "warn", high: "bad" };

function findingCard(f, { view, id, dec, obsById, executed }) {
  const diags = f.diagnostics.map((d) => catalog.diagnostics.find((x) => x.id === d)).filter(Boolean);
  return h("div", { class: `panel finding ${f.severity}` },
    h("div", { class: "spread" },
      h("div", { class: "row" }, pill(f.severity, "sev-" + f.severity), h("h3", {}, f.title)),
      h("div", { class: "row" }, meter(f.confidence),
        pill(`${f.uncertainty} uncertainty`, UNCERTAINTY_PILL[f.uncertainty], { title: "how uncertain this finding is" }),
        pill(f.explainedBy === "model" ? "explained by fm" : "rule", null, { title: "who wrote the explanation" }))),
    h("p", {}, f.explanation),
    evidence(f.observationIDs, obsById),
    diags.length ? h("div", { class: "small" }, h("div", { class: "muted" }, "To check:"), diags.map((d) => diagnosticRow(d, f, id))) : null,
    f.recommendations.map((a) => recommendation(a, view, id, dec, executed)));
}

function fillTemplate(d, subject) {
  let ok = true;
  const argv = d.argv.map((a) => a.replace(/\{(\w+)\}/g, (_, k) => (subject[k] ?? (k === "uid" ? "$(id -u)" : (ok = false, `<${k}>`)))));
  return { cmd: (d.admin ? "sudo " : "") + argv.map((a) => /^[\w@%+=:,./-]+$/.test(a) ? a : `'${a.replace(/'/g, "'\\''")}'`).join(" "), runnable: ok };
}

function diagnosticRow(d, f, id) {
  const { cmd, runnable } = fillTemplate(d, f.subject || {});
  const out = h("div", {});
  const run = async (ev) => {
    if (d.admin && !(await confirmDialog("Run with administrator rights?", [h("p", {}, d.title), h("pre", {}, cmd),
      h("p", { class: "muted small" }, "macOS will ask for your password. bibi never sees it.")], "Run"))) return;
    ev.target.disabled = true;
    out.replaceChildren(h("span", { class: "spinner" }));
    await fill(out, async () => (await api(runPath(id, "diagnostic"), { finding: f.id, diagnostic: d.id, confirmAdmin: d.admin }))
      .map((x) => x.ok ? h("pre", {}, x.output || x.message) : failBox(x.message)));
    ev.target.disabled = false;
  };
  return h("div", {},
    h("div", { class: "row" }, h("code", {}, cmd),
      h("button", { class: "small", onclick: () => navigator.clipboard?.writeText(cmd) }, "Copy"),
      runnable ? h("button", { class: "small", onclick: run }, "Run") : null,
      h("span", { class: "muted small" }, d.title)),
    out);
}

const DECISION_CLASS = { approve: "approved", skip: "skipped" };

// Also used by chat.js, which passes its own rerender.
function recommendation(a, view, id, dec, executed, rerender = route) {
  const done = executed.has(a.id);
  const preview = h("div", {});
  const showPreview = () => fill(preview, async () => {
    const p = (await api(runPath(id, "preview"), { actions: [a.id] }))[a.id];
    return p.error ? failBox("Cannot run: " + p.error) : h("ul", { class: "small" }, p.steps.map((s) => h("li", {}, s)));
  });
  return h("div", { class: "rec " + (DECISION_CLASS[dec[a.id]] || "") },
    h("div", { class: "spread" },
      h("div", {}, h("strong", {}, a.title), done ? pill("done", "ok", { style: "margin-left:8px" }) : null),
      done ? null : decisionButtons(a.id, dec, rerender)),
    actionPills(a, view.actionInfo[a.id] || {}),
    h("div", { class: "small" }, a.reason),
    h("div", { class: "row small", style: "margin-top: 4px" }, h("code", { class: "muted" }, a.command),
      h("button", { class: "small", onclick: showPreview }, "Preview")),
    preview);
}

// Approve / Skip; clicking the chosen one again clears it.
function decisionButtons(actionId, dec, rerender) {
  const state = dec[actionId];
  const toggle = (choice) => () => { dec[actionId] = state === choice ? undefined : choice; rerender(); };
  return h("span", { class: "seg" },
    h("button", { class: state === "approve" ? "on" : "", onclick: toggle("approve") }, "Approve"),
    h("button", { class: state === "skip" ? "on skip" : "", onclick: toggle("skip") }, "Skip"));
}

function actionPills(a, info) {
  return h("div", { class: "row small", style: "margin: 4px 0" },
    a.bytes ? pill(human(a.bytes), "accent") : null,
    pill(`safety ${a.safety}/10`),
    pill(`confidence ${a.confidence}/10`),
    info.reversible ? pill("undoable", "ok") : pill("not undoable"),
    info.privilege === "admin" ? pill("password required", "warn") : null);
}

function renderBar(view, id, dec, subscribe) {
  const approved = Object.entries(dec).filter(([, v]) => v === "approve").map(([k]) => k);
  if (!approved.length) { bar().hidden = true; return; }
  const dry = h("input", { type: "checkbox" });
  const runLabel = () => dry.checked ? "Dry run" : "Run approved";
  const run = h("button", { class: "primary", onclick: () => execute(view, id, approved, dry.checked, subscribe) }, runLabel());
  dry.addEventListener("change", () => run.textContent = runLabel());
  bar().hidden = false;
  bar().replaceChildren(
    h("strong", {}, `${approved.length} approved`),
    h("label", { class: "check" }, dry, "Dry run (show what would happen)"),
    h("button", { onclick: () => { for (const k of approved) delete dec[k]; route(); } }, "Clear"),
    run);
}

async function execute(view, id, ids, dryRun, subscribe) {
  const all = view.report.findings.flatMap((f) => f.recommendations);
  const chosen = ids.map((i) => all.find((a) => a.id === i)).filter(Boolean);
  const admin = chosen.filter((a) => view.actionInfo[a.id]?.privilege === "admin");
  const irreversible = chosen.filter((a) => !view.actionInfo[a.id]?.reversible);
  let previews = {};
  try { previews = await api(runPath(id, "preview"), { actions: ids }); } catch (_) {}
  const notes = dryRun ? [] : riskNotes(irreversible.length, admin.length);
  const [title, okLabel] = dryRun ? ["Dry run these actions?", "Dry run"] : ["Run these actions?", "Run"];
  if (!(await confirmDialog(title, [previewList(chosen, previews), ...notes], okLabel, !dryRun && irreversible.length > 0))) return;
  bar().hidden = true;
  subscribe();
  try {
    const results = await api(runPath(id, "execute"), { actions: ids, dryRun, confirmAdmin: admin.length > 0 });
    const dec = decisionsFor(id);
    for (const k of ids) delete dec[k];
    await showRun(id);
    app().prepend(resultsPanel(dryRun ? "Dry run" : "Results", results));
  } catch (e) {
    app().prepend(errorBox(e));
  }
}

function previewList(actions, previews) {
  return h("ul", {}, actions.map((a) => {
    const p = previews[a.id];
    return h("li", {}, a.title, p?.error ? h("div", { class: "small", style: "color: var(--bad)" }, "will fail: " + p.error)
      : h("div", { class: "small muted" }, (p?.steps || []).join("; ")));
  }));
}

function riskNotes(irreversible, admin) {
  return [
    irreversible ? h("p", { class: "small" }, `${irreversible} of these cannot be undone.`) : null,
    admin ? h("p", { class: "small" }, h("strong", {}, `${admin} need administrator rights. `),
      "macOS will show its own password dialog for each one; bibi and this page never see your password.") : null,
  ].filter(Boolean);
}

function resultsPanel(title, results) {
  return h("div", { class: "panel" }, h("h3", {}, title),
    results.map((r) => h("div", { class: "result " + (r.ok ? "ok" : "fail") }, h("strong", {}, r.title), " — ", r.message,
      r.output ? h("pre", {}, r.output) : null)));
}

async function undo(view, id, subscribe) {
  const entries = view.journal.filter((j) => j.event === "executed" && view.undoable.includes(j.actionID));
  const ok = await confirmDialog("Undo these actions?", [h("ul", {}, entries.map((e) => h("li", {}, e.title, h("div", { class: "small muted" }, e.message || "")))),
    view.undoNeedsAdmin ? h("p", { class: "small" }, "Some need administrator rights; macOS will ask for your password.") : null].filter(Boolean), "Undo");
  if (!ok) return;
  subscribe();
  try {
    const results = await api(runPath(id, "undo"), { confirmAdmin: view.undoNeedsAdmin });
    await showRun(id);
    app().prepend(resultsPanel("Undo", results));
  } catch (e) { app().prepend(errorBox(e)); }
}

// --- history ---------------------------------------------------------------------------------------
// Searched and paged on the server; the search and page survive opening a run and coming back.
const historyUI = { q: "", offset: 0 };
const HISTORY_PAGE = 25;

async function showHistory() {
  const search = h("input", { type: "search", placeholder: "Search runs: command, arguments, summary…", value: historyUI.q, style: "width:100%;max-width:420px" });
  const out = h("div", {});
  let timer, seq = 0;
  const load = async () => {
    const mine = ++seq;
    const page = await api(`history?q=${encodeURIComponent(historyUI.q)}&offset=${historyUI.offset}&limit=${HISTORY_PAGE}`);
    if (mine !== seq) return; // a newer search already answered
    if (!page.items.length && page.total && historyUI.offset) { historyUI.offset = 0; return load(); } // e.g. runs were deleted
    out.replaceChildren(historyTable(page, load));
  };
  search.addEventListener("input", () => {
    clearTimeout(timer);
    timer = setTimeout(() => { historyUI.q = search.value; historyUI.offset = 0; load().catch((e) => out.replaceChildren(errorBox(e))); }, 250);
  });
  app().replaceChildren(h("h1", {}, "History"),
    h("p", { class: "muted" }, "Every run is saved with its evidence, model calls, the actions you chose and their results."),
    search, out);
  await load();
}

function historyTable(page, reload) {
  if (!page.total) return h("div", { class: "empty" }, historyUI.q ? "No runs match this search." : "No runs yet.");
  const go = (offset) => { historyUI.offset = offset; reload().then(() => window.scrollTo(0, 0)).catch((e) => app().append(errorBox(e))); };
  const first = page.offset + 1, last = page.offset + page.items.length;
  const pager = h("div", { class: "spread", style: "margin-top:10px" },
    h("span", { class: "muted small" }, `${first}–${last} of ${page.total}`),
    h("span", { class: "row" },
      h("button", { class: "small", disabled: page.offset === 0, onclick: () => go(Math.max(0, page.offset - page.limit)) }, "‹ Newer"),
      h("button", { class: "small", disabled: last >= page.total, onclick: () => go(page.offset + page.limit) }, "Older ›")));
  return h("div", { class: "panel" }, h("table", {},
    h("tr", {}, h("th", {}, "When"), h("th", {}, "Command"), h("th", {}, "Result"), h("th", {}, "Options")),
    page.items.map(historyRow)), pager);
}

function historyRow(r) {
  const { meta } = r;
  const result = meta.error ? pill("failed", "bad") : meta.finished ? `${meta.findings ?? 0} findings` : pill("running");
  return h("tr", { class: "click", onclick: () => location.hash = "#/run/" + encodeURIComponent(meta.id) },
    h("td", { class: "small" }, when(meta.started)),
    h("td", {}, meta.skill),
    h("td", { class: "small" }, result, r.undoable ? pill(`${r.undoable} undoable`, "warn", { style: "margin-left:6px" }) : null),
    h("td", { class: "small mono muted" }, meta.args.join(" ")));
}

// --- theme: auto (device setting), light or dark; the choice is kept per browser --------------------
(() => {
  const buttons = document.querySelectorAll("[data-theme-choice]");
  const apply = (choice) => {
    if (choice === "auto") delete document.documentElement.dataset.theme;
    else document.documentElement.dataset.theme = choice;
    try { choice === "auto" ? localStorage.removeItem("bibi-theme") : localStorage.setItem("bibi-theme", choice); } catch {}
    buttons.forEach((b) => { b.classList.toggle("on", b.dataset.themeChoice === choice); b.setAttribute("aria-pressed", b.dataset.themeChoice === choice); });
    document.dispatchEvent(new Event("themechange"));
  };
  buttons.forEach((b) => b.addEventListener("click", () => apply(b.dataset.themeChoice)));
  apply(document.documentElement.dataset.theme || "auto");
})();

// --- logo: a sphere head lit from inside, drawn in 3D on a canvas -----------------------------------
(() => {
  const canvas = document.querySelector(".logo");
  if (!canvas) return;
  const ctx = canvas.getContext("2d");
  const still = matchMedia("(prefers-reduced-motion: reduce)").matches;
  const size = canvas.clientWidth, dpr = devicePixelRatio || 1;
  canvas.width = canvas.height = size * dpr;
  ctx.scale(dpr, dpr);
  const c = size / 2, m = size * 0.57, R = size * 0.31; // centre sits low to leave room for the antenna

  const rgb = (hex) => { const n = parseInt(hex.trim().slice(1), 16); return [n >> 16, (n >> 8) & 255, n & 255]; };
  const mix = ([r, g, b], [r2, g2, b2], k) => `rgb(${r + (r2 - r) * k | 0},${g + (g2 - g) * k | 0},${b + (b2 - b) * k | 0})`;
  const norm = ([x, y, z]) => { const l = Math.hypot(x, y, z); return [x / l, y / l, z / l]; };

  // Head space: x right, y up, z towards the viewer. Orthographic projection.
  const EYES = [norm([-0.4, 0.14, 0.9]), norm([0.4, 0.14, 0.9])];
  let M; // rotation matrix rows, rebuilt each frame from yaw / pitch / roll
  const rotate = ([x, y, z]) => [M[0] * x + M[1] * y + M[2] * z, M[3] * x + M[4] * y + M[5] * z, M[6] * x + M[7] * y + M[8] * z];
  const screen = ([x, y], r = R) => [c + x * r, m - y * r];

  // A circle of angular radius `a` around surface direction `n` (already rotated), lifted to radius `lift`.
  const disc = (n, a, lift = 1) => {
    const [x, y] = screen(n, R * lift * Math.cos(a));
    const r = R * lift * Math.sin(a);
    ctx.beginPath();
    ctx.ellipse(x, y, Math.max(r * Math.abs(n[2]), 0.01), r, Math.atan2(-n[1], n[0]), 0, 2 * Math.PI); // squashed along the tilt
  };

  const draw = (yaw, pitch, roll, light, beacon) => {
    // Positive yaw turns to the viewer's right, positive pitch looks up.
    const [cy, sy, cp, sp, cr, sr] = [Math.cos(yaw), Math.sin(yaw), Math.cos(pitch), -Math.sin(pitch), Math.cos(roll), Math.sin(roll)];
    // R = Rz(roll) · Rx(pitch) · Ry(yaw)
    M = [cr * cy - sr * sp * sy, -sr * cp, cr * sy + sr * sp * cy,
         sr * cy + cr * sp * sy, cr * cp, sr * sy - cr * sp * cy,
         -cp * sy, sp, cp * cy];
    const accent = rgb(getComputedStyle(document.documentElement).getPropertyValue("--accent") || "#5b5bd6");
    const white = [255, 255, 255], black = [0, 0, 0], metal = [150, 150, 165];
    ctx.clearRect(0, 0, size, size);

    // Parts that stick out of the sphere: ear bolts and the antenna. Behind the head -> drawn before it.
    const ears = [[1, 0, 0], [-1, 0, 0]].map(rotate);
    const base = rotate([0, 1, 0]), tip = rotate(norm([0.18, 1, -0.1]));
    const ear = (n) => {
      disc(n, 0.42, 1.0); ctx.fillStyle = mix(metal, black, 0.45); ctx.fill();
      disc(n, 0.3, 1.13); ctx.fillStyle = mix(metal, white, 0.15 + 0.3 * Math.max(0, n[1] - n[0] * 0.5)); ctx.fill();
    };
    const antenna = () => {
      const [bx, by] = screen(base), [tx, ty] = screen(tip, R * 1.45);
      ctx.strokeStyle = mix(metal, black, 0.3); ctx.lineWidth = 1.4; ctx.lineCap = "round";
      ctx.beginPath(); ctx.moveTo(bx, by); ctx.lineTo(tx, ty); ctx.stroke();
      const g = ctx.createRadialGradient(tx, ty, 0, tx, ty, 3.5);
      g.addColorStop(0, `rgba(255,90,90,${0.9 * beacon})`); g.addColorStop(1, "rgba(255,90,90,0)");
      ctx.fillStyle = g; ctx.fillRect(tx - 4, ty - 4, 8, 8);
      ctx.beginPath(); ctx.arc(tx, ty, 1.9, 0, 2 * Math.PI); ctx.fillStyle = mix([150, 40, 40], [255, 120, 110], beacon); ctx.fill();
    };
    ears.filter((n) => n[2] < 0).forEach(ear);
    if (tip[2] < 0) antenna();

    // The sphere itself: fixed key light from the upper left, so plain shading reads as 3D at any pose.
    const g = ctx.createRadialGradient(c - R * 0.4, m - R * 0.45, R * 0.05, c, m, R * 1.05);
    g.addColorStop(0, mix(accent, white, 0.55)); g.addColorStop(0.45, mix(accent, white, 0.05)); g.addColorStop(1, mix(accent, black, 0.55));
    ctx.beginPath(); ctx.arc(c, m, R, 0, 2 * Math.PI); ctx.fillStyle = g; ctx.fill();

    ctx.save();
    ctx.beginPath(); ctx.arc(c, m, R, 0, 2 * Math.PI); ctx.clip();
    // Panel seam below the eyes: the visible half of a latitude ring.
    ctx.strokeStyle = mix(accent, black, 0.5); ctx.lineWidth = 0.8;
    ctx.beginPath();
    for (let i = 0, pen = false; i <= 48; i++) {
      const t = i / 48 * 2 * Math.PI, p = rotate([0.94 * Math.cos(t), -0.34, 0.94 * Math.sin(t)]);
      if (p[2] < 0) { pen = false; continue; }
      const [x, y] = screen(p);
      pen ? ctx.lineTo(x, y) : ctx.moveTo(x, y); pen = true;
    }
    ctx.stroke();
    // Eye holes, with the bulb inside showing through.
    for (const e of EYES.map(rotate)) {
      if (e[2] <= 0) continue;
      disc(e, 0.27); ctx.fillStyle = mix(accent, black, 0.8); ctx.fill();
      disc(e, 0.2);
      const [x, y] = screen(e);
      const bulb = ctx.createRadialGradient(x, y, 0, x, y, R * 0.22);
      bulb.addColorStop(0, mix([255, 220, 120], [255, 255, 245], light)); bulb.addColorStop(1, mix([90, 60, 20], [255, 190, 60], light));
      ctx.fillStyle = bulb; ctx.fill();
    }
    ctx.restore();

    if (tip[2] >= 0) antenna();
    ears.filter((n) => n[2] >= 0).forEach(ear);

    // Light spilling out of the eyes: strongest when they face the viewer, it streaks outwards as the head turns.
    ctx.save();
    ctx.globalCompositeOperation = "lighter";
    for (const e of EYES.map(rotate)) {
      if (e[2] <= 0) continue;
      const [x, y] = screen(e), k = light * e[2];
      for (let i = 0; i < 4; i++) {
        const [bx, by] = [x + e[0] * R * 0.22 * i, y - e[1] * R * 0.22 * i], r = R * (0.28 + 0.07 * i);
        const glow = ctx.createRadialGradient(bx, by, 0, bx, by, r);
        glow.addColorStop(0, `rgba(255,214,110,${0.55 * k / (1 + i)})`); glow.addColorStop(1, "rgba(255,214,110,0)");
        ctx.fillStyle = glow; ctx.fillRect(bx - r, by - r, 2 * r, 2 * r);
      }
    }
    ctx.restore();
  };

  if (still) {
    const redraw = () => draw(-0.25, 0.1, 0, 1, 1);
    redraw();
    matchMedia("(prefers-color-scheme: dark)").addEventListener("change", redraw);
    document.addEventListener("themechange", redraw);
    return;
  }

  // Motion: the head snaps between gaze targets like a servo, follows the pointer when it is around, and blinks.
  let pose = [0, 0], target = [0, 0], nextLook = 0, pointerUntil = 0, blinkAt = performance.now() + 3000, last = performance.now();
  addEventListener("pointermove", (ev) => {
    const r = canvas.getBoundingClientRect();
    const dx = ev.clientX - (r.left + r.width / 2), dy = ev.clientY - (r.top + r.height / 2);
    target = [Math.atan(dx / 250) * 0.9, Math.atan(-dy / 250) * 0.6];
    pointerUntil = performance.now() + 2500;
  });
  const frame = (now) => {
    const dt = Math.min(now - last, 100) / 1000, t = now / 1000;
    last = now;
    if (now > pointerUntil && now > nextLook) {
      target = [(Math.random() * 2 - 1) * 0.9, (Math.random() * 2 - 1) * 0.3 + 0.05];
      nextLook = now + 1500 + Math.random() * 2500;
    }
    const k = 1 - Math.exp(-dt * 7);
    pose = pose.map((v, i) => v + (target[i] - v) * k);
    if (now > blinkAt + 160) blinkAt = now + 3000 + Math.random() * 4000;
    const light = now > blinkAt ? 0.15 : 0.92 + 0.08 * Math.sin(t * 9);
    const roll = 0.08 * Math.sin(t * 0.7) - (target[0] - pose[0]) * 0.25;
    draw(pose[0], pose[1], roll, light, 0.5 + 0.5 * Math.sin(t * 3));
    requestAnimationFrame(frame);
  };
  requestAnimationFrame(frame);
})();

// --- start -------------------------------------------------------------------------------------------
(async () => {
  try {
    [skills, catalog] = await Promise.all([api("skills"), api("catalog")]);
    document.getElementById("version").textContent = "v" + catalog.version;
    document.getElementById("about-version").textContent = "Version " + catalog.version + ".";
    refreshSettingsBadge();
  } catch (e) {
    app().replaceChildren(errorBox(e));
    return;
  }
  route();
})();
