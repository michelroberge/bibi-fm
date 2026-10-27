"use strict";
// Graph page: fine-tune what chat retrieves for each skill (keywords, description, examples, actions, learned steps),
// draft a skill from a description, and an advanced editor for any node or edge of bibi.db.

const enc = encodeURIComponent;
const tunePath = (name, rest) => `graph/tune/${enc(name)}${rest ? "/" + rest : ""}`;
const stepsText = (steps) => JSON.stringify(steps || [], null, 1);

function parseJSON(text, what) {
  try { return JSON.parse(text); } catch (e) { throw new Error(`${what} isn't valid JSON: ${e.message}`); }
}

// Runs a change and re-renders with what it returns; a refusal shows in `out`.
function change(out, fn, then) {
  return async () => {
    try { then(await fn()); } catch (e) { out.replaceChildren(failBox(e.message)); }
  };
}

function graphTabs(active) {
  return h("div", { class: "row" }, h("span", { class: "seg" },
    h("button", { class: active === "skills" ? "on" : "", onclick: () => { location.hash = "#/graph"; } }, "Skills"),
    h("button", { class: active === "advanced" ? "on" : "", onclick: () => { location.hash = "#/graph/advanced"; } }, "Advanced")));
}

async function showGraph(id) {
  if (id === "advanced") return showAdvanced();
  if (id) return showTuning(id);
  const all = await api("graph/skills");
  const byNs = {};
  for (const s of all) (byNs[s.namespace || "generic"] ||= []).push(s);
  app().replaceChildren(h("div", {},
    h("h1", {}, "Graph"),
    h("p", { class: "muted" }, "The graph behind the skills: the words chat matches each skill on, the example requests it learns from, and the steps of learned skills. Your edits override bibi's defaults and survive updates; each can be reset."),
    graphTabs("skills"),
    describePanel(),
    tryPanel(),
    Object.keys(byNs).sort().map((ns) => [h("div", { class: "ns" }, ns),
      h("div", { class: "grid" }, byNs[ns].map((s) => h("a", { class: "card", href: `#/graph/${enc(s.name)}` },
        h("div", { class: "row" }, h("strong", {}, s.name), s.source === "learned" ? pill("learned", "accent") : null,
          s.status !== "active" ? pill(s.status, s.status === "candidate" ? "warn" : "") : null),
        h("div", { class: "muted small" }, s.help))))])));
}

// skills.create: bibi drafts a skill from a description; the run page shows the draft, Skills keeps or dismisses it.
function describePanel() {
  const text = h("textarea", { rows: 2, placeholder: "e.g. show free disk space and the 10 biggest files in a folder I name" });
  const out = h("div", {});
  return h("div", { class: "panel" },
    h("h3", {}, "Describe a new skill"),
    h("p", { class: "muted small" }, "bibi drafts it with the tools chat has and keeps only steps its rules accept. It is saved as a proposed skill: keep it under Skills, then tune it here."),
    text,
    h("div", { class: "row" }, h("button", { class: "primary small", onclick: change(out, async () => {
      if (!text.value.trim()) throw new Error("describe what the skill should do");
      return api("runs", { skill: "skills.create", argv: [text.value.trim()] });
    }, (r) => { location.hash = `#/run/${enc(r.id)}`; }) }, "Draft it")),
    out);
}

// What a request would retrieve: the skills and examples chat would show the model, without asking it.
function tryPanel(highlight) {
  const q = h("input", { type: "search", placeholder: "Type a request, like: how much space is left" });
  const out = h("div", { class: "small" });
  const go = () => fill(out, async () => {
    if (!q.value.trim()) return [];
    const r = await api(`graph/preview?q=${enc(q.value)}`);
    const mark = (name) => name === highlight ? pill(name, "ok") : pill(name);
    return [
      h("div", { class: "row" }, h("span", { class: "muted" }, "Skills:"), r.skills.length ? r.skills.map(mark) : h("span", { class: "muted" }, "none")),
      h("div", { class: "row" }, h("span", { class: "muted" }, "Examples:"), r.examples.length ? r.examples.map((e) => pill(e)) : h("span", { class: "muted" }, "none")),
      h("div", { class: "row" }, h("span", { class: "muted" }, "Tools offered:"), r.tools.map((t) => h("code", {}, t))),
    ];
  });
  q.addEventListener("keydown", (e) => { if (e.key === "Enter") go(); });
  return h("div", { class: "panel" }, h("h3", {}, "Try it"),
    h("div", { class: "row" }, q, h("button", { class: "small", onclick: go }, "Retrieve")), out);
}

// --- one skill --------------------------------------------------------------------------------------
async function showTuning(name) {
  renderTuning(await api(tunePath(name)));
}

function renderTuning(v) {
  const s = v.skill;
  const rerender = (nv) => renderTuning(nv);
  app().replaceChildren(h("div", {},
    h("a", { href: "#/graph", class: "small" }, "← Graph"),
    h("div", { class: "row" }, h("h1", {}, s.name), pill(s.source, s.source === "learned" ? "accent" : ""),
      s.status !== "active" ? pill(s.status, s.status === "candidate" ? "warn" : "") : null),
    h("p", { class: "muted" }, s.help),
    matchingPanel(v, rerender),
    tryPanel(s.name),
    examplesPanel(v, rerender),
    actionsPanel(v, rerender),
    s.source === "learned" ? stepsPanel(v, rerender) : null));
}

function overrideField(v, key, label, input, rerender, out) {
  const tuned = v.tuned.includes(key);
  const base = key === "text" ? v.defaultText : v.defaultKeywords;
  return h("label", { class: "field" }, h("span", {}, label, " ", tuned ? pill("tuned", "accent") : null), input,
    h("div", { class: "row small muted" }, `Default: ${base || "(none)"}`,
      tuned ? h("button", { class: "small", type: "button", onclick: change(out, () => api(tunePath(v.skill.name, "override"), { [key]: "" }), rerender) }, "Reset to default") : null));
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
      () => api(tunePath(v.skill.name, "override"), { keywords: keywords.value, text: text.value }), rerender) }, "Save"),
    out);
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
    return h("tr", { class: e.status === "disabled" ? "muted" : "" },
      h("td", {}, text, h("details", {}, h("summary", {}, `Steps (${e.steps.length})`), steps)),
      h("td", {}, pill(e.source, e.source === "manual" ? "accent" : ""), e.tuned.length ? [" ", pill("tuned", "accent")] : null,
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
    h("p", { class: "muted small" }, "Chat shows the model up to three examples that share words with a request. Weight is how often this one matched: higher ranks first. Removing a learned example unlinks it; a starter example is disabled."),
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

// --- advanced: any node or edge -----------------------------------------------------------------------
async function showAdvanced(selected) {
  const kinds = await api("graph/kinds");
  const kind = h("select", {}, h("option", { value: "" }, "Any kind"),
    Object.keys(kinds).sort().map((k) => h("option", { value: k, selected: k === "skill" }, `${k} (${kinds[k]})`)));
  const q = h("input", { type: "search", placeholder: "Search names and text" });
  const list = h("div", {}), detail = h("div", {});
  const load = () => fill(list, async () => {
    const nodes = await api(`graph/nodes?kind=${enc(kind.value)}&q=${enc(q.value)}`);
    if (!nodes.length) return h("p", { class: "muted small" }, kind.value || q.value ? "Nothing found." : "Pick a kind or search.");
    return h("table", {}, h("thead", {}, h("tr", {}, h("th", {}, "Id"), h("th", {}, "Name"), h("th", {}, "Status"))),
      h("tbody", {}, nodes.map((n) => h("tr", { class: "click", onclick: () => openNode(n.id) },
        h("td", { class: "mono small" }, n.id), h("td", {}, n.name), h("td", {}, n.status)))));
  });
  const openNode = (id) => fill(detail, async () => nodePanel(await api(`graph/node?id=${enc(id)}`), openNode, load));
  kind.addEventListener("change", load);
  q.addEventListener("keydown", (e) => { if (e.key === "Enter") load(); });
  app().replaceChildren(h("div", {},
    h("h1", {}, "Graph"),
    h("p", { class: "muted" }, "Every node and edge in bibi.db. Built-in skills, starter examples, actions and namespaces are rebuilt from bibi's code, so only their status can change here; tune skills on their own page."),
    graphTabs("advanced"),
    h("div", { class: "row" }, kind, q, h("button", { class: "small", onclick: load }, "Search")),
    detail, list));
  load();
  if (selected) openNode(selected);
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
  const tune = n.kind === "skill" ? h("a", { href: `#/graph/${enc(n.name)}`, class: "small" }, "Tune this skill →") : null;
  return h("div", { class: "panel" },
    h("div", { class: "spread" }, h("div", { class: "row" }, h("h3", { class: "mono" }, n.id), pill(n.kind)), tune),
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
