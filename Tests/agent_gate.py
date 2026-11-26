#!/usr/bin/env python3
"""Commit gates (AgentGate), in a hidden probe.

Build first (`./build.sh`), then `python3 Tests/agent_gate.py`. With "Ask me
before an agent submits, pays or posts" on, an agent's click or Return that
would commit something waits for the person; the bench's `agents approve` and
`decline` answer as the buttons would. Checked on pages served from 127.0.0.1:

  - a POST form, a payment form (a card field, a button named "Go") and a
    sign-in form each hold their button, and nothing is sent while it waits;
  - the agent's call returns only after the answer: the result when approved,
    "declined" when not, and a decline sends nothing;
  - Approve pressed with no mouse event behind it is ignored;
  - Return is held the same way, and a search (GET) form is not held;
  - typing a new line as keys is refused (Return is for press);
  - a plain button is not held.
(With the setting off, nothing is held: AgentGateTests.)
"""

import json
import os
import subprocess
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import split_view as sv  # noqa: E402

sv.use("agent-gate")
ROOT = Path(__file__).resolve().parents[1]
VERBOSE = "-v" in sys.argv
HITS = []

PAGES = {
    "/post": '<h1>Post</h1><form action="/sent" method="post"><label>Note <input name="note"></label><button>Next</button></form>',
    "/pay": '<h1>Pay</h1><form action="/paid" method="post"><label>Number <input name="n" autocomplete="cc-number"></label><button>Go</button></form>',
    "/login": '<h1>In</h1><form action="/signed" method="post"><label>Name <input name="u"></label><label>Secret <input type="password" name="p"></label><button>Continue</button></form>',
    "/search": '<h1>Find</h1><form action="/found" method="get"><label>Query <input name="q"></label><button>Go</button></form>',
    "/script": '<h1>Script</h1><form id="f" action="/scripted" method="post"><input type="hidden" name="a" value="1"></form>'
               '<button type="button" onclick="document.getElementById(\'f\').submit()">Weiter</button>',
    "/inside": '<h1>Inside</h1><p id="s">waiting</p><script>fetch("http://localhost:PORT/fetched", {mode: "no-cors"})'
               '.then(() => s.textContent = "reached", () => s.textContent = "stopped")</script>',
    "/later": '<h1>Later</h1><script>setInterval(() => fetch("http://localhost:PORT/later-fetched", {mode: "no-cors"}).catch(() => {}), 500)</script>',
    "/plain": '<h1>Plain</h1><button type="button" onclick="document.title=\'clicked\'">Show more</button>',
}


class Page(BaseHTTPRequestHandler):
    def respond(self, body):
        data = f"<!doctype html><title>t</title>{body}".encode()
        self.send_response(200)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self):
        path = self.path.split("?")[0]
        if path == "/redirect":
            self.send_response(302)
            self.send_header("Location", f"http://localhost:{self.server.server_port}/redirected")
            self.send_header("Content-Length", "0")
            return self.end_headers()
        if path in PAGES:
            return self.respond(PAGES[path].replace("PORT", str(self.server.server_port)))
        HITS.append(("GET", self.path))
        self.respond("<p>result</p>")

    def do_POST(self):
        self.rfile.read(int(self.headers.get("Content-Length", 0)))
        HITS.append(("POST", self.path))
        self.respond("<p>sent</p>")

    def log_message(self, *a):
        pass


srv = ThreadingHTTPServer(("127.0.0.1", 0), Page)
threading.Thread(target=srv.serve_forever, daemon=True).start()
BASE = f"http://127.0.0.1:{srv.server_port}"


class Client:
    def __init__(self):
        self.p = subprocess.Popen([str(ROOT / "search-mcp"), "--world", sv.W], stdin=subprocess.PIPE,
                                  stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True, start_new_session=True)
        self.n = 0
        self.rpc("initialize", {"protocolVersion": "2025-06-18", "capabilities": {}, "clientInfo": {"name": "claude-code"}})

    def send(self, method, params=None):
        self.n += 1
        self.p.stdin.write(json.dumps({"jsonrpc": "2.0", "id": self.n, "method": method, "params": params or {}}) + "\n")
        self.p.stdin.flush()
        return self.n

    def answer(self, n):
        out = json.loads(self.p.stdout.readline())
        assert out["id"] == n, out
        return out["result"]

    def rpc(self, method, params=None):
        return self.answer(self.send(method, params))

    def call(self, which, **args):
        return self.send("tools/call", {"name": which, "arguments": args})

    def result(self, n):
        out = self.answer(n)
        if VERBOSE:
            print("   →", json.dumps(out)[:240])
        content = out["content"]
        if len(content) == 1 and content[0]["type"] == "text":
            return json.loads(content[0]["text"]), bool(out.get("isError"))
        return content, bool(out.get("isError"))

    def tool(self, which, **args):
        return self.result(self.call(which, **args))

    def close(self):
        try:
            self.p.stdin.close()
            self.p.wait(5)
        except Exception:
            self.p.kill()
        try:
            os.killpg(self.p.pid, 9)
        except OSError:
            pass


def agents(action="state", **f):
    return sv.cmd({"do": "agents", "action": action, **f})


def until(check, within=10):
    end = time.time() + within
    while time.time() < end:
        if check():
            return True
        time.sleep(0.1)
    return False


def code(x):
    return x.get("error", {}).get("code") if isinstance(x, dict) else None


def node(read, role, name):
    return next((n for n in read["nodes"] if n["role"] == role and n["name"] == name), None)


def hits(kind="POST"):
    return [h for h in HITS if h[0] == kind]


t = sv.T()


def main():
    a = None
    try:
        sv.setup(**{"agents": True})
        subprocess.run(["defaults", "write", sv.SUITE, "test.agentLocalHosts", "-array", "127.0.0.1"], check=True)
        sv.launch()
        a = Client()
        n = a.call("open_tab", url=f"{BASE}/post")
        t.ok("the connection is asked about", until(lambda: agents().get("state") == "asking"), agents())
        agents("allow")
        opened, err = a.result(n)
        t.ok("allowed: its tab opens", not err and opened.get("page") == "p1", opened)

        def read(page="p1"):
            return a.tool("read_page", page=page)[0]

        def go(path):
            x, err = a.tool("navigate", page="p1", url=f"{BASE}{path}")
            assert not err, x

        # ---- a POST form
        form = read()
        n = a.call("click", element=node(form, "button", "Next")["element"])
        t.ok("a POST form's button is held", until(lambda: agents().get("held")), agents())
        st = agents()
        t.ok("said as a form to send", st.get("heldReason") == "submit" and "Next" in st.get("held", ""), st)
        time.sleep(1.0)
        t.ok("nothing is sent while it waits", hits() == [], HITS)
        agents("pressApprove")
        time.sleep(0.5)
        t.ok("Approve with no click behind it is ignored", agents().get("held") and hits() == [], agents())
        agents("decline")
        x, err = a.result(n)
        t.ok("declined: the agent is told", err and code(x) == "declined", x)
        time.sleep(0.8)
        t.ok("declined: nothing was sent", hits() == [], HITS)
        t.ok("and nothing is held any more", agents().get("held") == "")

        form = read()
        n = a.call("click", element=node(form, "button", "Next")["element"])
        t.ok("held again", until(lambda: agents().get("held")))
        agents("approve")
        x, err = a.result(n)
        t.ok("approved: it goes through", not err and x.get("navigated") is True, x)
        t.ok("approved: sent exactly once", until(lambda: len(hits()) == 1), HITS)

        # ---- payment: a card field, and a button that says only "Go"
        del HITS[:]
        go("/pay")
        form = read()
        n = a.call("click", element=node(form, "button", "Go")["element"])
        t.ok("a card form's button is held as a payment", until(lambda: agents().get("heldReason") == "pay"), agents())
        agents("decline")
        x, err = a.result(n)
        t.ok("and declined sends nothing", err and code(x) == "declined" and hits() == [], (x, HITS))

        # ---- sign-in
        go("/login")
        form = read()
        n = a.call("click", element=node(form, "button", "Continue")["element"])
        t.ok("a password form's button is held as a sign-in", until(lambda: agents().get("heldReason") == "signIn"), agents())
        agents("decline")
        a.result(n)

        # ---- Return, and typing a new line as keys
        x, err = a.tool("type", element=node(read(), "textbox", "Name")["element"], text="Ada")
        t.ok("typing into a field is not held", not err and x.get("verified") is True, x)
        x, err = a.tool("type", element=node(read(), "textbox", "Name")["element"], text="a\nb", keys=True)
        t.ok("a new line typed as keys is refused", err and code(x) == "bad_text", x)
        n = a.call("press", page="p1", key="Enter")
        t.ok("Return in the form is held", until(lambda: agents().get("held")), agents())
        t.ok("and does not quote the field's label as what it sends", "Name" not in agents().get("held", ""), agents())
        agents("decline")
        x, err = a.result(n)
        t.ok("Return declined: the agent is told", err and code(x) == "declined", x)
        n = a.call("type", element=node(read(), "textbox", "Name")["element"], text="Ada", submit=True)
        t.ok("typing with submit is held", until(lambda: agents().get("held")), agents())
        agents("decline")
        x, err = a.result(n)
        t.ok("and sends nothing when declined", err and code(x) == "declined" and hits() == [], (x, HITS))

        # ---- waiting for the person is not the page being slow
        go("/post")
        form = read()
        n = a.call("click", element=node(form, "button", "Next")["element"])
        t.ok("held for a long answer", until(lambda: agents().get("held")))
        del HITS[:]
        time.sleep(70)
        t.ok("still waiting after a minute (the agent was not told no_answer)", agents().get("held") != "", agents())
        agents("approve")
        x, err = a.result(n)
        t.ok("approved after a minute: it goes through", not err and x.get("navigated") is True, x)

        # ---- not held
        go("/search")
        form = read()
        x, err = a.tool("type", element=node(form, "textbox", "Query")["element"], text="cats", submit=True)
        t.ok("a search form (GET) is not held", not err and agents().get("held") == "", (x, agents()))
        go("/plain")
        x, err = a.tool("click", element=node(read(), "button", "Show more")["element"])
        t.ok("a plain button is not held", not err and agents().get("held") == "", x)

        # ---- a button that gives nothing away, whose script sends the form:
        # only what leaves shows it
        del HITS[:]
        go("/script")
        n = a.call("click", element=node(read(), "button", "Weiter")["element"])
        t.ok("a script's form.submit() is held as it leaves", until(lambda: agents().get("heldReason") == "submit"), agents())
        time.sleep(1.0)
        t.ok("nothing of it is sent while it waits", hits() == [], HITS)
        agents("decline")
        a.result(n)
        time.sleep(0.8)
        t.ok("declined: the script's form is not sent", hits() == [], HITS)
        go("/script")
        n = a.call("click", element=node(read(), "button", "Weiter")["element"])
        t.ok("held again", until(lambda: agents().get("held")))
        agents("approve")
        a.result(n)
        t.ok("approved: the script's form is sent once", until(lambda: len(hits()) == 1), HITS)

        # ---- this Mac and the network around it ("localhost" is not among
        # the hosts a test run lets through; 127.0.0.1 is)
        del HITS[:]
        x, err = a.tool("navigate", page="p1", url=f"http://localhost:{srv.server_port}/direct")
        t.ok("a private address is refused", err and code(x) == "private_address", x)
        x, err = a.tool("open_tab", url="http://192.168.1.1/")
        t.ok("and not opened", err and code(x) == "private_address", x)
        x, err = a.tool("navigate", page="p1", url=f"{BASE}/redirect")
        t.ok("a redirect inside is not followed, and said", "localhost" in " ".join(x.get("blocked", [])), x)
        go("/inside")
        t.ok("a page's own fetch inside is stopped", until(lambda: "stopped" in json.dumps(read())), read())
        t.ok("nothing reached it", not any(h[1].startswith(("/direct", "/redirected", "/fetched")) for h in HITS), HITS)

        # ---- handed to you, the tab is yours, and so is your own network
        go("/later")
        time.sleep(1.5)
        reached = lambda: any(h[1].startswith("/later-fetched") for h in HITS)
        t.ok("while the agent has it, its fetches inside are stopped", not reached(), HITS)
        a.tool("disconnect")
        t.ok("handed over, the same page reaches your own network again", until(reached), (agents(), HITS))
    finally:
        if a:
            a.close()
        t.done()
        sv.finish()
    sys.exit(1 if t.failed else 0)


if __name__ == "__main__":
    main()
