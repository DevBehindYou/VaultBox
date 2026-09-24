/* Atomic Carton public link page (/s/<token> to download, /u/<token> to upload).
 *
 * No account and no cookie: the link's secret token in the address is the only
 * credential. Everything shown is inserted as text, never as HTML.
 */
"use strict";

(function () {
  var appEl = document.getElementById("app");
  var parts = window.location.pathname.split("/").filter(Boolean);
  var token = parts.length >= 2 ? parts[1] : "";
  var base = "/api/v1/public/" + encodeURIComponent(token);

  var state = { info: null, unlock: null, path: "/", entries: [], next: null, loading: false, error: null };
  var collator = new Intl.Collator(undefined, { numeric: true, sensitivity: "base" });

  function append(node, children) {
    for (var i = 0; i < children.length; i++) {
      var child = children[i];
      if (child === null || child === undefined || child === false) continue;
      if (Array.isArray(child)) append(node, child);
      else node.append(child instanceof Node ? child : document.createTextNode(String(child)));
    }
  }

  function h(tag, attrs) {
    var node = document.createElement(tag);
    var keys = attrs ? Object.keys(attrs) : [];
    for (var i = 0; i < keys.length; i++) {
      var key = keys[i];
      var value = attrs[key];
      if (value === null || value === undefined || value === false) continue;
      if (key === "class") node.className = value;
      else if (key === "text") node.textContent = value;
      else if (key.indexOf("on") === 0) node.addEventListener(key.slice(2), value);
      else if (key === "value" || key === "checked" || key === "disabled") node[key] = value;
      else node.setAttribute(key, value === true ? "" : String(value));
    }
    append(node, Array.prototype.slice.call(arguments, 2));
    return node;
  }

  function formatBytes(bytes) {
    if (bytes === null || bytes === undefined) return "";
    if (bytes < 1024) return bytes + " B";
    var units = ["KB", "MB", "GB", "TB"];
    var value = bytes / 1024;
    var unit = 0;
    while (value >= 1024 && unit < units.length - 1) {
      value /= 1024;
      unit++;
    }
    return (value >= 10 ? value.toFixed(0) : value.toFixed(1)) + " " + units[unit];
  }

  function formatWhen(iso) {
    if (!iso) return "";
    var date = new Date(iso);
    if (isNaN(date.getTime())) return "";
    try {
      return date.toLocaleString(undefined, { dateStyle: "medium", timeStyle: "short" });
    } catch (_) {
      return date.toISOString();
    }
  }

  var MESSAGES = {
    not_found: "This link doesn't exist, or it has been removed.",
    link_expired: "This link has expired.",
    link_used_up: "This link has been used as many times as it allows.",
    password_required: "Enter the password to continue.",
    invalid_password: "That password isn't right.",
    too_many_attempts: "Too many attempts. Wait a moment and try again.",
    busy: "The phone is busy. Try again in a moment.",
    storage_unavailable: "The storage isn't reachable right now.",
    invalid_name: "That file name can't be used.",
    file_too_large: "That file is bigger than this link accepts.",
    upload_interrupted: "The upload was interrupted.",
    insufficient_storage: "There isn't enough free space on the phone.",
    network: "Can't reach the phone. Check that it is on and on the same network.",
  };

  function describe(error) {
    if (error && error.code === "too_many_attempts" && error.retryAfter) {
      return "Too many attempts. Try again in " + error.retryAfter + " seconds.";
    }
    return (error && MESSAGES[error.code]) || "Something went wrong. Please try again.";
  }

  function ApiError(status, code, retryAfter) {
    this.status = status;
    this.code = code;
    this.retryAfter = retryAfter;
  }

  function request(method, path, options) {
    var opts = options || {};
    var url = new URL(base + path, window.location.origin);
    var query = opts.query || {};
    Object.keys(query).forEach(function (key) {
      if (query[key] !== undefined && query[key] !== null) url.searchParams.set(key, String(query[key]));
    });
    if (state.unlock) url.searchParams.set("unlock", state.unlock);
    var init = { method: method, headers: {}, cache: "no-store", credentials: "omit", referrerPolicy: "no-referrer" };
    if (opts.json !== undefined) {
      init.headers["Content-Type"] = "application/json";
      init.body = JSON.stringify(opts.json);
    }
    return fetch(url.toString(), init).then(
      function (response) {
        if (!response.ok) {
          return response.json().then(function (d) { return d; }, function () { return null; }).then(function (data) {
            throw new ApiError(response.status, data && typeof data.error === "string" ? data.error : "error", response.headers.get("Retry-After"));
          });
        }
        return response.json();
      },
      function () { throw new ApiError(0, "network", null); }
    );
  }

  function contentUrl(relativePath) {
    var url = base + "/content";
    var query = [];
    if (relativePath) query.push("path=" + encodeURIComponent(relativePath));
    if (state.unlock) query.push("unlock=" + encodeURIComponent(state.unlock));
    return query.length ? url + "?" + query.join("&") : url;
  }

  function join(directory, name) {
    return directory === "/" ? "/" + name : directory + "/" + name;
  }

  function segments(path) {
    return path.split("/").filter(Boolean);
  }

  // ---------------------------------------------------------------- shell

  function shell(children) {
    appEl.replaceChildren(
      h(
        "div",
        { class: "login-wrap" },
        h(
          "main",
          { class: "card" },
          h("div", { class: "brand" }, h("span", { class: "brand-mark", "aria-hidden": "true" }), h("h1", { text: "Atomic Carton" })),
          children
        )
      )
    );
  }

  function showError(error) {
    shell([h("p", { class: "notice error", role: "alert", text: describe(error) })]);
  }

  function insecureNote() {
    var insecure = window.location.protocol === "http:" &&
      ["localhost", "127.0.0.1", "[::1]"].indexOf(window.location.hostname) === -1;
    return insecure
      ? h("p", { class: "insecure", text: "This connection isn't encrypted, so anyone on this network could see what is sent. Use the https:// address if you can." })
      : null;
  }

  function expiryNote(info) {
    return info.expiresAt ? h("p", { class: "lede", text: "Available until " + formatWhen(info.expiresAt) + "." }) : null;
  }

  // ------------------------------------------------------------- password

  function askPassword() {
    var errorBox = h("p", { class: "notice error hidden", role: "alert" });
    var input = h("input", { id: "pw", type: "password", autocomplete: "off", required: true });
    var submit = h("button", { type: "submit", class: "btn primary" }, h("span", { class: "txt", text: "Continue" }));
    var form = h(
      "form",
      {
        novalidate: true,
        onsubmit: function (event) {
          event.preventDefault();
          if (!input.value) return;
          errorBox.classList.add("hidden");
          submit.disabled = true;
          request("POST", "/unlock", { json: { password: input.value } }).then(
            function (data) {
              state.unlock = data.unlock;
              input.value = "";
              return load();
            },
            function (error) {
              submit.disabled = false;
              input.value = "";
              input.focus();
              errorBox.textContent = describe(error);
              errorBox.classList.remove("hidden");
            }
          );
        },
      },
      errorBox,
      h("div", { class: "field" }, h("label", { for: "pw", text: "Password" }), input),
      submit
    );
    shell([h("p", { class: "lede", text: "This link is protected." }), form, insecureNote()]);
    input.focus();
  }

  // ------------------------------------------------------------- download

  function renderFile(info) {
    shell([
      h("p", { class: "lede", text: "Someone shared a file with you." }),
      h("p", null, h("strong", { text: info.name || "File" })),
      info.size !== null && info.size !== undefined ? h("p", { class: "lede", text: formatBytes(info.size) }) : null,
      expiryNote(info),
      h("a", { class: "btn primary", href: contentUrl(null), download: info.name || "" }, h("span", { class: "txt", text: "Download" })),
      insecureNote(),
    ]);
  }

  function loadFolder(reset) {
    if (reset) {
      state.entries = [];
      state.next = null;
    }
    state.loading = true;
    state.error = null;
    renderFolder();
    var query = { path: state.path, limit: 200 };
    if (!reset && state.next) query.cursor = state.next;
    return request("GET", "/entries", { query: query }).then(
      function (data) {
        state.entries = state.entries.concat(data.entries);
        state.entries.sort(function (a, b) {
          if (a.type !== b.type) return a.type === "directory" ? -1 : 1;
          return collator.compare(a.name, b.name);
        });
        state.next = data.nextCursor;
        state.loading = false;
        renderFolder();
      },
      function (error) {
        state.loading = false;
        state.error = describe(error);
        renderFolder();
      }
    );
  }

  function crumbs(info) {
    var nodes = [];
    var walked = "/";
    nodes.push(h("button", { type: "button", text: info.name || "Folder", onclick: function () { state.path = "/"; loadFolder(true); } }));
    segments(state.path).forEach(function (part) {
      walked = join(walked, part);
      var target = walked;
      nodes.push(h("span", { class: "sep", "aria-hidden": "true", text: "/" }));
      nodes.push(h("button", { type: "button", text: part, onclick: function () { state.path = target; loadFolder(true); } }));
    });
    return h("nav", { class: "crumbs", "aria-label": "Folder path" }, nodes);
  }

  function renderFolder() {
    var info = state.info;
    var body;
    if (state.error) {
      body = h("div", { class: "empty" }, h("strong", { text: "Couldn't open this folder" }), h("p", { text: state.error }));
    } else if (state.loading && state.entries.length === 0) {
      body = h("div", { class: "empty", role: "status", text: "Loading…" });
    } else if (state.entries.length === 0) {
      body = h("div", { class: "empty" }, h("strong", { text: "This folder is empty" }));
    } else {
      var rows = h("tbody");
      state.entries.forEach(function (entry) {
        var isDir = entry.type === "directory";
        var label = isDir
          ? h("button", { type: "button", class: "name-btn", onclick: function () { state.path = join(state.path, entry.name); loadFolder(true); } }, h("span", { class: "label", text: entry.name }))
          : h("a", { class: "name-btn file", href: contentUrl(join(state.path, entry.name)), download: entry.name }, h("span", { class: "label", text: entry.name }));
        rows.appendChild(
          h("tr", null, h("td", null, label), h("td", { class: "num", text: isDir ? "" : formatBytes(entry.size) }), h("td", { class: "when", text: formatWhen(entry.modified) }))
        );
      });
      var more = state.next
        ? h("div", { class: "more" }, h("button", { type: "button", class: "btn", disabled: state.loading, onclick: function () { loadFolder(false); } }, h("span", { class: "txt", text: "Load more" })))
        : null;
      body = h(
        "div",
        null,
        h("table", { class: "files" }, h("thead", null, h("tr", null, h("th", { text: "Name" }), h("th", { class: "num", text: "Size" }), h("th", { class: "when", text: "Modified" }))), rows),
        more
      );
    }
    appEl.replaceChildren(
      h("main", { class: "page" }, h("div", { class: "brand" }, h("span", { class: "brand-mark", "aria-hidden": "true" }), h("h1", { text: "Atomic Carton" })), expiryNote(info), crumbs(info), h("section", { class: "panel" }, body), insecureNote())
    );
  }

  // --------------------------------------------------------------- upload

  var uploads = [];

  function renderUpload(info) {
    var list = h("ul", { class: "uploads-list" });
    var picker = h("input", {
      type: "file",
      multiple: true,
      class: "hidden",
      tabindex: "-1",
      onchange: function (event) {
        var files = Array.prototype.slice.call(event.target.files);
        event.target.value = "";
        files.forEach(queue);
      },
    });
    var limit = info.maxFileBytes ? "Each file can be up to " + formatBytes(info.maxFileBytes) + "." : "";
    var left = info.remainingUses !== null && info.remainingUses !== undefined ? info.remainingUses + " more file" + (info.remainingUses === 1 ? "" : "s") + " can be sent." : "";

    var card = h(
      "main",
      { class: "card" },
      h("div", { class: "brand" }, h("span", { class: "brand-mark", "aria-hidden": "true" }), h("h1", { text: "Atomic Carton" })),
      h("p", { class: "lede", text: "Send files to the phone's owner. You won't see what else is in the folder." }),
      limit || left ? h("p", { class: "lede", text: [limit, left].filter(Boolean).join(" ") }) : null,
      expiryNote(info),
      h("button", { type: "button", class: "btn primary", onclick: function () { picker.click(); } }, h("span", { class: "txt", text: "Choose files" })),
      picker,
      list,
      insecureNote()
    );
    appEl.replaceChildren(h("div", { class: "login-wrap" }, card));

    card.addEventListener("dragover", function (event) { event.preventDefault(); });
    card.addEventListener("drop", function (event) {
      event.preventDefault();
      var files = Array.prototype.slice.call(event.dataTransfer.files);
      files.forEach(queue);
    });
    uploads.list = list;
    uploads.items = [];
  }

  function queue(file) {
    var status = h("span", { class: "s", text: "Waiting" });
    var bar = h("span");
    var row = h("li", null, h("div", { class: "row" }, h("span", { class: "n", text: file.name, title: file.name }), status), h("div", { class: "bar" }, bar));
    uploads.list.appendChild(row);
    uploads.items.push({ file: file, status: status, bar: bar });
    pump();
  }

  var sending = false;

  function pump() {
    if (sending) return;
    var next = uploads.items.filter(function (item) { return !item.started; })[0];
    if (!next) return;
    sending = true;
    next.started = true;
    send(next).then(function () {
      sending = false;
      pump();
    });
  }

  function send(item) {
    return new Promise(function (resolve) {
      var xhr = new XMLHttpRequest();
      var url = base + "/content?name=" + encodeURIComponent(item.file.name) + (state.unlock ? "&unlock=" + encodeURIComponent(state.unlock) : "");
      xhr.open("PUT", url);
      xhr.upload.onprogress = function (event) {
        if (event.lengthComputable && event.total > 0) {
          item.bar.style.width = Math.round((event.loaded / event.total) * 100) + "%";
          item.status.textContent = Math.round((event.loaded / event.total) * 100) + "%";
        }
      };
      xhr.onload = function () {
        if (xhr.status >= 200 && xhr.status < 300) {
          item.bar.style.width = "100%";
          item.status.textContent = "Sent";
          item.status.className = "s good";
        } else {
          var code = "error";
          try { code = JSON.parse(xhr.responseText).error; } catch (_) { /* keep generic */ }
          item.status.textContent = describe({ code: code });
          item.status.className = "s bad";
        }
        resolve();
      };
      xhr.onerror = function () {
        item.status.textContent = describe({ code: "network" });
        item.status.className = "s bad";
        resolve();
      };
      item.status.textContent = "0%";
      xhr.send(item.file);
    });
  }

  // ----------------------------------------------------------------- flow

  function load() {
    return request("GET", "").then(
      function (info) {
        state.info = info;
        if (info.requiresPassword && !info.unlocked) {
          askPassword();
        } else if (info.kind === "upload") {
          renderUpload(info);
        } else if (info.isDirectory) {
          state.path = "/";
          loadFolder(true);
        } else {
          renderFile(info);
        }
      },
      showError
    );
  }

  if (!token) showError({ code: "not_found" });
  else load();
})();
