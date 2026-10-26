// Loaded in <head> so a saved theme applies before first paint (no flash); app.js wires up the switcher.
try { const t = localStorage.getItem("bibi-theme"); if (t) document.documentElement.dataset.theme = t; } catch {}
