// Behaviour metrics: what visitors do, not just how fast pages are.
//
// AppSignal for Browser sends errors and web vitals but has no custom-metrics
// API, so events are batched here and posted to orders-web's /api/rum, which
// turns them into AppSignal custom metrics (storefront_*). That endpoint is an
// ignored action, so these beacons don't count as requests or create traces.

const queue = [];
const FLUSH_MS = 10_000;

export function track(event, data = {}) {
  queue.push({ event, ...data });
  if (queue.length >= 20) flush();
}

function flush() {
  if (!queue.length) return;
  const body = JSON.stringify({ events: queue.splice(0) });
  // sendBeacon survives the tab closing; fetch with keepalive is the fallback.
  if (!navigator.sendBeacon?.("/api/rum", new Blob([body], { type: "application/json" }))) {
    fetch("/api/rum", { method: "POST", body, keepalive: true, headers: { "Content-Type": "application/json" } });
  }
}

setInterval(flush, FLUSH_MS);
document.addEventListener("visibilitychange", () => { if (document.visibilityState === "hidden") flush(); });

// One session per tab per 30 minutes of activity, tagged new or returning.
function startSession() {
  const now = Date.now();
  let last = 0;
  let returning = false;
  try {
    last = Number(sessionStorage.getItem("sf_last_active") || 0);
    returning = localStorage.getItem("sf_seen") === "1";
    localStorage.setItem("sf_seen", "1");
    sessionStorage.setItem("sf_last_active", String(now));
  } catch { /* storage blocked: still count the session */ }
  if (now - last < 30 * 60_000) return;
  const width = window.innerWidth;
  track("session_start", {
    device: width < 640 ? "mobile" : width < 1024 ? "tablet" : "desktop",
    visitor: returning ? "returning" : "new",
  });
}
startSession();

// Rage clicks: three or more clicks on the same element within a second.
let clicks = [];
document.addEventListener("click", (e) => {
  const now = Date.now();
  clicks = clicks.filter((c) => now - c.at < 1000 && c.target === e.target);
  clicks.push({ at: now, target: e.target });
  if (clicks.length === 3) track("rage_click", { route: currentRoute() });
}, true);

let route = "/";
export function setTrackedRoute(template) { route = template; }
export function currentRoute() { return route; }

// Client-perceived API latency: what the visitor waited, including the network.
export async function timedFetch(endpoint, url, options) {
  const started = performance.now();
  try {
    const response = await fetch(url, options);
    track("api_call", { endpoint, status: `${String(response.status)[0]}xx`, ms: Math.round(performance.now() - started) });
    return response;
  } catch (error) {
    track("api_call", { endpoint, status: "network_error", ms: Math.round(performance.now() - started) });
    throw error;
  }
}
