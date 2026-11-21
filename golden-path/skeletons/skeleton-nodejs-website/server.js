#!/usr/bin/env node
"use strict";

const http = require("http");

const port = Number(process.env.PORT || ${{ values.port }});
const appName = "${{ values.appName }}";
const defaultBackendUrl = "${{ values.backendUrl }}";

function currentBackendUrl() {
  const raw = process.env.BACKEND_URL !== undefined ? process.env.BACKEND_URL : defaultBackendUrl;
  return String(raw || "").replace(/\/$/, "");
}

function health() {
  return {
    status: "ok",
    app: appName,
    type: "website",
    backend: currentBackendUrl() || "not-configured",
  };
}

function fetchBackend(cb) {
  const backendUrl = currentBackendUrl();
  if (!backendUrl) {
    cb(null, { message: "BACKEND_URL not set" });
    return;
  }
  const target = new URL("api", backendUrl.endsWith("/") ? backendUrl : `${backendUrl}/`);
  const lib = target.protocol === "https:" ? require("https") : http;
  const req = lib.get(target, { timeout: 3000 }, (res) => {
    let data = "";
    res.on("data", (c) => {
      data += c;
    });
    res.on("end", () => {
      try {
        cb(null, JSON.parse(data));
      } catch (err) {
        cb(err);
      }
    });
  });
  req.on("error", cb);
  req.on("timeout", () => {
    req.destroy();
    cb(new Error("backend timeout"));
  });
}

const page = (backend) => `<!doctype html>
<html><head><meta charset="utf-8"><title>${appName}</title></head>
<body style="font-family:sans-serif;margin:2rem;max-width:42rem">
  <h1>${appName}</h1>
  <p>${{ values.appDescription }}</p>
  <p>Consumes API <code>${{ values.backendApiName }}</code> via <code>${currentBackendUrl() || "BACKEND_URL"}</code>.</p>
  <pre>${JSON.stringify(backend, null, 2)}</pre>
</body></html>`;

const server = http.createServer((req, res) => {
  if (req.url === "/health") {
    res.writeHead(200, { "Content-Type": "application/json" });
    res.end(JSON.stringify(health()));
    return;
  }
  fetchBackend((err, backend) => {
    const payload = err ? { error: String(err.message || err) } : backend;
    res.writeHead(200, { "Content-Type": "text/html; charset=utf-8" });
    res.end(page(payload));
  });
});

if (require.main === module) {
  server.listen(port, "0.0.0.0", () => {
    console.log(`${appName} listening on http://0.0.0.0:${port} backend=${currentBackendUrl() || "unset"}`);
  });
}

module.exports = { health, fetchBackend, currentBackendUrl, server };
