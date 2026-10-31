// Clothespin browser client: live room chat over the vendored phoenix.js.
// No bundler — this file is plain ES2020 loaded by the root layout.
(function () {
  "use strict";

  var page = document.getElementById("room-page");
  if (!page || typeof Phoenix === "undefined") return;

  var roomId = page.dataset.roomId;
  var token = page.dataset.userToken;
  var selectedId = page.dataset.selected || null;

  var messagesEl = document.getElementById("messages");
  var compose = document.getElementById("compose");
  var convForm = document.getElementById("open-conversation");
  var convList = document.getElementById("conversation-list");

  function freshId() {
    return (window.crypto && crypto.randomUUID) ? crypto.randomUUID() : String(Date.now());
  }

  function el(tag, cls, text) {
    var node = document.createElement(tag);
    if (cls) node.className = cls;
    if (text != null) node.textContent = text;
    return node;
  }

  function esc(s) { return s == null ? "" : s; }

  function renderMessage(msg) {
    if (messagesEl.querySelector('[data-message-id="' + msg.message_id + '"]')) return;
    var previous = document.getElementById("no-messages");
    if (previous) previous.remove();

    var row = el("div", "message" + (msg.sender_kind === "human" ? " human" : ""));
    row.dataset.messageId = msg.message_id;

    var meta = el("div", "meta");
    meta.appendChild(el("span", "name", esc(msg.sender_name)));
    meta.appendChild(el("span", "muted", " at " + esc(msg.inserted_at)));
    if (msg.recipient_site) meta.appendChild(el("span", "muted", " → " + msg.recipient_site));
    row.appendChild(meta);
    row.appendChild(el("div", "body", esc(msg.body)));
    messagesEl.appendChild(row);
    messagesEl.scrollTop = messagesEl.scrollHeight;
  }

  function renderConversation(conv) {
    if (convList.querySelector('a[href$="' + conv.id + '"]')) return;
    var li = el("li");
    var a = el("a", null, conv.title);
    a.href = window.location.pathname + "?cid=" + conv.id;
    li.appendChild(a);
    convList.appendChild(li);
  }

  function selectConversation(id) {
    selectedId = id;
    Array.prototype.forEach.call(convList.querySelectorAll("a"), function (a) {
      a.classList.toggle("active", a.href.indexOf(id) !== -1);
    });
  }

  var socket = new Phoenix.Socket("/socket", { params: { token: token } });
  socket.connect();

  var channel = socket.channel("room:" + roomId, {});
  var connected = false;

  channel.on("snapshot", function (payload) {
    if (selectedId) {
      payload.messages.forEach(function (m) {
        if (m.conversation_id === selectedId) {
          renderMessage({ message_id: m.id, sender_name: m.sender_name, sender_kind: m.sender_key.indexOf("human:") === 0 ? "human" : "agent", inserted_at: m.inserted_at, recipient_site: m.recipient_site, body: m.body });
        }
      });
    }
  });

  channel.on("message_new", function (payload) {
    renderMessage(payload);
    renderConversation(payload.conversation);
    if (!selectedId) selectConversation(payload.conversation.id);
  });

  channel.on("conversation_new", function (conv) {
    renderConversation(conv);
  });

  channel.join()
    .receive("ok", function () { connected = true; })
    .receive("error", function () {
      // Live chat unavailable; the HTTP fallback form still works.
      console.warn("room channel join failed; falling back to HTTP form");
    });

  if (convForm) {
    convForm.addEventListener("submit", function (event) {
      event.preventDefault();
      var title = convForm.querySelector('[name="title"]').value.trim();
      if (!title) return;
      channel
        .push("open_conversation", { title: title })
        .receive("ok", function (resp) {
          convForm.querySelector('[name="title"]').value = "";
          var conv = { id: resp.conversation_id, title: title };
          renderConversation(conv);
          selectConversation(resp.conversation_id);
          window.history.replaceState(null, "", "?cid=" + resp.conversation_id);
          if (compose) attachCompose(resp.conversation_id, title);
        });
    });
  }

  // The server-rendered form posts over HTTP; intercept when the socket is
  // live for the synchronous path, else let it submit normally.
  function attachCompose(conversationId, title) {
    if (!compose) {
      return;
    }
    compose.dataset.conversationId = conversationId;
    compose.action = window.location.pathname.replace(/\/$/, "") +
      "/conversations/" + conversationId + "/messages";
    var label = compose.querySelector("label");
    if (label && title) label.textContent = "Message — " + title;
  }

  if (compose) {
    var cmidInput = compose.querySelector('[name="client_message_id"]');
    compose.addEventListener("submit", function (event) {
      if (!connected) return; // let the HTTP fallback post
      event.preventDefault();
      var bodyEl = compose.querySelector('[name="body"]');
      var body = bodyEl.value.trim();
      if (!body) return;
      channel
        .push("chat", {
          conversation_id: compose.dataset.conversationId || selectedId,
          client_message_id: cmidInput.value,
          body: body,
        })
        .receive("ok", function () {
          bodyEl.value = "";
          cmidInput.value = freshId();
        })
        .receive("error", function (resp) {
          console.warn("chat failed", resp);
        });
    });
  }
})();
