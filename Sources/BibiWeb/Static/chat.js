"use strict";
// Chat with bibi, and the Skills page. Loaded before app.js; uses its helpers (h, api, token, recommendation,
// confirmDialog, decisionsFor, currentStream) at call time.

const chatUI = { id: "", view: null, lastSeq: 0, draft: "", running: new Set(), quick: [], query: "" };

async function showChat(id) {
  chatUI.id = id;
  chatUI.lastSeq = 0;
  const [chats, quick] = await Promise.all([api("chats?q=" + encodeURIComponent(chatUI.query || "")).catch(() => []),
    api("graph/quick").catch(() => [])]);
  chatUI.quick = quick;
  chatUI.view = id ? await api("chat/" + encodeURIComponent(id)) : null;
  renderChat(chats);
  if (chatUI.view?.busy) followChat();
}

function renderChat(chats) {
  const v = chatUI.view, id = chatUI.id;
  const list0 = h("div", { class: "chatlist" });
  const search = h("input", { type: "search", placeholder: "Search chats", value: chatUI.query || "", "aria-label": "Search chats" });
  let timer;
  search.addEventListener("input", () => {
    chatUI.query = search.value;
    clearTimeout(timer);
    timer = setTimeout(async () => fillChatList(list0, await api("chats?q=" + encodeURIComponent(search.value)).catch(() => [])), 200);
  });
  fillChatList(list0, chats);
  const side = h("aside", { class: "chats" },
    h("button", { class: "primary", style: "width:100%", onclick: () => { location.hash = "#/chat"; } }, "New chat"),
    search, list0);

  const list = h("div", { class: "chat", id: "chatlog" });
  if (!v) {
    list.append(h("div", { class: "empty" },
      h("h2", { style: "margin-top:0" }, "Ask bibi about " + (catalog.hostName || "this Mac")),
      h("p", {}, "bibi answers from what it can check. When it needs to look at something or change it, it proposes the exact steps and nothing runs until you approve them."),
      h("div", { class: "row", style: "justify-content:center" }, ["How much free disk space do I have?", "What is using my CPU?", "Which apps start at login?"]
        .map((q) => h("button", { class: "small", onclick: () => sendChat(q) }, q)))));
  } else {
    const byFinding = Object.fromEntries((v.report?.findings || []).map((f) => [f.id, f]));
    for (const m of v.transcript) list.append(chatMessage(m, byFinding));
    for (const c of v.candidates.filter((c) => c.status === "candidate")) list.append(candidateCard(c));
  }
  const thinking = h("div", { class: "msg bibi thinking", id: "thinking", hidden: !v?.busy },
    h("span", { class: "row" }, h("span", { class: "spinner" }), h("span", { id: "thinking-text", class: "muted" }, "thinking…")),
    h("div", { id: "thinking-log", class: "muted small mono" }));
  list.append(thinking);

  const input = h("textarea", { rows: 2, placeholder: "Ask anything about this Mac, or ask bibi to do something…", id: "composer-input" });
  input.value = chatUI.draft;
  input.addEventListener("input", () => { chatUI.draft = input.value; });
  input.addEventListener("keydown", (e) => {
    if (e.key === "Enter" && !e.shiftKey && !e.isComposing) { e.preventDefault(); sendChat(input.value); }
  });
  const composer = h("div", { class: "composer" }, input,
    h("button", { class: "primary", id: "composer-send", onclick: () => sendChat(input.value) }, "Send"));

  const head = v ? h("div", { class: "spread" }, h("h1", {}, v.state.title),
    h("span", { class: "row small" },
      v.undoable.length ? h("a", { href: "#/run/" + encodeURIComponent(id) }, `${v.undoable.length} undoable`) : null,
      h("a", { href: "#/run/" + encodeURIComponent(id), title: "Evidence, the journal of what ran, and undo" }, "Details"))) : h("h1", {}, "Chat");
  app().replaceChildren(h("div", { class: "chatpage" }, side, h("section", { class: "chatmain" }, head, list, composer), quickPanel()));
  setBusy(!!v?.busy);
  renderChatBar();
  list.scrollIntoView({ block: "end" });
  window.scrollTo(0, document.body.scrollHeight);
  input.focus();
}

// Most-used skills, one click away: the same run as the Run page's button, with default options.
function quickPanel() {
  if (!chatUI.quick.length) return h("aside", { class: "quick" });
  return h("aside", { class: "quick" },
    h("div", { class: "ns", style: "margin-top:0" }, "Quick run"),
    chatUI.quick.map((s) => h("button", { class: "card quickrun", type: "button", title: s.help, onclick: () => quickRun(s.name) },
      h("div", { class: "spread" }, h("strong", { class: "small" }, s.name), s.source === "learned" ? h("span", { class: "pill accent" }, "learned") : null),
      h("div", { class: "muted small" }, s.help))),
    h("a", { class: "small", href: "#/run" }, "All skills and options →"));
}

async function quickRun(skill) {
  try {
    const r = await api("runs", { skill, argv: [] });
    location.hash = "#/run/" + encodeURIComponent(r.id);
  } catch (e) {
    document.getElementById("chatlog")?.append(h("div", { class: "msg note" }, e.message));
  }
}

function fillChatList(el, chats) {
  if (!chats.length) { el.replaceChildren(h("div", { class: "muted small", style: "padding:6px 8px" }, chatUI.query ? "No chat matches." : "No chats yet.")); return; }
  el.replaceChildren(...chats.map((c) => h("div", { class: "chatitem" + (c.id === chatUI.id ? " active" : "") },
    h("a", { href: "#/chat/" + encodeURIComponent(c.id) },
      h("div", { class: "title" }, c.title),
      c.snippet ? h("div", { class: "muted small snippet" }, c.snippet) : h("div", { class: "muted small" }, when(c.started))),
    h("button", { class: "small icon", title: "Delete this chat", "aria-label": "Delete " + c.title, onclick: () => deleteChat(c) }, "×"))));
}

async function deleteChat(c) {
  const notes = [h("p", {}, c.title),
    h("p", { class: "small muted" }, "The transcript and its history run are removed. What bibi learned from it (statistics, examples, facts) stays.")];
  if (c.undoable) notes.push(h("p", { class: "small" }, h("strong", {}, `${c.undoable} action(s) from this chat can still be undone. `),
    "After deleting, bibi can't undo them any more (trashed files stay in the Trash)."));
  if (!(await confirmDialog("Delete this chat?", notes, "Delete", true))) return;
  try {
    await api("chat/" + encodeURIComponent(c.id), undefined, "DELETE");
    if (chatUI.id === c.id) { location.hash = "#/chat"; return; }
    renderChat(await api("chats?q=" + encodeURIComponent(chatUI.query || "")));
  } catch (e) {
    document.getElementById("chatlog")?.append(h("div", { class: "msg note" }, e.message));
  }
}

function chatMessage(m, byFinding) {
  if (m.role === "user") return h("div", { class: "msg user" }, m.text);
  if (m.role === "note") return h("div", { class: "msg note" }, m.text);
  if (m.role === "result") {
    const [first, ...rest] = m.text.split("\n");
    return h("div", { class: "msg outcome" }, h("div", { class: "result " + (m.ok ? "ok" : "fail") }, first),
      rest.length ? (rest.join("\n").length > 400 ? h("details", {}, h("summary", {}, "Output"), h("pre", {}, rest.join("\n"))) : h("pre", {}, rest.join("\n"))) : null);
  }
  const f = m.finding ? byFinding[m.finding] : null;
  return h("div", { class: "msg bibi" }, h("div", { class: "text" }, m.text), f ? proposal(f) : null);
}

function proposal(f) {
  const v = chatUI.view, id = chatUI.id;
  const dec = decisionsFor(id);
  const executed = new Set(v.executed);
  if (f.id !== v.state.pending) {
    // Decided or superseded: a record of what was proposed and what happened.
    const skipped = new Set(v.transcript.filter((m) => m.role === "note" && m.actionID).map((m) => m.actionID));
    return h("div", { class: "proposal past small" }, f.recommendations.map((a) => h("div", { class: "row" },
      executed.has(a.id) ? h("span", { class: "pill ok" }, "ran")
        : chatUI.running.has(a.id) ? h("span", { class: "row" }, h("span", { class: "spinner" }), h("span", { class: "pill accent" }, "running…"))
        : h("span", { class: "pill" }, skipped.has(a.id) ? "skipped" : "not run"),
      h("code", { class: "muted" }, a.command))));
  }
  return h("div", { class: "proposal" }, f.recommendations.map((a) => {
    const card = recommendation(a, v, id, dec, executed, rerenderChat);
    const fields = v.actionInfo[a.id]?.fields || [];
    if (!fields.length || executed.has(a.id)) return card;
    card.append(draftForm(a, fields));
    if (a.problems) {
      // A draft with gaps can't be approved until they are filled in.
      if (dec[a.id] === "approve") delete dec[a.id];
      const approve = card.querySelector(".seg button");
      if (approve) { approve.disabled = true; approve.title = "Fill in the missing fields first"; }
    }
    return card;
  }));
}

// --- draft cards: an action's fields, editable before approving ------------------------------------
const choiceCache = {};

function draftForm(a, fields) {
  const params = a.call.params || {}, problems = a.problems || {};
  const form = h("div", { class: "draft" });
  for (const f of fields) {
    const value = params[f.key] ?? "";
    let input;
    if (f.kind === "longtext") {
      input = h("textarea", { rows: 4, placeholder: f.placeholder || "" });
      input.value = value;
    } else if (f.kind === "bool") {
      input = h("input", { type: "checkbox", checked: value === "true" });
    } else if (f.kind === "choice") {
      input = h("select", {}, h("option", { value: "" }, f.placeholder || "—"), value ? h("option", { value, selected: true }, value) : null);
      fillChoices(input, f, value);
    } else if (f.kind === "datetime") {
      // Stored as "2026-10-27 15:00" (or a day alone); the picker wants "2026-10-27T15:00".
      input = h("input", { type: "datetime-local", value: value.length > 10 ? value.replace(" ", "T") : value ? value + "T09:00" : "" });
    } else {
      input = h("input", { type: "text", value, placeholder: f.placeholder || "" });
    }
    input.addEventListener("change", () => editDraft(a.id, f.key, f.kind === "bool" ? String(input.checked) : input.value));
    const problem = problems[f.key];
    form.append(h("label", { class: "field" + (problem ? " bad" : "") },
      h("span", {}, f.label, f.required ? h("span", { class: "muted" }, " *") : null), input,
      problem ? h("small", { class: "problem" }, problem) : null));
  }
  if (problems[""]) form.append(h("div", { class: "result fail" }, problems[""]));
  return form;
}

// Choices come from the apps (Mail accounts, calendars, lists) once per page, or from the field itself.
function fillChoices(select, f, value) {
  const add = (items) => {
    for (const c of items) if (c.value !== value) select.append(h("option", { value: c.value }, c.label));
    for (const o of select.options) if (o.value === value) o.textContent = items.find((c) => c.value === value)?.label || value;
  };
  if (f.options) return add(f.options.map((o) => ({ value: o, label: o })));
  if (!f.source) return;
  (choiceCache[f.source] ||= api("choices/" + encodeURIComponent(f.source))).then(add).catch((e) => {
    delete choiceCache[f.source];
    select.title = e.message;
  });
}

async function editDraft(action, key, value) {
  try {
    await api(`chat/${encodeURIComponent(chatUI.id)}/edit`, { action, params: { [key]: value } });
    chatUI.view = await api("chat/" + encodeURIComponent(chatUI.id));
    rerenderChat();
  } catch (e) {
    document.getElementById("chatlog")?.append(h("div", { class: "msg note" }, e.message));
  }
}

function rerenderChat() {
  const y = window.scrollY;
  api("chats?q=" + encodeURIComponent(chatUI.query || "")).then((chats) => { renderChat(chats); window.scrollTo(0, y); });
}

function candidateCard(c) {
  const out = h("div", {});
  const act = (verb) => async () => {
    try {
      await api(`graph/skills/${encodeURIComponent(c.name)}/${verb}`, {});
      chatUI.view = await api("chat/" + encodeURIComponent(chatUI.id));
      rerenderChat();
    } catch (e) { out.replaceChildren(h("div", { class: "result fail" }, e.message)); }
  };
  return h("div", { class: "msg bibi" }, h("div", { class: "panel candidate" },
    h("div", { class: "spread" }, h("h3", {}, "New skill: " + c.name), h("span", { class: "pill accent" }, "learned")),
    h("p", {}, c.help),
    skillSteps(c),
    h("div", { class: "row" }, h("button", { class: "primary small", onclick: act("accept") }, "Keep this skill"),
      h("button", { class: "small", onclick: act("dismiss") }, "Dismiss")),
    out));
}

function skillSteps(s) {
  if (!s.steps?.length) return null;
  return h("ol", { class: "small mono" }, s.steps.map((st) => h("li", {}, st.tool === "command" ? st.args.join(" ") : `${st.tool} ${st.args.join(" ")}`)));
}

function setBusy(busy) {
  const t = document.getElementById("thinking");
  if (t) t.hidden = !busy;
  const send = document.getElementById("composer-send");
  if (send) send.disabled = busy;
  if (busy) bar().hidden = true;
}

async function sendChat(text) {
  text = (text || "").trim();
  if (!text) return;
  try {
    const r = await api("chat", { conversation: chatUI.id || undefined, message: text });
    chatUI.draft = "";
    if (r.id !== chatUI.id) {
      // A new conversation: show it, then follow its events from the start.
      history.replaceState(null, "", "#/chat/" + encodeURIComponent(r.id));
      chatUI.id = r.id;
      chatUI.view = await api("chat/" + encodeURIComponent(r.id));
      renderChat(await api("chats"));
    } else {
      document.getElementById("composer-input").value = "";
      document.getElementById("chatlog").insertBefore(h("div", { class: "msg user" }, text), document.getElementById("thinking"));
    }
    setBusy(true);
    followChat(true);
  } catch (e) {
    document.getElementById("chatlog")?.append(h("div", { class: "msg note" }, e.message));
  }
}

function followChat(skipOwnMessage) {
  if (currentStream) currentStream.close();
  const id = chatUI.id;
  const es = new EventSource(`/api/chat/${encodeURIComponent(id)}/events?from=${chatUI.lastSeq}&token=${encodeURIComponent(token())}`);
  currentStream = es;
  let skipUser = !!skipOwnMessage;
  const log = () => document.getElementById("thinking-log");
  es.onmessage = async (m) => {
    const e = JSON.parse(m.data);
    chatUI.lastSeq = e.seq;
    if (e.type === "done") {
      es.close();
      if (currentStream === es) currentStream = null;
      if (chatUI.id !== id) return;
      chatUI.running = new Set();
      chatUI.view = await api("chat/" + encodeURIComponent(id));
      renderChat(await api("chats"));
      return;
    }
    if (e.type === "delta") {
      const t = document.getElementById("thinking-text");
      if (t) { t.textContent = e.text; t.classList.remove("muted"); }
      return;
    }
    if (e.type === "message") {
      const msg = JSON.parse(e.text);
      if (msg.role === "user" && skipUser) { skipUser = false; return; }
      if (msg.role === "bibi") {
        const t = document.getElementById("thinking-text");
        if (t) { t.textContent = "thinking…"; t.classList.add("muted"); }
      }
      if (!msg.finding) document.getElementById("chatlog")?.insertBefore(chatMessage(msg, {}), document.getElementById("thinking"));
      window.scrollTo(0, document.body.scrollHeight);
      return;
    }
    if (["progress", "info", "ok", "error", "heading"].includes(e.type) && log()) {
      log().textContent = e.text;
    }
  };
}

function renderChatBar() {
  const v = chatUI.view, id = chatUI.id;
  if (!v || v.busy) { bar().hidden = true; return; }
  const dec = decisionsFor(id);
  const executed = new Set(v.executed);
  const open = (v.report?.findings || []).find((f) => f.id === v.state.pending);
  const valid = new Set((open?.recommendations || []).map((a) => a.id).filter((a) => !executed.has(a)));
  const approved = Object.entries(dec).filter(([k, x]) => x === "approve" && valid.has(k)).map(([k]) => k);
  const skipped = Object.entries(dec).filter(([k, x]) => x === "skip" && valid.has(k)).map(([k]) => k);
  if (!approved.length && !skipped.length) { bar().hidden = true; return; }
  const dry = h("input", { type: "checkbox" });
  const reason = h("input", { type: "text", placeholder: "Why skip? (bibi learns from this)", style: "max-width:280px" });
  bar().hidden = false;
  bar().replaceChildren(...[
    h("strong", {}, `${approved.length} approved, ${skipped.length} skipped`),
    skipped.length ? reason : null,
    approved.length ? h("label", { class: "check" }, dry, "Dry run") : null,
    h("button", { onclick: () => { for (const k of [...approved, ...skipped]) delete dec[k]; rerenderChat(); } }, "Clear"),
    h("button", { class: "primary", onclick: () => decideChat(approved, skipped, reason.value, dry.checked) }, approved.length ? "Run approved" : "Send"),
  ].filter(Boolean));
}

async function decideChat(approve, skip, reason, dryRun) {
  const v = chatUI.view, id = chatUI.id;
  const all = (v.report?.findings || []).flatMap((f) => f.recommendations);
  const chosen = approve.map((i) => all.find((a) => a.id === i)).filter(Boolean);
  const admin = chosen.filter((a) => v.actionInfo[a.id]?.privilege === "admin");
  const irreversible = chosen.filter((a) => !v.actionInfo[a.id]?.reversible);
  const outbound = chosen.filter((a) => a.kind === "outbound");
  if (chosen.length) {
    const notes = [h("ul", {}, chosen.map((a) => h("li", {}, a.title, h("div", { class: "small mono muted" }, a.command))))];
    if (!dryRun && outbound.length) notes.push(h("p", { class: "small" }, h("strong", {}, `${outbound.length} will send a message or place a call as you. `),
      "Check the recipients and text above: once sent, it can't be taken back."));
    if (!dryRun && irreversible.length) notes.push(h("p", { class: "small" }, `${irreversible.length} of these cannot be undone by bibi.`));
    if (!dryRun && admin.length) notes.push(h("p", { class: "small" }, h("strong", {}, `${admin.length} need administrator rights. `),
      "macOS will show its own password dialog for each one; bibi and this page never see your password."));
    if (!(await confirmDialog(dryRun ? "Dry run these steps?" : "Run these steps?", notes, dryRun ? "Dry run" : "Run",
      !dryRun && chosen.some((a) => a.kind !== "read-only" && a.kind !== "skill")))) return;
  }
  try {
    await api(`chat/${encodeURIComponent(id)}/decide`, { approve, skip, reason: reason || undefined, dryRun, confirmAdmin: admin.length > 0 });
    const dec = decisionsFor(id);
    for (const k of [...approve, ...skip]) delete dec[k];
    // Show the decision right away: the cards become a record of what is running.
    chatUI.running = new Set(approve);
    v.state.pending = null;
    v.busy = "decide";
    rerenderChat();
    followChat();
  } catch (e) {
    document.getElementById("chatlog")?.append(h("div", { class: "msg note" }, e.message));
  }
}

// --- skills ----------------------------------------------------------------------------------------
async function showSkills() {
  const all = await api("graph/skills");
  const candidates = all.filter((s) => s.status === "candidate");
  const byNs = {};
  for (const s of all.filter((s) => s.status !== "candidate" && s.namespace !== "")) (byNs[s.namespace] ||= []).push(s);
  const generic = all.find((s) => s.namespace === "");
  app().replaceChildren(h("div", {},
    h("h1", {}, "Skills"),
    h("p", { class: "muted" }, "What bibi can do, how often its proposals were approved, and skills it learned from your chats. Guidance is part of each skill's prompt; bibi adds an \"Avoid:\" line when you skip a proposal and say why, and rolls a change back if approvals drop."),
    candidates.length ? h("h2", {}, "Proposed skills") : null,
    candidates.map((c) => skillCard(c)),
    generic ? h("h2", {}, "Generic (chat)") : null, generic ? skillCard(generic) : null,
    Object.keys(byNs).sort().map((ns) => [h("div", { class: "ns" }, ns), byNs[ns].map((s) => skillCard(s))])));
}

function skillCard(s) {
  const out = h("div", {});
  const act = (verb) => async () => {
    try { await api(`graph/skills/${encodeURIComponent(s.name)}/${verb}`, {}); await showSkills(); }
    catch (e) { out.replaceChildren(h("div", { class: "result fail" }, e.message)); }
  };
  const st = s.stats || {};
  const decided = (st.approved || 0) + (st.skipped || 0);
  const guidance = h("textarea", { rows: 3 });
  guidance.value = s.guidance ?? s.help;
  const editor = h("details", {}, h("summary", {}, `Guidance${s.guidanceVersions ? ` (version ${s.guidanceVersions})` : ""}`), guidance,
    h("button", { class: "small", onclick: async () => {
      try { await api(`graph/skills/${encodeURIComponent(s.name)}/guidance`, { text: guidance.value }); await showSkills(); }
      catch (e) { out.replaceChildren(h("div", { class: "result fail" }, e.message)); }
    } }, "Save guidance"));
  const buttons = {
    candidate: [["accept", "Keep this skill", "primary"], ["dismiss", "Dismiss", ""]],
    active: s.source === "learned" ? [["disable", "Disable", ""]] : s.namespace ? [["disable", "Hide from chat", ""]] : [],
    disabled: [["enable", "Enable", ""]],
    dismissed: [["accept", "Keep it after all", ""]],
  }[s.status] || [];
  return h("div", { class: "panel" },
    h("div", { class: "spread" },
      h("div", { class: "row" }, h("h3", {}, s.name), s.source === "learned" ? h("span", { class: "pill accent" }, "learned") : null,
        s.status !== "active" ? h("span", { class: "pill " + (s.status === "candidate" ? "warn" : "") }, s.status) : null),
      h("div", { class: "row small" },
        h("span", { class: "pill" }, `proposed ${st.proposed || 0}`),
        h("span", { class: "pill ok" }, `approved ${st.approved || 0}`),
        h("span", { class: "pill" }, `skipped ${st.skipped || 0}`),
        st.failed ? h("span", { class: "pill bad" }, `failed ${st.failed}`) : null,
        decided ? meter(Math.round(s.approvalRate * 100)) : null)),
    h("p", { class: "muted small" }, s.help),
    skillSteps(s),
    s.params?.length ? h("div", { class: "small" }, "Run it: ", h("code", {}, `bibi ${s.name} ${s.params.map((p) => `--${p} …`).join(" ")}`)) : null,
    s.examples?.length ? h("details", {}, h("summary", {}, `Learned from ${s.examples.length} request(s)`), h("ul", { class: "small" }, s.examples.map((e) => h("li", {}, e)))) : null,
    editor,
    h("a", { class: "small", href: `#/graph/${encodeURIComponent(s.name)}` }, "Tune in Graph →"),
    buttons.length ? h("div", { class: "row" }, buttons.map(([verb, label, cls]) => h("button", { class: "small " + cls, onclick: act(verb) }, label))) : null,
    out);
}
