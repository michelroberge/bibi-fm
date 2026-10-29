// Background layer: the mascot's head as ASCII art, cut by the right edge of the screen so two thirds of
// it show, its eyes pulsing. Self-contained: it only draws into #backdrop (styled in style.css),
// so swapping this file for another script that fills that element replaces the whole layer.
(() => {
  const el = document.getElementById("backdrop");
  if (!el) return;
  const still = matchMedia("(prefers-reduced-motion: reduce)").matches;
  const RAMP = " .:-=+*#%@";
  const PERIOD = 4000; // ms per pulse

  const norm = ([x, y, z]) => { const l = Math.hypot(x, y, z); return [x / l, y / l, z / l]; };
  const dot = (a, b) => a[0] * b[0] + a[1] * b[1] + a[2] * b[2];
  const LIGHT = norm([-0.5, 0.6, 0.7]); // key light from the upper left, as on the logo
  const EYES = [norm([-0.4, 0.14, 0.9]), norm([0.4, 0.14, 0.9])];
  const TIP = [-0.2, 1.45]; // antenna tip in screen units of R, leaning into view

  let cols = 0, rows = 0, cw = 1, ch = 1;
  const measure = () => {
    const probe = document.createElement("span");
    probe.textContent = "M".repeat(10);
    el.textContent = ""; el.append(probe);
    const box = probe.getBoundingClientRect();
    cw = box.width / 10; ch = parseFloat(getComputedStyle(el).lineHeight) || box.height;
    cols = Math.ceil(el.clientWidth / cw); rows = Math.ceil(el.clientHeight / ch);
  };

  // Distance from point p to segment ab, all 2D.
  const toSegment = (px, py, ax, ay, bx, by) => {
    const dx = bx - ax, dy = by - ay, k = Math.max(0, Math.min(1, ((px - ax) * dx + (py - ay) * dy) / (dx * dx + dy * dy)));
    return Math.hypot(px - ax - k * dx, py - ay - k * dy);
  };

  const draw = (now) => {
    const pulse = still ? 1 : 0.5 + 0.5 * Math.sin(now / PERIOD * 2 * Math.PI);
    const yaw = still ? 0 : 0.06 * Math.sin(now / (PERIOD * 3.1) * 2 * Math.PI); // a slow drift so it reads as alive
    const [cy, sy] = [Math.cos(yaw), Math.sin(yaw)];
    const W = el.clientWidth, H = el.clientHeight;
    // Centre a third of a radius inside the right edge so two thirds of the face show; low to fit the antenna.
    const R = Math.min(W * 0.72, H * 0.36), ox = W - R / 3, oy = H * 0.58;
    const glow = 0.45 + 0.55 * pulse;
    let out = "";
    for (let r = 0; r < rows; r++) {
      for (let c = 0; c < cols; c++) {
        const x = ((c + 0.5) * cw - ox) / R, y = (oy - (r + 0.5) * ch) / R, d2 = x * x + y * y;
        let b = 0;
        if (d2 <= 1) {
          const n = [x, y, Math.sqrt(1 - d2)];
          const h = [cy * n[0] + sy * n[2], n[1], -sy * n[0] + cy * n[2]]; // undo the yaw: head-space normal
          const eye = Math.min(...EYES.map((e) => Math.acos(Math.min(1, dot(h, e))))); // angle to the nearest eye
          b = 0.08 + 0.55 * Math.max(0, dot(n, LIGHT)) + 0.5 * glow * Math.exp(-((eye / 0.45) ** 2)); // shading + light spill
          if (Math.abs(h[1] + 0.34) < 0.025 && h[2] > 0) b *= 0.35; // panel seam
          if (eye < 0.27) b = 0.05; // socket
          if (eye < 0.2) b = 0.6 + 0.4 * glow * (1 - eye / 0.2); // the bulb
        } else {
          const ex = -cy * 1.04, ew = 0.2 * Math.max(Math.abs(ex), 0.4); // ear bolt, squashed as the head turns
          if (((x - ex) / ew) ** 2 + (y / 0.24) ** 2 < 1) b = 0.35;
          const stalk = toSegment(x, y, 0, 1, TIP[0] + sy * 0.2, TIP[1]);
          if (y > 0.98 && stalk < 0.025) b = 0.4;
          if (Math.hypot(x - TIP[0] - sy * 0.2, y - TIP[1]) < 0.07) b = 0.3 + 0.7 * pulse; // beacon
        }
        out += RAMP[Math.max(0, Math.min(RAMP.length - 1, Math.round(b * (RAMP.length - 1))))];
      }
      out += "\n";
    }
    el.textContent = out;
  };

  let timer = 0;
  const start = () => {
    clearInterval(timer);
    measure(); draw(performance.now());
    if (!still) timer = setInterval(() => { if (!document.hidden) draw(performance.now()); }, 80);
  };
  let resize = 0;
  addEventListener("resize", () => { clearTimeout(resize); resize = setTimeout(start, 150); });
  start();
})();
