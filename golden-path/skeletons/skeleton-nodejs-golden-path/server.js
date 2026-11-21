#!/usr/bin/env node
"use strict";

const http = require("http");

const port = Number(process.env.PORT || ${{ values.port }});
const appName = "${{ values.appName }}";

function health() {
  return { status: "ok", app: appName };
}

const page = () => `<!doctype html>
<html><head><meta charset="utf-8"><title>${appName}</title></head>
<body style="font-family:sans-serif;margin:2rem;max-width:42rem">
  <h1>${appName}</h1>
  <p>${{ values.appDescription }}</p>
  <p>Golden path: Jenkins → Sonar → Helm.</p>
</body></html>`;

const server = http.createServer((req, res) => {
  if (req.url === "/health") {
    res.writeHead(200, { "Content-Type": "application/json" });
    res.end(JSON.stringify(health()));
    return;
  }
  res.writeHead(200, { "Content-Type": "text/html; charset=utf-8" });
  res.end(page());
});

if (require.main === module) {
  server.listen(port, "0.0.0.0", () => {
    console.log(`${appName} listening on http://0.0.0.0:${port}`);
  });
}

module.exports = { health, server };
