"use strict";

const { test } = require("node:test");
const assert = require("node:assert/strict");
const http = require("http");
const { spawn } = require("child_process");
const path = require("path");
const { health, fetchBackend } = require("./server");

function withBackendUrl(url, fn) {
  const prev = process.env.BACKEND_URL;
  process.env.BACKEND_URL = url;
  return Promise.resolve()
    .then(fn)
    .finally(() => {
      if (prev === undefined) {
        delete process.env.BACKEND_URL;
      } else {
        process.env.BACKEND_URL = prev;
      }
    });
}

function fetchOnce() {
  return new Promise((resolve, reject) => {
    fetchBackend((err, body) => (err ? reject(err) : resolve(body)));
  });
}

test("health() returns website payload", () => {
  const body = health();
  assert.equal(body.status, "ok");
  assert.equal(body.type, "website");
  assert.equal(typeof body.app, "string");
  assert.equal(typeof body.backend, "string");
});

test("fetchBackend reports missing URL", async () => {
  const body = await withBackendUrl("", fetchOnce);
  assert.ok(body.message);
});

test("GET /health returns ok", async () => {
  const child = spawn(process.execPath, [path.join(__dirname, "server.js")], {
    env: { ...process.env, PORT: "3099", BACKEND_URL: "" },
    stdio: ["ignore", "pipe", "pipe"],
  });
  await new Promise((resolve) => setTimeout(resolve, 400));
  try {
    const body = await new Promise((resolve, reject) => {
      http
        .get("http://127.0.0.1:3099/health", (res) => {
          let data = "";
          res.on("data", (c) => (data += c));
          res.on("end", () => resolve(data));
        })
        .on("error", reject);
    });
    const parsed = JSON.parse(body);
    assert.equal(parsed.status, "ok");
    assert.equal(parsed.type, "website");
  } finally {
    child.kill("SIGTERM");
  }
});

test("fetchBackend reads /api from a stub backend", async () => {
  const stub = http.createServer((req, res) => {
    assert.equal(req.url, "/api");
    res.writeHead(200, { "Content-Type": "application/json" });
    res.end(JSON.stringify({ service: "stub", message: "ok" }));
  });
  await new Promise((resolve) => stub.listen(0, "127.0.0.1", resolve));
  try {
    const { port } = stub.address();
    const body = await withBackendUrl(`http://127.0.0.1:${port}`, fetchOnce);
    assert.equal(body.service, "stub");
    assert.equal(body.message, "ok");
  } finally {
    stub.close();
  }
});
