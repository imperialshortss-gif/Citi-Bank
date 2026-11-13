self.addEventListener("install", event => self.skipWaiting());
self.addEventListener("activate", event => event.waitUntil(self.clients.claim()));
self.addEventListener("fetch", event => {
  const request = event.request;
  if (request.method !== "GET" || new URL(request.url).origin !== self.location.origin) return;
  if (request.mode === "navigate") {
    event.respondWith(fetch(request).catch(() => new Response(
      "<!doctype html><html><meta name='viewport' content='width=device-width,initial-scale=1'><title>Citi Online</title><body style='font:16px Arial,sans-serif;padding:32px;color:#17384f'><h2>You're offline</h2><p>Connect to the internet and reopen Citi Online.</p></body></html>",
      { headers: { "Content-Type": "text/html; charset=utf-8" } }
    )));
  }
});