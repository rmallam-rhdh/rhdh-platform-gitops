"use strict";

const { test } = require("node:test");
const assert = require("node:assert/strict");
const http = require("http");
const { spawn } = require("child_process");
const path = require("path");

test("health endpoint returns ok", async () => {
  const child = spawn(process.execPath, [path.join(__dirname, "server.js")], {
    env: { ...process.env, PORT: "3099" },
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
    assert.equal(JSON.parse(body).status, "ok");
  } finally {
    child.kill("SIGTERM");
  }
});
