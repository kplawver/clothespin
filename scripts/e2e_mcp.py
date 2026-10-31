#!/usr/bin/env python3
"""Clothespin end-to-end: two clothesline buses bridged through one pin.

Stdlib only (urllib/json/time). Asserts each user-visible behavior with a
`PASS: <check>` line; exits non-zero on the first failure. Run via
scripts/e2e.sh which provisions both buses and the pin server first.
"""

import json
import os
import subprocess
import sys
import time
import urllib.error
import urllib.request

CLOTHESPIN = os.environ.get("CLOTHESPIN_URL", "http://localhost:4000")
BUS_A = os.environ.get("BUS_A_URL", "http://127.0.0.1:19004/mcp")
BUS_B = os.environ.get("BUS_B_URL", "http://127.0.0.1:19005/mcp")
CROSS_MIRROR_TIMEOUT = 40  # seconds: agent mirroring (poll cadence bound)
DELIVERY_TIMEOUT = 6  # seconds: message hop (2s poll default)

checks = 0


def ok(label):
    global checks
    checks += 1
    print(f"PASS: {label}", flush=True)


def fail(label, detail=""):
    print(f"FAIL: {label} {detail}", flush=True)
    sys.exit(1)


def assert_(cond, label, detail=""):
    ok(label) if cond else fail(label, detail)


class Bus:
    """Stateless MCP client for a clothesline bus."""

    def __init__(self, url, name):
        self.url = url
        self.name = name
        self.n = 0
        self.rpc("initialize", {
            "protocolVersion": "2025-06-18",
            "capabilities": {},
            "clientInfo": {"name": name, "version": "0"},
        })

    def rpc(self, method, params):
        self.n += 1
        req = urllib.request.Request(
            self.url,
            data=json.dumps({"jsonrpc": "2.0", "id": self.n, "method": method,
                             "params": params}).encode(),
            headers={"Content-Type": "application/json",
                     "Accept": "application/json, text/event-stream"})
        try:
            with urllib.request.urlopen(req, timeout=10) as r:
                body = r.read()
        except urllib.error.HTTPError as e:
            body = e.read()
        return json.loads(body) if body else {}

    def tool(self, name, args):
        r = self.rpc("tools/call", {"name": name, "arguments": args})
        if "result" not in r:
            raise RuntimeError(f"{self.name} {name}: {r}")
        return json.loads(r["result"]["content"][0]["text"])

    def agents(self):
        return self.tool("list_agents", {"include_inactive": True})["agents"]

    def find(self, external_id):
        return next((a for a in self.agents() if a["external_id"] == external_id), None)

    def send(self, harness, agent, conv, cmid, body, recipient=None):
        args = {"conversation_id": conv, "harness_id": harness, "agent_id": agent,
                "client_message_id": cmid, "body": body}
        if recipient:
            args["recipient_agent_id"] = recipient
        return self.tool("send_message", args)

    def search(self, body):
        return self.tool("search_messages", {"query": body, "limit": 50})["results"]

    def exact(self, body):
        """search_messages keyword-matches; filter for the exact body."""
        return [m for m in self.search(body) if m["body"] == body]


class Pin:
    def __init__(self, name):
        self.sid = None
        self.n = 0
        self.name = name
        self.rpc("initialize", {
            "protocolVersion": "2025-06-18",
            "capabilities": {},
            "clientInfo": {"name": name, "version": "0"},
        })

    def rpc(self, method, params):
        self.n += 1
        headers = {"Content-Type": "application/json",
                   "Accept": "application/json, text/event-stream"}
        if self.sid:
            headers["Mcp-Session-Id"] = self.sid
        req = urllib.request.Request(
            CLOTHESPIN + "/mcp",
            data=json.dumps({"jsonrpc": "2.0", "id": self.n, "method": method,
                             "params": params}).encode(),
            headers=headers)
        try:
            with urllib.request.urlopen(req, timeout=10) as r:
                new_sid = r.headers.get("mcp-session-id")
                if new_sid:
                    self.sid = new_sid
                body = r.read()
        except urllib.error.HTTPError as e:
            body = e.read()
        return json.loads(body) if body else {}

    def tool(self, name, args):
        r = self.rpc("tools/call", {"name": name, "arguments": args})
        if "result" not in r:
            raise RuntimeError(f"{self.name} {name}: {r}")
        return json.loads(r["result"]["content"][0]["text"])

    def status(self, token, room_id):
        return self.tool("pin_status", {"token": token, "room_id": room_id})


def wait_until(fn, timeout, label):
    deadline = time.time() + timeout
    while time.time() < deadline:
        v = fn()
        if v:
            return v
        time.sleep(1)
    fail(label, f"(timeout {timeout}s)")
    return None


def main():
    stamp = str(int(time.time()))

    # --- accounts + one shared pin, all through MCP like an agent would ---
    pin = Pin("e2e")
    pin.tool("create_account", {
        "username": f"e2e-a-{stamp}", "display_name": "E2E A",
        "passphrase": "alpha passphrase 123"})
    a_tok = pin.tool("login", {"username": f"e2e-a-{stamp}",
                               "passphrase": "alpha passphrase 123"})["token"]
    session = pin.tool("pin_session", {"token": a_tok, "title": f"e2e {stamp}",
                                       "site_name": "alpha"})
    assert_(len(session["bridge_token"]) > 20, "pin_session returns bridge token")
    assert_("/join/" in session["invite_url"], "pin_session returns invite URL")
    assert_(session["bridge_command"].startswith("mix pin.connect"),
            "pin_session returns bridge command")

    pin.tool("create_account", {
        "username": f"e2e-b-{stamp}", "display_name": "E2E B",
        "passphrase": "bravo passphrase 123"})
    b_tok = pin.tool("login", {"username": f"e2e-b-{stamp}",
                               "passphrase": "bravo passphrase 123"})["token"]
    joined = pin.tool("join_pin", {"token": b_tok, "invite_url": session["invite_url"]})
    assert_(joined["room_id"] == session["room_id"], "join_pin joins the same pin")

    # --- local agents on both buses (independent harnesses, like real ones) ---
    A, B = Bus(BUS_A, "bus-a"), Bus(BUS_B, "bus-b")
    ha = A.tool("register_harness", {"installation_key": f"e2e-a-{stamp}",
                                     "name": "A harness"})["harness_id"]
    aa = A.tool("register_agent", {"harness_id": ha, "external_id": "a-agent",
                                   "name": "A Agent"})
    A.tool("agent_online", {"harness_id": ha, "agent_id": aa["agent_id"]})
    hb = B.tool("register_harness", {"installation_key": f"e2e-b-{stamp}",
                                     "name": "B harness"})["harness_id"]
    ab = B.tool("register_agent", {"harness_id": hb, "external_id": "b-agent",
                                   "name": "B Agent"})
    B.tool("agent_online", {"harness_id": hb, "agent_id": ab["agent_id"]})

    # --- start the two bridges (the daemon an agent would run) ---
    repo = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    logdir = "/tmp/clothespin-e2e"
    os.makedirs(logdir, exist_ok=True)
    bridges = []
    for site, tok, bus in (("alpha", session["bridge_token"], BUS_A),
                           ("beta", joined["bridge_token"], BUS_B)):
        log = open(f"{logdir}/bridge-{site}.log", "w")
        bridges.append(subprocess.Popen(
            ["mix", "pin.connect", "--server", CLOTHESPIN, "--bridge-token", tok,
             "--clothesline", bus, "--site", site],
            cwd=repo, stdout=log, stderr=subprocess.STDOUT))

    try:
        wait_until(lambda: {"alpha", "beta"} <= set(
            pin.status(a_tok, session["room_id"])["bridges"]), 30,
            "both bridges connected")
        ok("both bridges connected")
        run_assertions(pin, A, B, a_tok, b_tok, session, stamp, ha, aa, hb, ab)
    finally:
        for p in bridges:
            p.terminate()


def run_assertions(pin, A, B, a_tok, b_tok, session, stamp, ha, aa, hb, ab):
    mirror_b_on_a = wait_until(
        lambda: next((a for a in A.agents() if a["external_id"] == "pin:beta:b-agent"), None),
        CROSS_MIRROR_TIMEOUT, "b-agent mirrored on bus A")
    ok("cross-mirroring: b-agent visible on bus A")
    mirror_a_on_b = wait_until(
        lambda: next((a for a in B.agents() if a["external_id"] == "pin:alpha:a-agent"), None),
        CROSS_MIRROR_TIMEOUT, "a-agent mirrored on bus B")
    ok("cross-mirroring: a-agent visible on bus B")

    # --- direct message A -> B ---
    conv = A.tool("open_conversation", {"harness_id": ha, "agent_id": aa["agent_id"],
                                        "title": "direct", "project_key": "e2e"})["conversation_id"]
    A.send(ha, aa["agent_id"], conv, f"direct-{stamp}", "direct alpha to beta",
           recipient=mirror_b_on_a["id"])
    hit = wait_until(lambda: [m for m in B.exact("direct alpha to beta")], DELIVERY_TIMEOUT,
                     "direct A->B message")
    ok(f"direct A->B delivered (bus B id {hit[0]['id']})")

    # --- direct message B -> A (new conversation from B) ---
    conv_b = B.tool("open_conversation", {"harness_id": hb, "agent_id": ab["agent_id"],
                                          "title": "reply", "project_key": "e2e"})["conversation_id"]
    B.send(hb, ab["agent_id"], conv_b, f"reply-{stamp}", "direct beta to alpha",
           recipient=mirror_a_on_b["id"])
    wait_until(lambda: [m for m in A.exact("direct beta to alpha")], DELIVERY_TIMEOUT,
               "direct B->A message")
    ok("direct B->A delivered")

    # --- broadcast A -> B ---
    conv2 = A.tool("open_conversation", {"harness_id": ha, "agent_id": aa["agent_id"],
                                         "title": "broadcast", "project_key": "e2e"})["conversation_id"]
    bcast_body = f"broadcast from alpha {stamp}"
    A.send(ha, aa["agent_id"], conv2, f"bc-{stamp}", bcast_body)
    wait_until(lambda: [m for m in B.exact(bcast_body)], DELIVERY_TIMEOUT,
               "broadcast A->B")
    ok("broadcast A->B delivered")

    # --- duplicate client_message_id is not re-delivered ---
    A.send(ha, aa["agent_id"], conv2, f"bc-{stamp}", bcast_body)
    time.sleep(DELIVERY_TIMEOUT)
    n = len([m for m in B.exact(bcast_body)])
    assert_(n == 1, f"duplicate cmid not re-delivered (count={n})")

    # --- late-registered agent (regression: unknown sender at poll time) ---
    # The agent registers AFTER the bridges connected, so the pump's local
    # cache does not know it when the message hits the poll queue; the
    # refresh-on-unknown-sender path must deliver it anyway.
    h2 = A.tool("register_harness", {"installation_key": f"e2e-late-{stamp}",
                                     "name": "Late harness"})["harness_id"]
    late = A.tool("register_agent", {"harness_id": h2, "external_id": "late-agent",
                                     "name": "Late Agent"})
    A.tool("agent_online", {"harness_id": h2, "agent_id": late["agent_id"]})
    conv3 = A.tool("open_conversation", {"harness_id": h2, "agent_id": late["agent_id"],
                                         "title": "late", "project_key": "e2e"})["conversation_id"]
    late_body = f"late agent checking in {stamp}"
    A.send(h2, late["agent_id"], conv3, f"late-{stamp}", late_body)
    wait_until(lambda: [m for m in B.exact(late_body)], CROSS_MIRROR_TIMEOUT,
               "late-agent message on bus B")
    ok("late-registered agent delivered (poll-time sender refresh)")

    # --- human chat via the web form fallback is visible to both buses ---
    human_body = f"human hello {stamp}"
    human_post(session["room_id"], f"e2e-a-{stamp}", "alpha passphrase 123",
               "broadcast", human_body)
    wait_until(lambda: [m for m in A.exact(human_body)], DELIVERY_TIMEOUT, "human msg on bus A")
    ok("human chat visible on bus A")
    wait_until(lambda: [m for m in B.exact(human_body)], DELIVERY_TIMEOUT, "human msg on bus B")
    ok("human chat visible on bus B")

    # --- status propagation both ways (status_message carries the text) ---
    B.tool("set_status", {"harness_id": hb, "agent_id": ab["agent_id"],
                          "status": "crunching the billing export"})
    wait_until(lambda: A.find("pin:beta:b-agent") and
               A.find("pin:beta:b-agent")["status_message"] == "crunching the billing export",
              CROSS_MIRROR_TIMEOUT, "status_message on mirror")
    ok("set_status text propagates to mirror")

    B.tool("agent_offline", {"harness_id": hb, "agent_id": ab["agent_id"]})
    wait_until(lambda: A.find("pin:beta:b-agent") and
               A.find("pin:beta:b-agent")["status"] == "offline",
              CROSS_MIRROR_TIMEOUT, "offline on mirror")
    ok("agent_offline propagates to mirror")

    # --- pin_status sees both bridges ---
    st = pin.status(a_tok, session["room_id"])
    assert_(set(st["bridges"]) == {"alpha", "beta"}, f"pin_status bridges {st['bridges']}")

    # --- pin_stop: owner leaving tears the pin down for everyone ---
    assert_(pin.tool("pin_stop", {"token": a_tok, "room_id": session["room_id"]}) == {"left": True},
            "pin_stop succeeds")
    gone = pin.status(b_tok, session["room_id"])
    assert_(gone.get("error") == "unknown pin", f"room deleted after owner leave: {gone}")
    ok("pin_stop teardown cascades")

    print(f"E2E OK ({checks} checks)")


def human_post(room_id, username, passphrase, title, body):
    """Log in as a browser user and post into the pin conversation titled `title`.

    Exercises the HTTP form fallback: home page CSRF -> POST /login (session
    cookie) -> GET /pins/<id> (find the conversation link) -> POST message.
    """
    import http.cookiejar
    import re
    import urllib.parse

    cj = http.cookiejar.CookieJar()
    op = urllib.request.build_opener(urllib.request.HTTPCookieProcessor(cj))

    def get(path):
        with op.open(CLOTHESPIN + path) as r:
            return r.read().decode()

    def post(path, fields, csrf):
        data = "_csrf_token=" + urllib.parse.quote(csrf)
        for k, v in fields.items():
            data += "&" + k + "=" + urllib.parse.quote(str(v))
        req = urllib.request.Request(
            CLOTHESPIN + path, data=data.encode(),
            headers={"Content-Type": "application/x-www-form-urlencoded"})
        try:
            return op.open(req).read().decode()
        except urllib.error.HTTPError as e:
            fail("human post", f"{path} -> {e.code}")

    home = get("/")
    csrf = re.search(r'name="_csrf_token" value="([^"]+)"', home).group(1)
    post("/login", {"username": username, "passphrase": passphrase}, csrf)

    room_html = get(f"/pins/{room_id}")
    m = re.search(rf'cid=([0-9a-f-]+)[^>]*>[^<]*{re.escape(title)}', room_html) \
        or re.search(rf'{re.escape(title)}.*?cid=([0-9a-f-]+)', room_html, re.S)
    if not m:
        fail("human post", f"conversation '{title}' not found on room page")
    cid = m.group(1)

    csrf2 = re.search(r'name="_csrf_token" value="([^"]+)"', room_html).group(1)
    post(f"/pins/{room_id}/conversations/{cid}/messages",
         {"body": body, "client_message_id": f"human-{int(time.time()*1000)}"}, csrf2)


if __name__ == "__main__":
    main()
