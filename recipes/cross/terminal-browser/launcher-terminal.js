// launcher-terminal.js — Termux Launcher as a terminal terminal-browser can open panes in.
//
// Upstream's CLI and browser know kitty, tmux, wezterm, herdr and a few more by their environment;
// anything else gets "unrecognized terminal", so `terminal-browser open --split right <url>`
// (what upstream's agent skill tells coding agents to run) fails in the launcher. Upstream's way
// in for another terminal is shared/src/terminal-socket.ts: with TERMINAL_BROWSER_TERMINAL_SOCKET
// set, both the CLI and every browser session ask a unix socket instead of detecting. This is
// that socket's server, mapping each request onto the launcher's pane API (launcherctl's HTTP
// server, ~/.launcherctl/endpoint and token):
//
//   request, one JSON line per connection    {id, method, params, caller: {pid, cwd}}
//   reply                                    {id, result} or {id, error: {message}}
//
//   hello            {name, methods}; neighbor only when the launcher reports pane geometry
//   getCurrentPane   the launcher pane whose shell owns params.tty, else the nearest
//                    TERMUX_LAUNCHER_PANE (or pane shell) among caller.pid and its parents
//   split            POST /v1/panes, beside params.from when the launcher has "placement",
//                    else wherever the launcher's layout puts a new pane
//   listPanes        GET /v1/panes; tty from the pane shell's /proc entry, command left to
//                    upstream (it fills it in from ps by tty)
//   neighbor         the adjacent pane, from the launcher's pane geometry
//   sendText         POST /v1/panes/{id}/write (the launcher allows it on panes the API opened)
//   focusPane        POST /v1/panes/{id}/focus
//
// A pane's "tab" is the launcher window holding it, which is what `terminal-browser ls` and
// `action` mean by "the browser in this terminal tab".
//
// tty comes first in getCurrentPane because the browser asks from its daemon, one process for all
// browsers, whose own environment names whichever pane started it; its tty is the browser's own.
//
// No dependencies: it runs on Termux's electron42 with ELECTRON_RUN_AS_NODE=1 (Node 24).
// Usage: launcher-terminal.js <socket path>. It exits after 15 minutes without a request.
"use strict";

const fs = require("node:fs");
const http = require("node:http");
const net = require("node:net");
const os = require("node:os");
const path = require("node:path");

const NAME = "termux-launcher";
const PROTOCOL = 1;
const IDLE_MS = 15 * 60 * 1000;
const LISTING_TTL_MS = 500;
// The client gives up after 8 s; answer before that with the launcher's own failure.
const HTTP_TIMEOUT_MS = 6000;
const BASE_METHODS = ["getCurrentPane", "split", "listPanes", "sendText", "focusPane"];
const DIRECTIONS = ["right", "left", "down", "up"];

class Refusal extends Error {}

// A human sentence for an error answer of the launcher's API. Its bodies are
// {ok: false, error: "<code>", message} or, through the OpenAI envelope,
// {code, message, error: {code, message}}.
function refusal(status, body) {
  const nested = body && typeof body.error === "object" && body.error !== null ? body.error : null;
  const code = String((nested ? nested.code : body && body.error) || (body && (body.code || body.error_code)) || "");
  const said = String((body && body.message) || (nested && nested.message) || "");
  switch (code) {
    case "panes_api_disabled":
      return "the launcher does not let programs open or drive panes: turn on \"Let programs and agents control panes\" in the launcher's settings";
    case "splits_disabled":
      return "the launcher cannot open a pane while its compatibility mode is on (split panes are off)";
    case "activity_not_running":
      return "Termux Launcher is not running: open it and try again";
    case "not_owned":
      return "the launcher only lets programs type into panes they opened themselves, and this pane was opened by hand";
    case "pane_not_found":
      return `the launcher has no such pane${said ? ` (${said})` : ""}`;
    case "pane_not_tiled":
      return "the launcher cannot open a pane beside a floating pane";
    case "pane_open_failed":
      return `the launcher could not open a pane${said ? `: ${said}` : ""}`;
    case "unauthorized":
      return "the launcher refused the token in ~/.launcherctl/token (it changes when the launcher restarts; try again)";
    default:
      if (status === 401) return refusal(status, { error: "unauthorized" });
      return `the launcher answered HTTP ${status}${code ? ` ${code}` : ""}${said ? `: ${said}` : ""}`;
  }
}

// --- the launcher's API ---------------------------------------------------------------------------

function launcherApi({ dir, timeout = HTTP_TIMEOUT_MS }) {
  function connection() {
    let base;
    try {
      base = fs.readFileSync(path.join(dir, "endpoint"), "utf8").split("\n")[0].trim();
    } catch {
      throw new Refusal(`${path.join(dir, "endpoint")} is missing: is Termux Launcher running?`);
    }
    let token = "";
    try {
      token = fs.readFileSync(path.join(dir, "token"), "utf8").trim();
    } catch {}
    return { base, token };
  }

  return function call(method, route, body) {
    const { base, token } = connection();
    const url = new URL(route, base);
    const payload = body === undefined ? null : Buffer.from(JSON.stringify(body));
    const headers = { Accept: "application/json" };
    if (token) headers.Authorization = `Bearer ${token}`;
    if (payload) {
      headers["Content-Type"] = "application/json";
      headers["Content-Length"] = String(payload.length);
    }
    return new Promise((resolve, reject) => {
      const request = http.request(
        { hostname: url.hostname, port: url.port, path: url.pathname + url.search, method, headers },
        (response) => {
          const chunks = [];
          response.on("data", (chunk) => chunks.push(chunk));
          response.on("end", () => {
            let parsed = null;
            try {
              parsed = JSON.parse(Buffer.concat(chunks).toString("utf8"));
            } catch {}
            const status = response.statusCode || 0;
            if (status >= 400 || (parsed && parsed.ok === false)) {
              reject(new Refusal(refusal(status, parsed)));
            } else if (parsed === null) {
              reject(new Refusal(`the launcher answered ${method} ${route} with something that is not json`));
            } else {
              resolve(parsed);
            }
          });
        },
      );
      request.setTimeout(timeout, () => request.destroy(new Error("timeout")));
      request.on("error", (error) =>
        reject(
          new Refusal(
            error.message === "timeout"
              ? `the launcher did not answer ${method} ${route} within ${timeout / 1000}s`
              : `cannot reach the launcher at ${base} (${error.code || error.message}): is Termux Launcher running?`,
          ),
        ),
      );
      if (payload) request.write(payload);
      request.end();
    });
  };
}

// --- /proc ----------------------------------------------------------------------------------------

function procfs(root) {
  // pid, ppid and tty_nr from /proc/<pid>/stat; the name in parentheses may hold anything.
  function stat(pid) {
    try {
      const text = fs.readFileSync(`${root}/${pid}/stat`, "utf8");
      const fields = text.slice(text.lastIndexOf(")") + 2).split(" ");
      return { ppid: Number(fields[1]), ttyNr: Number(fields[4]) };
    } catch {
      return null;
    }
  }
  return {
    parent(pid) {
      const found = stat(pid);
      return found && Number.isInteger(found.ppid) ? found.ppid : 0;
    },
    environ(pid, name) {
      try {
        const prefix = `${name}=`;
        const entry = fs
          .readFileSync(`${root}/${pid}/environ`, "utf8")
          .split("\0")
          .find((line) => line.startsWith(prefix));
        return entry === undefined ? null : entry.slice(prefix.length);
      } catch {
        return null;
      }
    },
    tty(pid) {
      for (const fd of [0, 1, 2]) {
        try {
          const target = fs.readlinkSync(`${root}/${pid}/fd/${fd}`);
          if (target.startsWith("/dev/") && target !== "/dev/null") return target;
        } catch {}
      }
      return null;
    },
    // Whether pid's controlling terminal is the device at tty: by the file its stdio points at,
    // else by device number, for when the fd links cannot be read.
    onTty(pid, tty) {
      if (this.tty(pid) === tty) return true;
      const found = stat(pid);
      if (!found || !found.ttyNr) return false;
      try {
        return fs.statSync(tty).rdev === found.ttyNr;
      } catch {
        return false;
      }
    },
  };
}

// --- the protocol ---------------------------------------------------------------------------------

function paneRect(pane) {
  const g = pane.geometry;
  if (!g || ![g.left, g.top, g.columns, g.rows].every(Number.isFinite)) return null;
  return { id: pane.id, left: g.left, top: g.top, right: g.left + g.columns - 1, bottom: g.top + g.rows - 1 };
}

// Upstream's adjacentPane (pixel/src/terminal/shared.ts): the pane across the gap on that side
// that shares the most of the edge. Panes are a separator column or row apart.
function adjacent(from, candidates, direction, gap = 2) {
  const touches = (c) => {
    switch (direction) {
      case "right": return c.left > from.right && c.left <= from.right + gap;
      case "left": return c.right < from.left && c.right >= from.left - gap;
      case "down": return c.top > from.bottom && c.top <= from.bottom + gap;
      case "up": return c.bottom < from.top && c.bottom >= from.top - gap;
    }
    return false;
  };
  const overlap = (c) =>
    direction === "right" || direction === "left"
      ? Math.min(c.bottom, from.bottom) - Math.max(c.top, from.top)
      : Math.min(c.right, from.right) - Math.max(c.left, from.left);
  let best = null;
  for (const c of candidates) {
    if (c.id === from.id || !touches(c) || overlap(c) < 0) continue;
    if (!best || overlap(c) > overlap(best)) best = c;
  }
  return best;
}

// The pane's command, run so that a browser closed normally takes its pane with it: the launcher
// runs a pane's command in a login shell that stays behind, and closing the pane (an API-opened
// one is the API's to close) is how kitty and the others behave. A failure keeps the pane, and
// with it the error.
function closingCommand(argv) {
  const script =
    'if "$@"; then [ -n "$TERMUX_LAUNCHER_PANE" ] && command -v launcherctl >/dev/null 2>&1 &&' +
    ' launcherctl pane close "$TERMUX_LAUNCHER_PANE" >/dev/null 2>&1; fi';
  return ["sh", "-c", script, "terminal-browser", ...argv];
}

function launcherTerminal({ dir, procRoot = "/proc", now = Date.now, timeout } = {}) {
  const call = launcherApi({ dir, timeout });
  const proc = procfs(procRoot);
  let cached = null;

  // GET /v1/panes, flattened: every pane with the id of the window (the "tab") that holds it.
  function listing() {
    if (cached && now() - cached.at < LISTING_TTL_MS) return cached.promise;
    const promise = call("GET", "/v1/panes").then((body) => {
      const panes = [];
      for (const window of Array.isArray(body.windows) ? body.windows : []) {
        const tab = String(window.id ?? window.index);
        for (const pane of Array.isArray(window.panes) ? window.panes : []) {
          if (pane && pane.id != null) panes.push({ ...pane, id: String(pane.id), tab });
        }
      }
      return { panes, features: Array.isArray(body.features) ? body.features : [] };
    });
    cached = { at: now(), promise };
    promise.catch(() => {
      if (cached && cached.promise === promise) cached = null;
    });
    return promise;
  }

  async function currentPane(params, caller) {
    const { panes } = await listing();
    const tty = typeof params.tty === "string" && params.tty ? params.tty : null;
    if (tty) {
      const owner = panes.find((pane) => Number.isInteger(pane.pid) && proc.onTty(pane.pid, tty));
      if (owner) return owner;
    }
    let pid = caller && Number.isInteger(caller.pid) ? caller.pid : 0;
    for (let hops = 0; hops < 64 && pid > 1; hops++) {
      const shell = panes.find((pane) => pane.pid === pid);
      if (shell) return shell;
      const named = proc.environ(pid, "TERMUX_LAUNCHER_PANE");
      const pane = named && panes.find((candidate) => candidate.id === named);
      if (pane) return pane;
      pid = proc.parent(pid);
    }
    return null;
  }

  const brief = (pane) => (pane ? { id: pane.id, tab: pane.tab } : null);

  const methods = {
    async hello() {
      const features = await listing().then(
        (found) => found.features,
        () => [],
      );
      return { name: NAME, methods: features.includes("geometry") ? [...BASE_METHODS, "neighbor"] : BASE_METHODS };
    },

    async getCurrentPane(params, caller) {
      return { pane: brief(await currentPane(params, caller)) };
    },

    async split(params, caller) {
      const command = params.command;
      if (!Array.isArray(command) || command.length === 0 || !command.every((arg) => typeof arg === "string")) {
        throw new Refusal("split needs a command (an array of strings)");
      }
      const { features } = await listing();
      const body = {
        command: closingCommand(command),
        focus: false,
        title: "terminal-browser",
        tag: "terminal-browser",
      };
      if (caller && typeof caller.cwd === "string" && caller.cwd) body.cwd = caller.cwd;
      if (features.includes("placement")) {
        if (params.from && params.from.id != null) body.from = String(params.from.id);
        if (DIRECTIONS.includes(params.direction)) body.direction = params.direction;
        if (typeof params.size === "number" && Number.isFinite(params.size)) {
          body.size = Math.min(0.9, Math.max(0.1, params.size));
        }
      }
      await call("POST", "/v1/panes", body);
      cached = null;
      return {};
    },

    async listPanes() {
      const { panes } = await listing();
      return {
        panes: panes.map((pane) => ({
          id: pane.id,
          tab: pane.tab,
          tty: Number.isInteger(pane.pid) ? proc.tty(pane.pid) : null,
          command: null,
        })),
      };
    },

    async neighbor(params) {
      const { panes } = await listing();
      const from = params.from && panes.find((pane) => pane.id === String(params.from.id));
      const rect = from && !from.floating && paneRect(from);
      if (!rect || !DIRECTIONS.includes(params.direction)) return { pane: null };
      const candidates = panes
        .filter((pane) => pane.tab === from.tab && !pane.floating)
        .map(paneRect)
        .filter(Boolean);
      const found = adjacent(rect, candidates, params.direction);
      return { pane: found ? brief(panes.find((pane) => pane.id === found.id)) : null };
    },

    async sendText(params) {
      await call("POST", `/v1/panes/${encodeURIComponent(String(params.pane))}/write`, { text: String(params.text ?? "") });
      return {};
    },

    async focusPane(params) {
      await call("POST", `/v1/panes/${encodeURIComponent(String(params.pane))}/focus`, {});
      return {};
    },
  };

  // One request line in, one reply object out.
  return async function answer(line) {
    let request;
    try {
      request = JSON.parse(line);
    } catch {
      return { id: "", error: { message: "the request is not json" } };
    }
    const id = request && typeof request.id === "string" ? request.id : "";
    const method = request && request.method;
    if (typeof method !== "string" || !Object.prototype.hasOwnProperty.call(methods, method)) {
      return { id, error: { message: `${NAME} has no ${String(method)}` } };
    }
    if (method === "hello" && request.params && request.params.protocol !== PROTOCOL) {
      return { id, error: { message: `${NAME} speaks terminal socket protocol ${PROTOCOL}` } };
    }
    try {
      return { id, result: await methods[method](request.params || {}, request.caller || null) };
    } catch (error) {
      return { id, error: { message: error instanceof Error ? error.message : String(error) } };
    }
  };
}

// --- the socket -----------------------------------------------------------------------------------

function listening(socketPath) {
  return new Promise((resolve) => {
    const probe = net.connect(socketPath);
    probe.once("connect", () => {
      probe.destroy();
      resolve(true);
    });
    probe.once("error", () => resolve(false));
  });
}

// Serves answer() on socketPath. Resolves to the net.Server, or null when another server already
// answers there. A socket file nobody listens on (a server that was killed) is replaced.
async function serve(socketPath, answer, { idleMs = IDLE_MS, onIdle } = {}) {
  let idle = null;
  const touch = () => {
    if (idle) clearTimeout(idle);
    idle = setTimeout(() => onIdle && onIdle(), idleMs);
  };
  const server = net.createServer((connection) => {
    touch();
    let buffer = "";
    let answered = false;
    connection.setEncoding("utf8");
    connection.on("error", () => {});
    connection.on("data", (chunk) => {
      if (answered) return;
      buffer += chunk;
      const newline = buffer.indexOf("\n");
      if (newline < 0) return;
      answered = true;
      answer(buffer.slice(0, newline)).then((reply) => {
        if (!connection.destroyed) connection.end(`${JSON.stringify(reply)}\n`);
      });
    });
  });
  const bind = () =>
    new Promise((resolve, reject) => {
      server.once("error", reject);
      server.listen(socketPath, () => {
        server.off("error", reject);
        resolve();
      });
    });
  try {
    await bind();
  } catch (error) {
    if (error.code !== "EADDRINUSE") throw error;
    if (await listening(socketPath)) return null;
    fs.rmSync(socketPath, { force: true });
    await bind();
  }
  try {
    fs.chmodSync(socketPath, 0o600);
  } catch {}
  touch();
  server.on("close", () => idle && clearTimeout(idle));
  return server;
}

async function main(socketPath) {
  if (!socketPath) {
    process.stderr.write("usage: launcher-terminal.js <socket path>\n");
    process.exit(2);
  }
  // Started in the background of a pane's shell: closing that pane or ctrl+c there is not ours
  // to act on. (Node resets inherited ignored signals to their defaults, so nohup alone is not
  // enough.)
  for (const signal of ["SIGHUP", "SIGINT", "SIGQUIT"]) process.on(signal, () => {});
  const pidFile = `${socketPath}.pid`;
  let server = null;
  const stop = () => {
    try {
      if (fs.readFileSync(pidFile, "utf8").trim() === String(process.pid)) fs.rmSync(pidFile, { force: true });
    } catch {}
    // Closing the server removes its socket file (libuv unlinks a pipe it bound).
    if (server) server.close();
    process.exit(0);
  };
  process.on("SIGTERM", stop);
  const answer = launcherTerminal({ dir: path.join(os.homedir(), ".launcherctl") });
  server = await serve(socketPath, answer, { onIdle: stop });
  if (server === null) process.exit(0);
  // Written once the socket answers: the launcher script waits for it.
  fs.writeFileSync(pidFile, `${process.pid}\n`);
}

module.exports = { launcherTerminal, serve, refusal, closingCommand, NAME, PROTOCOL };

if (require.main === module) {
  main(process.argv[2]).catch((error) => {
    process.stderr.write(`launcher-terminal: ${error instanceof Error ? error.message : String(error)}\n`);
    process.exit(1);
  });
}
