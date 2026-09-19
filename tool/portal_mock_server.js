#!/usr/bin/env node
/*
 * A stand-in for the phone's server, so the web portal (assets/portal) can be
 * developed and looked at in an ordinary browser without a phone.
 *
 *   node tool/portal_mock_server.js [port]        # default 8090
 *   open http://127.0.0.1:8090/    user: admin    password: correct horse battery
 *
 * It mimics the /api/v1 contract (see lib/server/api/vault_api.dart) with an
 * in-memory file tree and the same status codes / error codes. It is NOT a
 * security reference: the Dart server is. Never expose this beyond localhost.
 */
"use strict";

const http = require("http");
const fs = require("fs");
const path = require("path");
const crypto = require("crypto");

const PORT = Number(process.argv[2] || 8090);
const PORTAL_DIR = path.join(__dirname, "..", "assets", "portal");
const PASSWORD = "correct horse battery";
const PORTAL_CSP = "default-src 'none'; script-src 'self'; style-src 'self'; img-src 'self' data: blob:; media-src 'self'; connect-src 'self'; base-uri 'none'; form-action 'none'; frame-ancestors 'none'";

// ---- in-memory storage: "/a/b" -> {dir: bool, data?: Buffer, mtime: Date}
const tree = new Map();
function seed(p, content) {
  const parts = p.split("/").filter(Boolean);
  for (let i = 1; i < parts.length; i++) {
    const dir = "/" + parts.slice(0, i).join("/");
    if (!tree.has(dir)) tree.set(dir, { dir: true, mtime: new Date() });
  }
  tree.set(p, content === null ? { dir: true, mtime: new Date() } : { dir: false, data: Buffer.from(content), mtime: new Date() });
}
seed("/Documents", null);
seed("/Documents/notes.txt", "Hello from the mock phone.\nLine two.\n");
seed("/Documents/readme.md", "# VaultBox\nA mock file.\n");
seed("/Photos", null);
seed("/Photos/pixel.png", Buffer.from("iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==", "base64"));
seed("/Music", null);
seed("/big.bin", Buffer.alloc(3 * 1024 * 1024, 7));
seed("/100% real.txt", "percent sign");
for (let i = 1; i <= 260; i++) seed("/many/file-" + String(i).padStart(3, "0") + ".txt", "n" + i);
seed("/.vaultbox/recycle/hidden.txt", "should never be listed");

const sessions = new Map(); // token -> {created, last}
const tickets = new Map(); // token -> {path, session, expires}

function send(res, status, body, headers) {
  const h = Object.assign({
    "Cache-Control": "no-store",
    "X-Content-Type-Options": "nosniff",
    "Referrer-Policy": "no-referrer",
    "Content-Security-Policy": "default-src 'none'",
  }, headers || {});
  if (body !== undefined && body !== null && typeof body !== "string" && !Buffer.isBuffer(body)) {
    h["Content-Type"] = "application/json";
    body = JSON.stringify(body);
  }
  res.writeHead(status, h);
  res.end(body);
}
const err = (res, status, code, headers) => send(res, status, { error: code }, headers);

function readBody(req, limit) {
  return new Promise((resolve, reject) => {
    const chunks = [];
    let size = 0;
    req.on("data", (c) => { size += c.length; if (limit && size > limit) { reject(new Error("too big")); req.destroy(); } else chunks.push(c); });
    req.on("end", () => resolve(Buffer.concat(chunks)));
    req.on("error", reject);
  });
}

function parsePath(raw) {
  let p = raw === undefined || raw === null ? "/" : String(raw);
  const segs = [];
  for (const part of p.replace(/\\/g, "/").split("/")) {
    if (!part) continue;
    if (part === "..") return null;
    segs.push(part);
  }
  if (segs.length && segs[0].toLowerCase() === ".vaultbox") return "reserved";
  return "/" + segs.join("/");
}
const parentOf = (p) => (p.lastIndexOf("/") <= 0 ? "/" : p.slice(0, p.lastIndexOf("/")));
const nameOf = (p) => p.slice(p.lastIndexOf("/") + 1);
const isDir = (p) => p === "/" || (tree.has(p) && tree.get(p).dir);

function entryJson(p) {
  const n = tree.get(p);
  return { name: nameOf(p), type: n.dir ? "directory" : "file", size: n.dir ? null : n.data.length, modified: n.mtime.toISOString(), mime: null };
}

function children(dir) {
  const prefix = dir === "/" ? "/" : dir + "/";
  return [...tree.keys()].filter((k) => k !== dir && k.startsWith(prefix) && !k.slice(prefix.length).includes("/")).sort();
}

function mimeOf(name) {
  const ext = name.split(".").pop().toLowerCase();
  return { txt: "text/plain", md: "text/plain", png: "image/png", jpg: "image/jpeg", mp4: "video/mp4", mp3: "audio/mpeg", html: "text/html" }[ext] || "application/octet-stream";
}

function disposition(name, inline) {
  const ascii = name.replace(/[^A-Za-z0-9._ -]/g, "_");
  return (inline ? "inline" : "attachment") + '; filename="' + ascii + "\"; filename*=UTF-8''" + encodeURIComponent(name).replace(/'/g, "%27");
}

function serveFile(req, res, p, inline) {
  const node = tree.get(p);
  const size = node.data.length;
  const mime = mimeOf(nameOf(p));
  const safeInline = inline && (/^(image|audio|video)\//.test(mime) || mime === "text/plain");
  const headers = {
    "Content-Type": mime,
    "Content-Disposition": disposition(nameOf(p), safeInline),
    "Accept-Ranges": "bytes",
    "Content-Security-Policy": "sandbox; default-src 'none'; style-src 'unsafe-inline'",
  };
  let start = 0;
  let end = size - 1;
  let status = 200;
  const m = /^bytes=(\d*)-(\d*)$/.exec(req.headers.range || "");
  if (m && (m[1] || m[2])) {
    if (!m[1]) { start = Math.max(0, size - Number(m[2])); }
    else { start = Number(m[1]); if (m[2]) end = Math.min(size - 1, Number(m[2])); }
    if (start >= size) return err(res, 416, "range_not_satisfiable", { "Content-Range": "bytes */" + size });
    status = 206;
    headers["Content-Range"] = "bytes " + start + "-" + end + "/" + size;
  }
  headers["Content-Length"] = String(end - start + 1);
  res.writeHead(status, Object.assign({ "Cache-Control": "no-store", "X-Content-Type-Options": "nosniff" }, headers));
  res.end(req.method === "HEAD" ? undefined : node.data.subarray(start, end + 1));
}

async function api(req, res, url) {
  const segs = url.pathname.split("/").filter(Boolean).slice(2); // after api/v1
  const q = url.searchParams;

  if (segs[0] === "auth" && segs[1] === "login") {
    if (req.method !== "POST") return err(res, 405, "method_not_allowed", { Allow: "POST" });
    let body;
    try { body = JSON.parse((await readBody(req, 16384)).toString("utf8")); } catch (_) { return err(res, 400, "bad_request"); }
    if (!body || typeof body.username !== "string" || typeof body.password !== "string") return err(res, 400, "bad_request");
    if (body.username.trim().toLowerCase() !== "admin" || body.password !== PASSWORD) return err(res, 401, "invalid_credentials");
    const token = crypto.randomBytes(32).toString("base64url");
    sessions.set(token, { last: Date.now() });
    return send(res, 200, { token, tokenType: "Bearer", idleTimeoutSeconds: 1800, maxLifetimeSeconds: 43200, user: { id: "a1", username: "admin" } });
  }

  const auth = /^Bearer (.+)$/i.exec(req.headers.authorization || "");
  const token = auth && auth[1].trim();
  if (!token || !sessions.has(token)) return err(res, 401, "unauthorized", { "WWW-Authenticate": "Bearer" });

  if (segs[0] === "auth" && segs[1] === "logout") { sessions.delete(token); return send(res, 204); }
  if (segs[0] === "me") return send(res, 200, { id: "a1", username: "admin" });
  if (segs[0] === "roots" && segs.length === 1) {
    return send(res, 200, { roots: [
      { id: "phone", name: "Phone storage", available: true, writable: true, isDefault: true, freeBytes: 50e9, totalBytes: 128e9 },
      { id: "card", name: "SD card", available: true, writable: false, isDefault: false, freeBytes: 1e9, totalBytes: 32e9 },
    ] });
  }
  if (segs[0] !== "roots" || segs.length !== 3) return err(res, 404, "not_found");

  const rootId = segs[1];
  const action = segs[2];
  if (rootId !== "phone" && rootId !== "card") return err(res, 404, "root_not_found");
  const writable = rootId === "phone";
  const need = () => (writable ? true : (err(res, 403, "read_only_storage"), false));

  if (action === "entries") {
    const p = parsePath(q.get("path"));
    if (p === null) return err(res, 400, "invalid_path");
    if (p === "reserved") return err(res, 404, "not_found");
    if (!isDir(p)) return err(res, tree.has(p) ? 400 : 404, tree.has(p) ? "not_a_directory" : "not_found");
    const limit = q.get("limit") === null ? 200 : Number(q.get("limit"));
    if (!Number.isInteger(limit) || limit < 1 || limit > 500) return err(res, 400, "bad_request");
    let names = children(p);
    const cursor = q.get("cursor");
    if (cursor) { const i = names.findIndex((n) => nameOf(n) === cursor); names = i === -1 ? [] : names.slice(i + 1); }
    const page = names.slice(0, limit);
    return send(res, 200, {
      path: p,
      entries: page.filter((n) => !(p === "/" && nameOf(n).toLowerCase() === ".vaultbox")).map(entryJson),
      nextCursor: page.length === limit ? nameOf(page[page.length - 1]) : null,
    });
  }

  if (action === "ticket" && req.method === "POST") {
    let body;
    try { body = JSON.parse((await readBody(req, 16384)).toString("utf8")); } catch (_) { return err(res, 400, "bad_request"); }
    const p = parsePath(body && body.path);
    if (p === null || p === "/") return err(res, 400, "invalid_path");
    if (p === "reserved" || !tree.has(p)) return err(res, 404, "not_found");
    if (tree.get(p).dir) return err(res, 400, "not_a_file");
    const t = crypto.randomBytes(32).toString("base64url");
    tickets.set(t, { path: p, expires: Date.now() + 15 * 60 * 1000 });
    return send(res, 200, { url: "/d/" + t, expiresInSeconds: 900 });
  }

  if (action === "content") {
    const p = parsePath(q.get("path"));
    if (p === null || p === "/") return err(res, 400, "invalid_path");
    if (p === "reserved") return err(res, 404, "not_found");
    if (req.method === "GET" || req.method === "HEAD") {
      if (!tree.has(p)) return err(res, 404, "not_found");
      if (tree.get(p).dir) return err(res, 400, "not_a_file");
      return serveFile(req, res, p, q.get("inline") === "1");
    }
    if (req.method === "PUT") {
      if (!need()) return;
      if (!isDir(parentOf(p))) return err(res, 409, "parent_not_found");
      if (tree.has(p) && tree.get(p).dir) return err(res, 409, "is_a_directory");
      if (tree.has(p) && q.get("overwrite") !== "1") return err(res, 409, "already_exists");
      const existed = tree.has(p);
      const data = await readBody(req);
      tree.set(p, { dir: false, data, mtime: new Date() });
      return send(res, existed ? 200 : 201, { path: p, size: data.length });
    }
    return err(res, 405, "method_not_allowed", { Allow: "GET, HEAD, PUT" });
  }

  if (req.method !== "POST") return err(res, 405, "method_not_allowed", { Allow: "POST" });
  if (!need()) return;
  let body;
  try { body = JSON.parse((await readBody(req, 16384)).toString("utf8")); } catch (_) { return err(res, 400, "bad_request"); }
  if (!body || typeof body !== "object") return err(res, 400, "bad_request");

  if (action === "mkdir") {
    const p = parsePath(body.path);
    if (typeof body.path !== "string" || p === null || p === "/") return err(res, 400, "invalid_path");
    if (p === "reserved") return err(res, 404, "not_found");
    if (!isDir(parentOf(p))) return err(res, 409, "parent_not_found");
    if (tree.has(p)) return err(res, 409, "already_exists");
    tree.set(p, { dir: true, mtime: new Date() });
    return send(res, 201, { path: p });
  }

  if (action === "rename") {
    const p = parsePath(body.path);
    const n = body.newName;
    if (typeof body.path !== "string" || typeof n !== "string" || p === null || p === "/") return err(res, 400, "bad_request");
    if (p === "reserved") return err(res, 404, "not_found");
    if (!n || n.length > 255 || /[\/\\]/.test(n) || n === "." || n === ".." || (parentOf(p) === "/" && n.toLowerCase() === ".vaultbox")) return err(res, 400, "invalid_name");
    if (!tree.has(p)) return err(res, 404, "not_found");
    const target = (parentOf(p) === "/" ? "" : parentOf(p)) + "/" + n;
    if (target !== p && tree.has(target)) return err(res, 409, "already_exists");
    for (const k of [...tree.keys()]) {
      if (k === p || k.startsWith(p + "/")) { tree.set(target + k.slice(p.length), tree.get(k)); tree.delete(k); }
    }
    return send(res, 200, { path: target });
  }

  if (action === "move" || action === "copy" || action === "delete") {
    const list = action === "delete" ? body.paths : body.sources;
    if (!Array.isArray(list) || list.length < 1 || list.length > 500 || !list.every((s) => typeof s === "string")) return err(res, 400, "bad_request");
    const sources = list.map(parsePath);
    if (sources.some((s) => s === null || s === "/")) return err(res, 400, "invalid_path");
    if (sources.some((s) => s === "reserved")) return err(res, 404, "not_found");
    const results = [];
    let dest = null;
    const policy = body.conflict || "skip";
    if (action !== "delete") {
      dest = parsePath(body.destination);
      if (dest === null || typeof body.destination !== "string" || !["skip", "keepBoth", "replace"].includes(policy)) return err(res, 400, "bad_request");
      if (dest === "reserved") return err(res, 404, "not_found");
      if (!isDir(dest)) return err(res, 409, "destination_not_found");
    }
    for (const s of sources) {
      if (!tree.has(s)) { results.push({ source: s, status: "failed", target: null, message: "Couldn't find this item" }); continue; }
      if (action === "delete") {
        const bin = "/.vaultbox/recycle/" + crypto.randomUUID() + "__" + nameOf(s);
        for (const k of [...tree.keys()]) if (k === s || k.startsWith(s + "/")) { tree.set(bin + k.slice(s.length), tree.get(k)); tree.delete(k); }
        results.push({ source: s, status: "completed", target: bin, message: null });
        continue;
      }
      let target = (dest === "/" ? "" : dest) + "/" + nameOf(s);
      if (tree.has(target) && s !== target) {
        if (policy === "skip") { results.push({ source: s, status: "skipped", target: null, message: "Already exists at destination" }); continue; }
        if (policy === "keepBoth") {
          const m = /^(.*?)(\.[^.]*)?$/.exec(nameOf(s));
          let i = 1;
          const base = (dest === "/" ? "" : dest) + "/" + m[1];
          while (tree.has(base + " (" + i + ")" + (m[2] || ""))) i++;
          target = base + " (" + i + ")" + (m[2] || "");
        }
      }
      for (const k of [...tree.keys()]) {
        if (k === s || k.startsWith(s + "/")) {
          const copy = tree.get(k);
          tree.set(target + k.slice(s.length), { dir: copy.dir, data: copy.data, mtime: new Date() });
          if (action === "move") tree.delete(k);
        }
      }
      results.push({ source: s, status: "completed", target, message: null });
    }
    const count = (st) => results.filter((r) => r.status === st).length;
    return send(res, 200, { completed: count("completed"), skipped: count("skipped"), failed: count("failed"), results });
  }

  return err(res, 404, "not_found");
}

const assets = {
  "/": ["index.html", "text/html; charset=utf-8"],
  "/index.html": ["index.html", "text/html; charset=utf-8"],
  "/portal.css": ["portal.css", "text/css; charset=utf-8"],
  "/portal.js": ["portal.js", "text/javascript; charset=utf-8"],
};

http.createServer(async (req, res) => {
  const url = new URL(req.url, "http://localhost");
  try {
    if (url.pathname.startsWith("/api/v1/")) return await api(req, res, url);
    if (url.pathname.startsWith("/d/")) {
      const t = tickets.get(url.pathname.slice(3));
      if (!t || Date.now() > t.expires || !tree.has(t.path)) return err(res, 404, "not_found");
      if (req.method !== "GET" && req.method !== "HEAD") return err(res, 405, "method_not_allowed", { Allow: "GET, HEAD" });
      return serveFile(req, res, t.path, url.searchParams.get("inline") === "1");
    }
    if (url.pathname === "/health/" || url.pathname === "/health") return send(res, 200, { status: "ok", app: "vaultbox" });
    const asset = assets[url.pathname];
    if (asset && (req.method === "GET" || req.method === "HEAD")) {
      return send(res, 200, fs.readFileSync(path.join(PORTAL_DIR, asset[0])), {
        "Content-Type": asset[1],
        "Content-Security-Policy": PORTAL_CSP,
        "X-Frame-Options": "DENY",
      });
    }
    return err(res, 404, "not_found");
  } catch (e) {
    if (!res.headersSent) res.writeHead(500);
    res.end();
  }
}).listen(PORT, "127.0.0.1", () => console.log("portal mock on http://127.0.0.1:" + PORT + "/"));
