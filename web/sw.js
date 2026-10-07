// App shell cache: the PWA opens instantly; live data always comes from the socket.
const CACHE = "elio-v5";
// Audio of inbox messages lives in its own cache (written by the page): survives shell updates.
const KEEP = ["elio-msg-audio"];
const SHELL = ["./", "index.html", "report.html", "manifest.webmanifest", "icon-192.png", "icon-512.png", "logo.svg"];

self.addEventListener("install", e => e.waitUntil(caches.open(CACHE).then(c => c.addAll(SHELL)).then(() => self.skipWaiting())));
self.addEventListener("activate", e => e.waitUntil(
  caches.keys().then(keys => Promise.all(keys.filter(k => k !== CACHE && !KEEP.includes(k)).map(k => caches.delete(k)))).then(() => self.clients.claim())));
self.addEventListener("fetch", e => {
  const url = new URL(e.request.url);
  if (e.request.method !== "GET" || url.origin !== location.origin) return;
  const p = url.pathname;
  // Live endpoints are never cached.
  if (p.includes("/tts") || p.endsWith("/stt") || p.endsWith("/ws") || p.includes("/push/") || p.includes("/api/") || p.includes("/msg-audio/")) return;
  // The paired manifest carries the token: don't keep it around.
  if (p.endsWith("manifest.webmanifest") && url.search) return;
  // Network first (fresh UI), cache as offline fallback.
  // Reports differ only by ?id=: one cached copy of the page is enough (the data comes from the API).
  const key = p.endsWith("report.html") ? new Request(new URL("report.html", self.registration.scope)) : e.request;
  e.respondWith(fetch(e.request).then(r => {
    if (r.ok) { const copy = r.clone(); caches.open(CACHE).then(c => c.put(key, copy)); }
    return r;
  }).catch(() => caches.match(key).then(hit => hit || (e.request.mode === "navigate" ? caches.match("index.html") : Response.error()))));
});

// ---------- Tiny key-value store shared with the page (token, badge count) ----------
function kv(mode, fn) {
  return new Promise((res, rej) => {
    const o = indexedDB.open("elio", 1);
    o.onupgradeneeded = () => o.result.createObjectStore("kv");
    o.onerror = () => rej(o.error);
    o.onsuccess = () => {
      const db = o.result, tx = db.transaction("kv", mode), r = fn(tx.objectStore("kv"));
      tx.oncomplete = () => { db.close(); res(r && r.result); };
      tx.onerror = () => { db.close(); rej(tx.error); };
    };
  });
}
const kvGet = k => kv("readonly", s => s.get(k)).catch(() => undefined);
const kvSet = (k, v) => kv("readwrite", s => s.put(v, k)).catch(() => {});

// The home-screen icon shows how many messages wait (support varies on iOS: every call is guarded).
async function bumpBadge(unread) {
  try {
    const n = typeof unread === "number" ? unread : ((await kvGet("badge")) || 0) + 1;
    await kvSet("badge", n);
    if (self.navigator && self.navigator.setAppBadge) await self.navigator.setAppBadge(n);
  } catch {}
}

// Stops the repeated pushes of an urgent "call" (same as the page does when it comes to the foreground).
async function ack() {
  try {
    const token = await kvGet("token");
    if (token) await fetch(new URL("api/ack", self.registration.scope), { method: "POST", headers: { "X-Elio-Token": token } });
  } catch {}
}

// ---------- Notifications from Elio (Web Push from the Mac) ----------
// Payload: {title, body, tag, urgency: very-low|low|normal|high, url}. A notification is always shown:
// iOS revokes the subscription of apps that receive pushes without showing anything.
self.addEventListener("push", e => {
  let d = {};
  try { d = e.data ? e.data.json() : {}; } catch { d = { title: "Elio", body: e.data ? e.data.text() : "" }; }
  const tag = d.tag || "elio";
  const opts = {
    body: d.body || "", tag, renotify: true, icon: "icon-192.png", badge: "icon-192.png",
    data: { url: d.url || "./", tag }, timestamp: Date.now(),
  };
  if (d.urgency === "high") { opts.requireInteraction = true; opts.vibrate = [250, 120, 250, 120, 500]; }
  if (d.urgency === "very-low") opts.silent = true;
  e.waitUntil(Promise.all([
    self.registration.showNotification(d.title || "Elio", opts),
    tag === "messages" ? bumpBadge(d.unread) : null,
  ]));
});

self.addEventListener("notificationclick", e => {
  e.notification.close();
  const data = e.notification.data || {};
  const tag = data.tag || e.notification.tag || "";
  const url = new URL(data.url || "./", self.registration.scope).href;
  e.waitUntil((async () => {
    if (tag.startsWith("call-")) await ack();
    const list = await clients.matchAll({ type: "window", includeUncontrolled: true });
    for (const c of list) {
      if (!("focus" in c)) continue;
      try { await c.focus(); } catch {}
      c.postMessage({ type: "open", url });
      return;
    }
    if (clients.openWindow) await clients.openWindow(url);
  })());
});

// The browser rotated the subscription: hand the new one to the Mac right away (the page also re-checks at every launch).
self.addEventListener("pushsubscriptionchange", e => {
  e.waitUntil((async () => {
    try {
      const token = await kvGet("token");
      const { key } = await (await fetch(new URL("push/key", self.registration.scope))).json();
      const raw = atob(key.replace(/-/g, "+").replace(/_/g, "/") + "=".repeat((4 - key.length % 4) % 4));
      const sub = await self.registration.pushManager.subscribe({ userVisibleOnly: true, applicationServerKey: Uint8Array.from(raw, c => c.charCodeAt(0)) });
      if (token) await fetch(new URL("push/subscribe", self.registration.scope), {
        method: "POST", headers: { "Content-Type": "application/json", "X-Elio-Token": token }, body: JSON.stringify(sub.toJSON()) });
    } catch {}
  })());
});
