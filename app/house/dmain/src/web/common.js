// What the pages share: how long ago, the banner, and the polling.
const banner = document.getElementById("banner");
const foot = document.getElementById("foot");

function ago(s, unknown) {
  if (s == null) return unknown;
  if (s < 60) return "just now";
  const m = Math.round(s / 60);
  if (m < 60) return m + " min ago";
  const h = Math.floor(m / 60), r = m % 60;
  if (h >= 48) return Math.floor(h / 24) + " days ago";
  return h + " h" + (r ? " " + r + " min" : "") + " ago";
}

function warn(text) {
  banner.textContent = text;
  banner.style.display = text ? "block" : "none";
}

function loggerWarning(logger) {
  return logger === "stopped" ? "The logger isn't running, so this isn't updating."
       : logger === "bridge" ? "The logger can't reach the Hue bridge, so this isn't updating."
       : logger === "silent" ? "Nothing is arriving from the Hue bridge, so this isn't updating."
       : "";
}

// Every source that isn't working, because a page across them all can be partly right.
function sourcesWarning(sources) {
  const words = { "hue-bridge": "Hue", "hub": "hub" };
  const bad = sources.filter((s) => s.state !== "ok").map((s) => words[s.src] || s.src);
  return bad.length ? "Not updating from " + bad.join(" or ") + ", so rooms using it may be out of date." : "";
}

// Fetch `url` and hand it to `render`, now, every 15 s, and whenever the phone
// wakes: one that has been asleep otherwise shows old numbers until the next tick.
function poll(url, render) {
  async function refresh() {
    try {
      const res = await fetch(url, { cache: "no-store" });
      if (!res.ok) throw new Error(res.status);
      const d = await res.json();
      warn(d.sources ? sourcesWarning(d.sources) : loggerWarning(d.logger));
      render(d);
      foot.textContent = "Updated " + new Date().toLocaleTimeString([], { hour: "2-digit", minute: "2-digit" });
    } catch (e) {
      warn("Can't reach dmain on the Pi. Showing the last figures received.");
    }
  }
  refresh();
  setInterval(refresh, 15000);
  document.addEventListener("visibilitychange", () => { if (!document.hidden) refresh(); });
}
