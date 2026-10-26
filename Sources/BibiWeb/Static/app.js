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
  for (const c of children.flat()) {
    if (c === null || c === undefined || c === false) continue;
    el.append(c instanceof Node ? c : document.createTextNode(String(c)));
  }
  return el;
}

async function api(path, body) {
  const opts = { headers: { "X-Bibi-Token": token() } };
  if (body !== undefined) {
    opts.method = "POST";
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

// --- router --------------------------------------------------------------------------------------
async function route() {
  if (currentStream) { currentStream.close(); currentStream = null; }
  bar().hidden = true;
  const hash = location.hash.slice(1) || "/";
  const [, view, id] = hash.split("/");
  for (const a of document.querySelectorAll("nav a")) {
    a.classList.toggle("active", a.dataset.nav === (view || "home") || (view === "run" && a.dataset.nav === "home"));
  }
  try {
    if (view === "run" && id) await showRun(decodeURIComponent(id));
    else if (view === "history") await showHistory();
    else if (view === "diff") await showDiff(id ? decodeURIComponent(id) : "");
    else await showHome();
  } catch (e) {
    app().replaceChildren(errorBox(e));
  }
  window.scrollTo(0, 0);
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
          h("span", { class: "row" }, s.usesWeb ? h("span", { class: "pill accent" }, "web") : null,
            s.adminActions ? h("span", { class: "pill warn" }, "admin") : null)),
        h("div", { class: "muted small" }, s.help));
      cards.push(card);
      return card;
    }))));
  app().replaceChildren(
    h("h1", {}, "What should bibi look at?"),
    h("p", { class: "muted" }, "Everything is analyzed on this Mac with the on-device model. Nothing changes until you approve it."),
    ...sections, form);
}

function renderForm(form, s) {
  const inputs = {};
  const fields = s.params.map((p) => {
    const label = p.flags.length ? p.flags[p.flags.length - 1] : p.key;
    if (p.kind === "flag") {
      inputs[p.key] = h("input", { type: "checkbox" });
      return h("label", { class: "check" }, inputs[p.key], h("span", {}, p.help), h("code", { class: "muted" }, label));
    }
    inputs[p.key] = h("input", { type: p.kind === "int" ? "number" : "text", value: p.defaultValue ?? "",
      placeholder: p.kind === "list" ? "comma-separated" : (p.metavar || "") });
    return h("label", { class: "field" }, h("span", {}, `${p.help}`, " ", h("code", { class: "muted" }, label)), inputs[p.key]);
  });
  const online = h("input", { type: "checkbox", checked: s.onlineByDefault });
  const verbose = h("input", { type: "checkbox" });
  const err = h("div", { class: "small", style: "color: var(--bad)" });
  const go = h("button", { class: "primary", type: "button", onclick: async () => {
    const argv = [];
    for (const p of s.params) {
      const el = inputs[p.key];
      if (p.kind === "flag") { if (el.checked) argv.push(p.flags[p.flags.length - 1]); continue; }
      const v = el.value.trim();
      if (!v || v === (p.defaultValue ?? "")) continue;
      const values = p.kind === "list" ? v.split(",").map((x) => x.trim()).filter(Boolean) : [v];
      for (const x of values) p.flags.length ? argv.push(p.flags[p.flags.length - 1], x) : argv.push(x);
    }
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
const decisions = {};  // runId -> { actionId: "approve" | "skip" }

async function showRun(id) {
  const view = await api("runs/" + encodeURIComponent(id));
  const log = h("div", { class: "log" });
  const status = h("span", { class: "row" });
  const body = h("div", {});
  app().replaceChildren(
    h("div", { class: "spread" },
      h("div", {}, h("h1", {}, view.meta.skill), h("div", { class: "muted small mono" }, view.meta.args.join(" ") || "(default options)")),
      status),
    h("details", { open: !view.report || !!view.busy }, h("summary", {}, "Activity log"), log),
    body);

  let lastSeq = 0;
  const running = () => !view.report || view.busy || (!view.meta.finished && !view.meta.error);
  const setStatus = (busy) => status.replaceChildren(busy
    ? h("span", { class: "row muted" }, h("span", { class: "spinner" }), "working")
    : view.meta.error ? h("span", { class: "pill bad" }, "failed")
    : h("span", { class: "pill ok" }, "done"),
    h("span", { class: "pill" }, view.meta.online ? "online" : "offline"),
    h("span", { class: "muted small" }, when(view.meta.started)));
  setStatus(running());

  const subscribe = () => {
    if (currentStream) currentStream.close();
    const es = new EventSource(`/api/runs/${encodeURIComponent(id)}/events?from=${lastSeq}&token=${encodeURIComponent(token())}`);
    currentStream = es;
    es.onmessage = async (m) => {
      const e = JSON.parse(m.data);
      lastSeq = e.seq;
      if (e.type === "done") {
        es.close();
        currentStream = null;
        if (e.phase === "run") return showRun(id);
        return;
      }
      const last = log.lastElementChild;
      if (e.type === "progress" && last && last.classList.contains("progress")) last.remove();
      log.append(h("div", { class: e.type }, e.text));
      log.scrollTop = log.scrollHeight;
    };
  };
  if (running()) { subscribe(); if (!view.report) { body.replaceChildren(h("p", { class: "muted" }, "Collecting evidence and asking the model. This usually takes a minute.")); return; } }
  else log.append(h("div", { class: "muted" }, "Finished. Live output is only kept while bibi is running; the saved report is below."));

  renderReport(view, body, id, subscribe);
}

function renderReport(view, body, id, subscribe) {
  const r = view.report;
  if (!r) { body.replaceChildren(h("div", { class: "panel" }, view.meta.error ? "This run failed: " + view.meta.error : "No report.")); return; }
  const dec = (decisions[id] ||= {});
  const obsById = Object.fromEntries(r.observations.map((o) => [o.id, o]));
  const executed = new Set(view.journal.filter((j) => j.event === "executed").map((j) => j.actionID));

  const parts = [h("div", { class: "panel" }, h("pre", { style: "background:none;padding:0;margin:0;font:inherit" }, r.summary.trim()),
    ...(r.notes || []).map((n) => h("div", { class: "muted small" }, "note: " + n)))];

  if (r.diff) {
    const ch = r.diff.changes;
    parts.push(h("h2", {}, `Changes since ${when(r.diff.baselineDate)}`),
      h("div", { class: "panel" }, ch.length ? changeList(ch.slice(0, 30)) : h("span", { class: "muted" }, "Nothing changed."),
        ch.length > 30 ? h("a", { href: "#/diff/" + encodeURIComponent(view.meta.skill) }, `… all ${ch.length} changes`) : null));
  }

  if (r.hypotheses?.length) {
    parts.push(h("h2", {}, "Possible connections"),
      ...r.hypotheses.map((hy) => h("div", { class: "panel" },
        h("div", { class: "spread" }, h("h3", {}, hy.title), meter(hy.confidence)),
        h("p", {}, hy.explanation),
        h("div", { class: "muted small" }, "Links " + hy.findingIDs.join(", "), " · model hypothesis, check before acting"),
        evidence(hy.observationIDs, obsById))));
  }

  const order = ["high", "medium", "low", "info"];
  const findings = [...r.findings].sort((a, b) => order.indexOf(a.severity) - order.indexOf(b.severity));
  parts.push(h("h2", {}, `Findings (${findings.length})`));
  if (!findings.length) parts.push(h("div", { class: "panel muted" }, "Nothing to report."));
  for (const f of findings) parts.push(findingCard(f, view, id, dec, obsById, executed, subscribe));

  const done = view.journal.filter((j) => ["executed", "failed", "undone", "undo-failed", "dry-run"].includes(j.event));
  if (done.length) {
    parts.push(h("h2", {}, "What was done"), h("div", { class: "panel" },
      h("table", {}, h("tr", {}, h("th", {}, "When"), h("th", {}, "What"), h("th", {}, "Result"), h("th", {}, "From")),
        done.map((j) => h("tr", {}, h("td", { class: "small" }, when(j.time)),
          h("td", {}, j.title || j.call?.spec, " ", h("span", { class: "pill" + (j.event === "failed" || j.event === "undo-failed" ? " bad" : j.event === "undone" ? " warn" : "") }, j.event)),
          h("td", { class: "small" }, j.error || j.message || ""), h("td", { class: "small muted" }, j.frontend || "")))),
      view.undoable.length ? h("div", { class: "row", style: "margin-top: 12px" },
        h("button", { onclick: () => undo(view, id, subscribe) }, `Undo ${view.undoable.length} action(s)`),
        view.undoNeedsAdmin ? h("span", { class: "pill warn" }, "asks for your password") : null) : null));
  }

  parts.push(h("details", {}, h("summary", {}, `Audit: ${view.modelCalls} model call(s), ${view.network.length} network request(s), run ${view.meta.id}`),
    view.network.length ? h("table", {}, view.network.map((n) => h("tr", {}, h("td", { class: "small" }, n.method),
      h("td", { class: "small mono" }, n.url), h("td", { class: "small" }, n.error || n.status || ""), h("td", { class: "small muted" }, n.sent || ""))))
      : h("p", { class: "muted small" }, view.meta.online ? "No network requests." : "Offline run: nothing left this Mac.")));

  body.replaceChildren(...parts);
  renderBar(view, id, dec, subscribe);
}

function changeList(changes) {
  return h("div", {}, changes.map((c) => h("div", { class: "change-" + c.kind },
    c.kind === "added" ? "+ " : c.kind === "removed" ? "− " : "~ ", changeText(c))));
}
function show(v) {
  if (v === null || v === undefined) return "nothing";
  if (typeof v === "number") return v >= 1048576 ? human(v) : (Number.isInteger(v) ? String(v) : v.toFixed(1));
  if (typeof v === "boolean") return v ? "yes" : "no";
  return typeof v === "string" ? v : JSON.stringify(v);
}
function changeText(c) {
  const item = c.item ? " " + c.item : "";
  if (c.kind === "added") return `${c.key}:${item} is new${c.to !== undefined && c.to !== null ? ` (${show(c.to)})` : ""}`;
  if (c.kind === "removed") return `${c.key}:${item} is gone${c.from !== undefined && c.from !== null ? ` (was ${show(c.from)})` : ""}`;
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

function findingCard(f, view, id, dec, obsById, executed, subscribe) {
  const uncertaintyClass = { low: "ok", medium: "warn", high: "bad" }[f.uncertainty];
  const diags = f.diagnostics.map((d) => catalog.diagnostics.find((x) => x.id === d)).filter(Boolean);
  return h("div", { class: `panel finding ${f.severity}` },
    h("div", { class: "spread" },
      h("div", { class: "row" }, h("span", { class: "pill sev-" + f.severity }, f.severity), h("h3", {}, f.title)),
      h("div", { class: "row" }, meter(f.confidence), h("span", { class: "pill " + uncertaintyClass, title: "how uncertain this finding is" }, `${f.uncertainty} uncertainty`),
        h("span", { class: "pill", title: "who wrote the explanation" }, f.explainedBy === "model" ? "explained by fm" : "rule"))),
    h("p", {}, f.explanation),
    evidence(f.observationIDs, obsById),
    diags.length ? h("div", { class: "small" }, h("div", { class: "muted" }, "To check:"),
      diags.map((d) => diagnosticRow(d, f, view, id, subscribe))) : null,
    f.recommendations.map((a) => recommendation(a, view, id, dec, executed)));
}

function fillTemplate(d, subject) {
  let ok = true;
  const argv = d.argv.map((a) => a.replace(/\{(\w+)\}/g, (_, k) => (subject[k] ?? (k === "uid" ? "$(id -u)" : (ok = false, `<${k}>`)))));
  return { cmd: (d.admin ? "sudo " : "") + argv.map((a) => /^[\w@%+=:,./-]+$/.test(a) ? a : `'${a.replace(/'/g, "'\\''")}'`).join(" "), runnable: ok };
}

function diagnosticRow(d, f, view, id, subscribe) {
  const { cmd, runnable } = fillTemplate(d, f.subject || {});
  const out = h("div", {});
  return h("div", {},
    h("div", { class: "row" }, h("code", {}, cmd),
      h("button", { class: "small", onclick: () => navigator.clipboard?.writeText(cmd) }, "Copy"),
      runnable ? h("button", { class: "small", onclick: async (ev) => {
        if (d.admin && !(await confirmDialog("Run with administrator rights?", [h("p", {}, d.title), h("pre", {}, cmd),
          h("p", { class: "muted small" }, "macOS will ask for your password. bibi never sees it.")], "Run"))) return;
        ev.target.disabled = true;
        out.replaceChildren(h("span", { class: "spinner" }));
        try {
          const res = await api(`runs/${encodeURIComponent(id)}/diagnostic`, { finding: f.id, diagnostic: d.id, confirmAdmin: d.admin });
          out.replaceChildren(...res.map((x) => x.ok ? h("pre", {}, x.output || x.message) : h("div", { class: "result fail" }, x.message)));
        } catch (e) { out.replaceChildren(h("div", { class: "result fail" }, e.message)); }
        ev.target.disabled = false;
      } }, "Run") : null,
      h("span", { class: "muted small" }, d.title)),
    out);
}

function recommendation(a, view, id, dec, executed) {
  const info = view.actionInfo[a.id] || {};
  const state = dec[a.id];
  const preview = h("div", {});
  const seg = h("span", { class: "seg" },
    h("button", { class: state === "approve" ? "on" : "", onclick: () => { dec[a.id] = state === "approve" ? undefined : "approve"; route(); } }, "Approve"),
    h("button", { class: state === "skip" ? "on skip" : "", onclick: () => { dec[a.id] = state === "skip" ? undefined : "skip"; route(); } }, "Skip"));
  return h("div", { class: "rec " + (state === "approve" ? "approved" : state === "skip" ? "skipped" : "") },
    h("div", { class: "spread" },
      h("div", {}, h("strong", {}, a.title), executed.has(a.id) ? h("span", { class: "pill ok", style: "margin-left:8px" }, "done") : null),
      executed.has(a.id) ? null : seg),
    h("div", { class: "row small", style: "margin: 4px 0" },
      a.bytes ? h("span", { class: "pill accent" }, human(a.bytes)) : null,
      h("span", { class: "pill" }, `safety ${a.safety}/10`),
      h("span", { class: "pill" }, `confidence ${a.confidence}/10`),
      info.reversible ? h("span", { class: "pill ok" }, "undoable") : h("span", { class: "pill" }, "not undoable"),
      info.privilege === "admin" ? h("span", { class: "pill warn" }, "password required") : null),
    h("div", { class: "small" }, a.reason),
    h("div", { class: "row small", style: "margin-top: 4px" }, h("code", { class: "muted" }, a.command),
      h("button", { class: "small", onclick: async () => {
        try {
          const p = (await api(`runs/${encodeURIComponent(id)}/preview`, { actions: [a.id] }))[a.id];
          preview.replaceChildren(p.error ? h("div", { class: "result fail" }, "Cannot run: " + p.error)
            : h("ul", { class: "small" }, p.steps.map((s) => h("li", {}, s))));
        } catch (e) { preview.replaceChildren(h("div", { class: "result fail" }, e.message)); }
      } }, "Preview")),
    preview);
}

function renderBar(view, id, dec, subscribe) {
  const approved = Object.entries(dec).filter(([, v]) => v === "approve").map(([k]) => k);
  if (!approved.length) { bar().hidden = true; return; }
  const dry = h("input", { type: "checkbox" });
  bar().hidden = false;
  bar().replaceChildren(
    h("strong", {}, `${approved.length} approved`),
    h("label", { class: "check" }, dry, "Dry run (show what would happen)"),
    h("button", { onclick: () => { for (const k of approved) delete dec[k]; route(); } }, "Clear"),
    h("button", { class: "primary", onclick: () => execute(view, id, approved, dry.checked, subscribe) }, dry.checked ? "Dry run" : "Run approved"));
  dry.addEventListener("change", () => bar().lastElementChild.textContent = dry.checked ? "Dry run" : "Run approved");
}

async function execute(view, id, ids, dryRun, subscribe) {
  const chosen = ids.map((i) => view.report.findings.flatMap((f) => f.recommendations).find((a) => a.id === i)).filter(Boolean);
  const admin = chosen.filter((a) => view.actionInfo[a.id]?.privilege === "admin");
  const irreversible = chosen.filter((a) => !view.actionInfo[a.id]?.reversible);
  let previews = {};
  try { previews = await api(`runs/${encodeURIComponent(id)}/preview`, { actions: ids }); } catch (_) {}
  const list = h("ul", {}, chosen.map((a) => h("li", {}, a.title,
    previews[a.id]?.error ? h("div", { class: "small", style: "color: var(--bad)" }, "will fail: " + previews[a.id].error)
      : h("div", { class: "small muted" }, (previews[a.id]?.steps || []).join("; ")))));
  const notes = [];
  if (!dryRun && irreversible.length) notes.push(h("p", { class: "small" }, `${irreversible.length} of these cannot be undone.`));
  if (!dryRun && admin.length) notes.push(h("p", { class: "small" }, h("strong", {}, `${admin.length} need administrator rights. `),
    "macOS will show its own password dialog for each one; bibi and this page never see your password."));
  if (!(await confirmDialog(dryRun ? "Dry run these actions?" : "Run these actions?", [list, ...notes], dryRun ? "Dry run" : "Run", !dryRun && irreversible.length > 0))) return;
  bar().hidden = true;
  subscribe();
  const decs = decisions[id];
  try {
    const results = await api(`runs/${encodeURIComponent(id)}/execute`, { actions: ids, dryRun, confirmAdmin: admin.length > 0 });
    for (const k of ids) delete decs[k];
    await showRun(id);
    app().prepend(h("div", { class: "panel" }, h("h3", {}, dryRun ? "Dry run" : "Results"),
      results.map((r) => h("div", { class: "result " + (r.ok ? "ok" : "fail") }, h("strong", {}, r.title), " — ", r.message,
        r.output ? h("pre", {}, r.output) : null))));
  } catch (e) {
    app().prepend(errorBox(e));
  }
}

async function undo(view, id, subscribe) {
  const entries = view.journal.filter((j) => j.event === "executed" && view.undoable.includes(j.actionID));
  const ok = await confirmDialog("Undo these actions?", [h("ul", {}, entries.map((e) => h("li", {}, e.title, h("div", { class: "small muted" }, e.message || "")))),
    view.undoNeedsAdmin ? h("p", { class: "small" }, "Some need administrator rights; macOS will ask for your password.") : null].filter(Boolean), "Undo");
  if (!ok) return;
  subscribe();
  try {
    const results = await api(`runs/${encodeURIComponent(id)}/undo`, { confirmAdmin: view.undoNeedsAdmin });
    await showRun(id);
    app().prepend(h("div", { class: "panel" }, h("h3", {}, "Undo"),
      results.map((r) => h("div", { class: "result " + (r.ok ? "ok" : "fail") }, r.title, " — ", r.message))));
  } catch (e) { app().prepend(errorBox(e)); }
}

// --- history ---------------------------------------------------------------------------------------
async function showHistory() {
  const runs = await api("history");
  app().replaceChildren(h("h1", {}, "History"),
    h("p", { class: "muted" }, "Every run is saved with its evidence, model calls, the actions you chose and their results."),
    runs.length ? h("div", { class: "panel" }, h("table", {},
      h("tr", {}, h("th", {}, "When"), h("th", {}, "Command"), h("th", {}, "Result"), h("th", {}, "Options")),
      runs.map((r) => h("tr", { class: "click", onclick: () => location.hash = "#/run/" + encodeURIComponent(r.meta.id) },
        h("td", { class: "small" }, when(r.meta.started)),
        h("td", {}, r.meta.skill),
        h("td", { class: "small" }, r.meta.error ? h("span", { class: "pill bad" }, "failed")
          : r.meta.finished ? `${r.meta.findings ?? 0} findings` : h("span", { class: "pill" }, "running"),
          r.undoable ? h("span", { class: "pill warn", style: "margin-left:6px" }, `${r.undoable} undoable`) : null),
        h("td", { class: "small mono muted" }, r.meta.args.join(" ")))))) : h("div", { class: "empty" }, "No runs yet."));
}

// --- changes (baseline diff) ---------------------------------------------------------------------
async function showDiff(skill) {
  const select = h("select", {}, h("option", { value: "" }, "Choose a command"), skills.map((s) => h("option", { value: s.name, selected: s.name === skill }, s.name)));
  const since = h("select", {}, ["", "1d", "7d", "30d"].map((v) => h("option", { value: v }, v ? `at least ${v.replace("d", " day(s)")} ago` : "about a week ago (default)")));
  const out = h("div", {});
  const load = async () => {
    if (!select.value) { out.replaceChildren(); return; }
    out.replaceChildren(h("span", { class: "spinner" }));
    try {
      const d = await api(`diff?skill=${encodeURIComponent(select.value)}&since=${encodeURIComponent(since.value)}`);
      if (!d.latest) out.replaceChildren(h("div", { class: "empty" }, "No runs of this command yet."));
      else if (!d.baseline) out.replaceChildren(h("div", { class: "empty" }, "Only one comparable run so far. Run it again later to see what changed."));
      else out.replaceChildren(h("div", { class: "panel" },
        h("div", { class: "muted small" }, h("a", { href: "#/run/" + d.latest.id }, `Latest run (${when(d.latest.started)})`), " compared with ",
          h("a", { href: "#/run/" + d.baseline.id }, when(d.baseline.started))),
        d.changes.length ? changeList(d.changes) : h("p", {}, "Nothing changed.")));
    } catch (e) { out.replaceChildren(errorBox(e)); }
  };
  select.addEventListener("change", load);
  since.addEventListener("change", load);
  app().replaceChildren(h("h1", {}, "Changes"),
    h("p", { class: "muted" }, "Compare the latest run of a command with an earlier one: new listeners, login items, apps, resource use…"),
    h("div", { class: "row" }, select, since), out);
  load();
}

// --- start -------------------------------------------------------------------------------------------
(async () => {
  try {
    [skills, catalog] = await Promise.all([api("skills"), api("catalog")]);
    document.getElementById("version").textContent = "v" + catalog.version;
  } catch (e) {
    app().replaceChildren(errorBox(e));
    return;
  }
  route();
})();
