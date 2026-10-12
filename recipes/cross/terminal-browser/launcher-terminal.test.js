// Tests for launcher-terminal.js: a fake launcherctl HTTP server and a fake /proc.
// Run: node --test recipes/cross/terminal-browser/
"use strict";

const assert = require("node:assert/strict");
const { spawnSync } = require("node:child_process");
const fs = require("node:fs");
const http = require("node:http");
const net = require("node:net");
const os = require("node:os");
const path = require("node:path");
const { test } = require("node:test");

const { launcherTerminal, serve, closingCommand, PROTOCOL } = require("./launcher-terminal.js");

const BASE = ["getCurrentPane", "split", "listPanes", "sendText", "focusPane"];

// A launcherctl stand-in: routes is {"GET /v1/panes": (body) => [status, json]}.
async function fakeLauncher(routes, token = "secret") {
  const requests = [];
  const server = http.createServer((request, response) => {
    let raw = "";
    request.on("data", (chunk) => (raw += chunk));
    request.on("end", () => {
      const body = raw ? JSON.parse(raw) : null;
      requests.push({ method: request.method, url: request.url, headers: request.headers, body });
      const route = routes[`${request.method} ${request.url}`];
      const [status, json] = route ? route(body) : [404, { ok: false, error: "not_found", message: "no route" }];
      response.writeHead(status, { "Content-Type": "application/json" });
      response.end(JSON.stringify(json));
    });
  });
  await new Promise((resolve) => server.listen(0, "127.0.0.1", resolve));
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "tb-launcherctl-"));
  fs.writeFileSync(path.join(dir, "endpoint"), `http://127.0.0.1:${server.address().port}\nhttp://127.0.0.1:${server.address().port}/v1\n`);
  fs.writeFileSync(path.join(dir, "token"), token === null ? "" : `${token}\n`);
  return { dir, requests, close: () => new Promise((resolve) => server.close(resolve)) };
}

// A /proc stand-in: {pid: {ppid, env: {...}, tty}}.
function fakeProc(processes) {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), "tb-proc-"));
  for (const [pid, info] of Object.entries(processes)) {
    const dir = path.join(root, pid);
    fs.mkdirSync(path.join(dir, "fd"), { recursive: true });
    fs.writeFileSync(path.join(dir, "stat"), `${pid} (a (weird) name) S ${info.ppid ?? 1} ${pid} ${pid} 0 -1 4194560\n`);
    fs.writeFileSync(
      path.join(dir, "environ"),
      Object.entries(info.env ?? {}).map(([key, value]) => `${key}=${value}\0`).join(""),
    );
    fs.symlinkSync(info.tty ?? "/dev/null", path.join(dir, "fd", "0"));
  }
  return root;
}

// Two windows: w1 holds the agent's pane p1 (shell 100) and p3 (shell 102), w2 holds p2 (shell 101).
function listing(features) {
  const body = {
    windows: [
      {
        index: 0, id: "w1", name: "1", current: true, focusedPane: "p1",
        panes: [
          { id: "p1", pid: 100, running: true, geometry: { left: 0, top: 0, columns: 40, rows: 24 } },
          { id: "p3", pid: 102, running: true, geometry: { left: 41, top: 0, columns: 39, rows: 24 } },
        ],
      },
      { index: 1, id: "w2", name: "2", current: false, focusedPane: "p2", panes: [{ id: "p2", pid: 101, running: true }] },
    ],
    activePane: "p1",
    layout: "dwindle",
  };
  if (features) body.features = features;
  return () => [200, body];
}

const request = (method, params, caller = { pid: 1, cwd: "/" }) =>
  JSON.stringify({ id: "r1", method, params, caller });

test("hello offers neighbor only when the launcher reports geometry", async () => {
  const old = await fakeLauncher({ "GET /v1/panes": listing(null) });
  const fresh = await fakeLauncher({ "GET /v1/panes": listing(["placement", "resize", "geometry", "windows"]) });
  const down = await fakeLauncher({});
  try {
    const hello = request("hello", { protocol: PROTOCOL });
    assert.deepEqual(await launcherTerminal({ dir: old.dir })(hello), {
      id: "r1",
      result: { name: "termux-launcher", methods: BASE },
    });
    assert.deepEqual((await launcherTerminal({ dir: fresh.dir })(hello)).result.methods, [...BASE, "neighbor"]);
    assert.deepEqual((await launcherTerminal({ dir: down.dir })(hello)).result.methods, BASE);
    assert.match((await launcherTerminal({ dir: old.dir })(request("hello", { protocol: 2 }))).error.message, /protocol 1/);
  } finally {
    await Promise.all([old.close(), fresh.close(), down.close()]);
  }
});

test("getCurrentPane walks the caller's parents to TERMUX_LAUNCHER_PANE or a pane's shell", async () => {
  const launcher = await fakeLauncher({ "GET /v1/panes": listing(null) });
  const procRoot = fakeProc({
    100: { ppid: 1, tty: "/dev/pts/7" },
    101: { ppid: 1, tty: "/dev/pts/8" },
    // an agent's tool shell in w2's pane: node -> sh -> terminal-browser, no tty of its own
    300: { ppid: 200, env: { HOME: "/home" } },
    200: { ppid: 150, env: { TERMUX_LAUNCHER_PANE: "p2" } },
    // a process under p1's shell, without the variable
    400: { ppid: 100 },
    // the browser daemon: started from p2, so its environment names p2
    500: { ppid: 1, env: { TERMUX_LAUNCHER_PANE: "p2" } },
    // nothing to do with the launcher
    600: { ppid: 1 },
  });
  try {
    const answer = launcherTerminal({ dir: launcher.dir, procRoot });
    const current = async (tty, pid) =>
      (await answer(request("getCurrentPane", { tty, cwd: "/" }, { pid, cwd: "/" }))).result.pane;
    assert.deepEqual(await current(null, 300), { id: "p2", tab: "w2" });
    assert.deepEqual(await current(null, 400), { id: "p1", tab: "w1" });
    assert.deepEqual(await current("/dev/pts/7", 500), { id: "p1", tab: "w1" }, "the tty wins over the caller's environment");
    assert.deepEqual(await current("/dev/pts/99", 300), { id: "p2", tab: "w2" }, "an unknown tty falls back to the walk");
    assert.equal(await current(null, 600), null);
    assert.equal(launcher.requests.filter((r) => r.url === "/v1/panes").length, 1, "the listing is cached");
  } finally {
    await launcher.close();
  }
});

test("split places the pane beside the caller when the launcher has placement", async () => {
  const opened = () => [200, { ok: true, pane: { id: "p9" } }];
  const placed = await fakeLauncher({ "GET /v1/panes": listing(["placement", "geometry"]), "POST /v1/panes": opened });
  const legacy = await fakeLauncher({ "GET /v1/panes": listing(null), "POST /v1/panes": opened });
  try {
    const params = {
      from: { id: "p1", tab: "w1" },
      direction: "right",
      command: ["/app/bin/terminal-browser", "open", "https://example.com", "--split-dir=right"],
      size: 0.95,
      tty: "/dev/pts/7",
    };
    const caller = { pid: 300, cwd: "/work" };
    const common = {
      command: closingCommand(params.command),
      focus: false,
      title: "terminal-browser",
      tag: "terminal-browser",
      cwd: "/work",
    };
    assert.deepEqual(await launcherTerminal({ dir: placed.dir })(request("split", params, caller)), { id: "r1", result: {} });
    assert.deepEqual(placed.requests.find((r) => r.method === "POST").body, {
      ...common,
      from: "p1",
      direction: "right",
      size: 0.9,
    });
    await launcherTerminal({ dir: legacy.dir })(request("split", { ...params, size: null }, caller));
    assert.deepEqual(legacy.requests.find((r) => r.method === "POST").body, common);
    assert.deepEqual(closingCommand(["tb", "open"]).slice(0, 2), ["sh", "-c"]);
    assert.deepEqual(closingCommand(["tb", "open"]).slice(3), ["terminal-browser", "tb", "open"]);
  } finally {
    await Promise.all([placed.close(), legacy.close()]);
  }
});

test("the launcher's refusals become sentences", async () => {
  const disabled = () => [403, {
    ok: false,
    error: "panes_api_disabled",
    message: "Pane access for scripts is switched off in Settings > Terminal & Status > Sessions and panes",
  }];
  const off = await fakeLauncher({ "GET /v1/panes": disabled, "POST /v1/panes": disabled });
  const enveloped = await fakeLauncher({
    "GET /v1/panes": listing(null),
    "POST /v1/panes": () => [409, { ok: false, code: "splits_disabled", message: "Split panes are disabled", error: { code: "splits_disabled", message: "Split panes are disabled" } }],
    "POST /v1/panes/p1/write": () => [403, { ok: false, error: "not_owned", message: "not yours" }],
    "POST /v1/panes/p7/focus": () => [418, { ok: false, error: "teapot", message: "short and stout" }],
  });
  try {
    const split = request("split", { from: { id: "p1", tab: "w1" }, direction: "right", command: ["tb"], size: null, tty: null });
    assert.match((await launcherTerminal({ dir: off.dir })(split)).error.message, /turn on "Let programs and agents control panes"/);
    const answer = launcherTerminal({ dir: enveloped.dir });
    assert.match((await answer(split)).error.message, /compatibility mode/);
    assert.match((await answer(request("sendText", { pane: "p1", text: "hi" }))).error.message, /only lets programs type into panes they opened/);
    assert.equal((await answer(request("focusPane", { pane: "p7" }))).error.message, "the launcher answered HTTP 418 teapot: short and stout");
    assert.match((await answer(request("split", { command: [] }))).error.message, /needs a command/);
    assert.match((await answer(request("nope", {}))).error.message, /has no nope/);
  } finally {
    await Promise.all([off.close(), enveloped.close()]);
  }
});

test("the token goes in a bearer header, and an empty token file sends none", async () => {
  const withToken = await fakeLauncher({ "GET /v1/panes": listing(null) });
  const without = await fakeLauncher({ "GET /v1/panes": listing(null) }, null);
  try {
    await launcherTerminal({ dir: withToken.dir })(request("listPanes", { tty: null }));
    await launcherTerminal({ dir: without.dir })(request("listPanes", { tty: null }));
    assert.equal(withToken.requests[0].headers.authorization, "Bearer secret");
    assert.equal(without.requests[0].headers.authorization, undefined);
  } finally {
    await Promise.all([withToken.close(), without.close()]);
  }
  const nowhere = fs.mkdtempSync(path.join(os.tmpdir(), "tb-launcherctl-"));
  assert.match((await launcherTerminal({ dir: nowhere })(request("listPanes", {}))).error.message, /endpoint is missing/);
});

test("listPanes, neighbor, sendText and focusPane", async () => {
  const launcher = await fakeLauncher({
    "GET /v1/panes": listing(["geometry"]),
    "POST /v1/panes/p3/write": () => [200, { ok: true }],
    "POST /v1/panes/p3/focus": () => [200, { ok: true }],
  });
  const procRoot = fakeProc({ 100: { tty: "/dev/pts/7" }, 101: {}, 102: { tty: "/dev/pts/9" } });
  try {
    const answer = launcherTerminal({ dir: launcher.dir, procRoot });
    assert.deepEqual((await answer(request("listPanes", { tty: null }))).result.panes, [
      { id: "p1", tab: "w1", tty: "/dev/pts/7", command: null },
      { id: "p3", tab: "w1", tty: "/dev/pts/9", command: null },
      { id: "p2", tab: "w2", tty: null, command: null },
    ]);
    const beside = async (id, direction) =>
      (await answer(request("neighbor", { from: { id, tab: "w1" }, direction }))).result.pane;
    assert.deepEqual(await beside("p1", "right"), { id: "p3", tab: "w1" });
    assert.deepEqual(await beside("p3", "left"), { id: "p1", tab: "w1" });
    assert.equal(await beside("p1", "down"), null);
    assert.equal(await beside("p2", "left"), null, "a pane without geometry has no neighbours");
    assert.deepEqual(await answer(request("sendText", { pane: "p3", text: "> look\n\n" })), { id: "r1", result: {} });
    assert.deepEqual(await answer(request("focusPane", { pane: "p3" })), { id: "r1", result: {} });
    const posts = launcher.requests.filter((r) => r.method === "POST");
    assert.deepEqual(posts.map((r) => [r.url, r.body]), [
      ["/v1/panes/p3/write", { text: "> look\n\n" }],
      ["/v1/panes/p3/focus", {}],
    ]);
  } finally {
    await launcher.close();
  }
});

// The client's side of the wire, as shared/src/terminal-socket.ts speaks it.
function ask(socketPath, line) {
  return new Promise((resolve, reject) => {
    const connection = net.connect(socketPath);
    let buffer = "";
    connection.setEncoding("utf8");
    connection.on("error", reject);
    connection.on("data", (chunk) => {
      buffer += chunk;
      const newline = buffer.indexOf("\n");
      if (newline < 0) return;
      connection.destroy();
      resolve(JSON.parse(buffer.slice(0, newline)));
    });
    connection.on("connect", () => connection.write(`${line}\n`));
  });
}

test("serve answers on the socket, replaces a dead one, and leaves a live one alone", async () => {
  const socketPath = path.join(fs.mkdtempSync(path.join(os.tmpdir(), "tb-sock-")), "t.sock");
  // A socket file nobody listens on, as a killed server leaves it.
  spawnSync(process.execPath, [
    "-e",
    `require("node:net").createServer().listen(${JSON.stringify(socketPath)}, () => process.kill(process.pid, "SIGKILL"))`,
  ]);
  assert.ok(fs.existsSync(socketPath));

  const answer = async (line) => ({ id: JSON.parse(line).id, result: { echoed: JSON.parse(line).method } });
  const server = await serve(socketPath, answer);
  try {
    assert.notEqual(server, null);
    assert.deepEqual(await ask(socketPath, request("hello", { protocol: 1 })), { id: "r1", result: { echoed: "hello" } });
    assert.equal(await serve(socketPath, answer), null, "a second server steps aside");
    assert.equal((fs.statSync(socketPath).mode & 0o777).toString(8), "600");
  } finally {
    await new Promise((resolve) => server.close(resolve));
  }
  assert.equal(fs.existsSync(socketPath), false, "closing removes the socket file");
});
