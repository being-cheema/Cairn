#!/usr/bin/env python3
"""The Local Dev Bridge (DevBridge.swift), in a hidden probe, through the
real cairn-mcp.

Build first (`./build.sh`), then `python3 Tests/agent_devbridge.py`. The
local site is "localhost"; the public web is stood in for by 127.0.0.1, which
the test run lets agents reach. The switch is turned on with the bench's
`devbridge grant`, past the click; the press with no click behind it is
checked to be ignored. Checked:

  - without the bridge the local site is refused, and the tools say bridge_off;
  - a press with no click, Developer Mode and a private tab turn nothing on;
  - with it, the agent's own tab reads the console errors and failed requests,
    redacted, assert_layout finds what is wrong, and both resources answer;
  - the tab it was turned on from is never read;
  - another port is refused, to open and to fetch; its own grant lets the
    fetch through;
  - a public page's link, a redirect, and the app bounced off a public page
    can't take the agent's tab in;
  - closing the tab it was turned on from shuts the agent out;
  - once you have had the agent's tab, nothing more is read;
  - a task that ends leaves nothing of the bridge on its tabs.
"""

import json
import subprocess
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import split_view as sv  # noqa: E402

sv.use("agent-devbridge")
ROOT = Path(__file__).resolve().parents[1]
VERBOSE = "-v" in sys.argv
HITS = []
PORTS = {}

APP = """<h1>App</h1>
<script>
console.error('boom: save failed token=abc123secret');
console.warn('careful', {password: 'pa55word'});
fetch('/missing?key=s3cretkey#hashpart77');
var x = new XMLHttpRequest(); x.open('POST', '/fail?sig=sig999'); x.send('card=4111111111111111');
setTimeout(function () { throw new Error('uncaught kaboom') }, 50);
</script>
<img src="/nope.png?sig=imgsig42" alt="">
<a href="/two">two</a> <a href="PUBLIC/bounce">bounce</a>
<label>Password <input type="password" value="hunter2hunter2"></label>
<button style="position:absolute;left:10px;top:300px;width:120px;height:40px">Save</button>
<button style="position:absolute;left:20px;top:305px;width:120px;height:40px">Delete</button>
<div style="width:5000px;height:4px;background:#000">wide</div>
<div style="width:60px;white-space:nowrap;overflow:hidden">A long line of text that is cut off here</div>
<button onclick="fetch('OTHER/api', {mode:'no-cors'}).then(()=>document.title='reached',()=>document.title='stopped')">Call API</button>
"""


def page_for(name, path):
    local = f"http://localhost:{PORTS['app']}"
    if name == "app":
        if path == "/":
            return 200, "App", APP.replace("PUBLIC", f"http://127.0.0.1:{PORTS['public']}").replace(
                "OTHER", f"http://localhost:{PORTS['other']}"), None
        if path == "/two":
            return 200, "Two", "<p>two<script>console.error('on two')</script>", None
        if path == "/fail":
            return 500, "no", "no", None
        if path == "/delete":
            return 200, "Deleted", "<p>deleted", None
    if name == "other":
        return 200, "api", "ok", None
    if name == "public":
        if path == "/links":
            return 200, "Links", f"<a href='{local}/delete'>trap</a>", None
        if path in ("/redirect", "/bounce"):
            return 302, "", "", f"{local}/delete"
    return 404, "Not found", "<p>nothing here", None


def serve(name):
    class Page(BaseHTTPRequestHandler):
        def respond(self):
            path = self.path.split("?")[0]
            if path != "/favicon.ico":
                HITS.append((name, path))
            status, title, body, location = page_for(name, path)
            data = f"<!doctype html><title>{title}</title>{body}".encode()
            self.send_response(status)
            if location:
                self.send_header("Location", location)
            self.send_header("Content-Type", "text/html; charset=utf-8")
            self.send_header("Content-Length", str(len(data)))
            self.end_headers()
            self.wfile.write(data)

        def do_GET(self):
            self.respond()

        def do_POST(self):
            self.rfile.read(int(self.headers.get("Content-Length", 0)))
            self.respond()

        def log_message(self, *a):
            pass

    server = ThreadingHTTPServer(("127.0.0.1", 0), Page)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    PORTS[name] = server.server_port


for each in ("app", "other", "public"):
    serve(each)
LOCAL = f"http://localhost:{PORTS['app']}"
OTHER = f"http://localhost:{PORTS['other']}"
PUBLIC = f"http://127.0.0.1:{PORTS['public']}"


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

    def reply(self, n):
        out = json.loads(self.p.stdout.readline())
        assert out["id"] == n, out
        if VERBOSE:
            print("   →", json.dumps(out)[:300])
        return out

    def rpc(self, method, params=None):
        return self.reply(self.send(method, params)).get("result")

    def call(self, which, **args):
        return self.send("tools/call", {"name": which, "arguments": args})

    def result(self, n):
        out = self.reply(n)["result"]
        return json.loads(out["content"][0]["text"]), bool(out.get("isError"))

    def tool(self, which, approve=True, **args):
        """The call, approving whatever is held for it (a move to another site)."""
        n = self.call(which, **args)
        stop = threading.Event()

        def answer():
            while not stop.wait(0.2):
                try:
                    if approve and agents().get("held"):
                        agents("approve")
                except Exception:
                    pass

        watcher = threading.Thread(target=answer, daemon=True)
        watcher.start()
        try:
            return self.result(n)
        finally:
            stop.set()
            watcher.join()

    def resource(self, uri):
        return self.reply(self.send("resources/read", {"uri": uri}))

    def close(self):
        try:
            self.p.stdin.close()
            self.p.wait(5)
        except Exception:
            self.p.kill()
        try:
            import os
            os.killpg(self.p.pid, 9)
        except OSError:
            pass


def agents(action="state", **f):
    return sv.cmd({"do": "agents", "action": action, **f})


def bridge(id, action="state"):
    return sv.cmd({"do": "devbridge", "id": id, "action": action})


def until(check, within=12):
    end = time.time() + within
    while time.time() < end:
        if check():
            return True
        time.sleep(0.15)
    return False


def code(x):
    return x.get("error", {}).get("code") if isinstance(x, dict) else None


def node(read, role, name):
    return next((n for n in read.get("nodes", []) if n["role"] == role and n["name"] == name), None)


def asked(name, path):
    return (name, path) in HITS


t = sv.T()


def main():
    a = None
    try:
        sv.setup(**{"agents": True, "developer.local": True})
        subprocess.run(["defaults", "write", sv.SUITE, "test.agentLocalHosts", "-array", "127.0.0.1"], check=True)
        sv.launch()

        def user_tab(address):
            tab = sv.cmd({"do": "open", "url": address})["id"]
            t.ok(f"the person's tab loads {address}", until(lambda: bridge(tab).get("offer")), bridge(tab))
            return tab

        mine = user_tab(f"{LOCAL}/two")
        del HITS[:]

        a = Client()
        n = a.call("open_tab", url=f"{PUBLIC}/links")
        t.ok("the connection is asked about", until(lambda: agents().get("state") == "asking"), agents())
        agents("allow", tabs=True)
        opened, err = a.result(n)
        t.ok("allowed: its tab opens", not err and opened.get("page") == "p1", opened)

        def read(page="p1"):
            return a.tool("read_page", page=page)[0]

        # ---- nothing without the bridge
        x, err = a.tool("open_tab", url=f"{LOCAL}/")
        t.ok("the local site is refused", err and code(x) == "private_address", x)
        for tool in ("read_console", "read_network_errors", "assert_layout"):
            x, err = a.tool(tool, page="p1")
            t.ok(f"{tool} says bridge_off", err and code(x) == "bridge_off", x)
        for uri in ("cairn://dev/console", "cairn://dev/network-errors"):
            x = a.resource(uri)
            t.ok(f"{uri} says bridge_off", "bridge_off" in json.dumps(x.get("error", {})), x)

        # ---- what turns nothing on
        st = bridge(mine, "press")
        t.ok("the switch pressed with no click is ignored", st["taken"] is False and st["granted"] == [], st)
        dev = sv.cmd({"do": "devmode", "id": mine, "set": True})
        t.ok("Developer Mode is on and grants nothing", dev["on"] and bridge(mine)["granted"] == [], (dev, bridge(mine)))
        private = sv.cmd({"do": "open", "url": f"{LOCAL}/two", "private": True})["id"]
        time.sleep(1.5)
        st = bridge(private, "grant")
        time.sleep(0.5)
        t.ok("a private tab has no offer and no grant", st["offer"] == "" and bridge(private)["granted"] == [], bridge(private))
        t.ok("and the local site is still refused", code(a.tool("navigate", page="p1", url=f"{LOCAL}/")[0]) == "private_address")

        # ---- on
        bridge(mine, "grant")
        t.ok("turned on for this origin and port", until(lambda: bridge(mine)["granted"] == [LOCAL]), bridge(mine))
        del HITS[:]
        x, err = a.tool("open_tab", url=f"{LOCAL}/")
        t.ok("the agent's tab opens the local site", not err and x.get("title") == "App", x)
        app = x.get("page", "p2")
        time.sleep(1.5)

        said, err = a.tool("read_console", page=app)
        text = json.dumps(said)
        t.ok("console errors, warnings and the uncaught one are read",
             not err and all(w in text for w in ("boom: save failed", "careful", "uncaught kaboom")), said)
        t.ok("redacted", not any(w in text for w in ("abc123secret", "pa55word", "hunter2")), said)
        said, err = a.tool("read_console", page=app, level="warn")
        t.ok("level warn gives warnings alone", "careful" in json.dumps(said) and "boom" not in json.dumps(said), said)
        said, err = a.tool("read_network_errors", page=app)
        text = json.dumps(said)
        t.ok("failed fetch, XHR and image are read",
             not err and all(w in text for w in ("/missing", "404", "/fail", "500", "nope.png")), said)
        t.ok("with no query value, fragment or payload",
             not any(w in text for w in ("s3cretkey", "sig999", "imgsig42", "4111111111111111", "hashpart77")), said)

        said, err = a.tool("assert_layout", page=app)
        text = json.dumps(said, ensure_ascii=False)
        t.ok("assert_layout finds sideways overflow", not err and said.get("horizontalOverflow", {}).get("by", 0) > 1000, said)
        t.ok("the two buttons over each other",
             any("Save" in json.dumps(o) and "Delete" in json.dumps(o) for o in said.get("overlaps", [])), said)
        t.ok("and the clipped line", "A long line" in json.dumps(said.get("clipped", [])), said)
        t.ok("with the page's errors, and nothing typed", "boom" in text and "hunter2" not in text, text[:600])

        for uri, word in (("cairn://dev/console", "boom"), ("cairn://dev/network-errors", "/missing")):
            x = a.resource(uri)
            body = x.get("result", {}).get("contents", [{}])[0].get("text", "")
            t.ok(f"{uri} gives it", word in body and "abc123secret" not in body, x)

        # ---- the tab it was turned on from is never read
        listed, _ = a.tool("list_tabs")
        theirs = next((p["page"] for p in listed["tabs"] if not p["mine"] and p["url"].startswith(LOCAL)), None)
        t.ok("the person's tab is listed", theirs is not None, listed)
        if theirs:
            x, err = a.tool("read_page", page=theirs)
            t.ok("and not read", err and code(x) == "not_yours", x)
            x, err = a.tool("read_console", page=theirs)
            t.ok("nor its console", err and code(x) == "not_yours", x)

        # ---- another port
        x, err = a.tool("open_tab", url=f"{OTHER}/api")
        t.ok("another port is refused", err and code(x) == "private_address", x)
        del HITS[:]
        button = node(read(app), "button", "Call API")
        a.tool("click", element=button["element"])
        a.tool("wait_for", page=app, title="stopped", timeout=8)
        t.ok("and not fetched", not any(h[0] == "other" for h in HITS) and read(app).get("title") == "stopped", HITS)
        api = user_tab(f"{OTHER}/api")
        bridge(api, "grant")
        t.ok("its own grant", until(lambda: len(bridge(api)["granted"]) == 2), bridge(api))
        time.sleep(1.0)
        a.tool("navigate", page=app, url=f"{LOCAL}/")
        del HITS[:]
        a.tool("click", element=node(read(app), "button", "Call API")["element"])
        t.ok("then the fetch gets through", until(lambda: asked("other", "/api")), HITS)
        sv.cmd({"do": "close", "id": api})
        t.ok("closed, that grant is gone and the app's stays", until(lambda: bridge(mine)["granted"] == [LOCAL]), bridge(mine))

        # ---- public pages can't take it in
        del HITS[:]
        x, err = a.tool("navigate", page="p1", url=f"{PUBLIC}/links")
        a.tool("click", element=node(read(), "link", "trap")["element"])
        time.sleep(1.2)
        t.ok("a public page's link is refused", not asked("app", "/delete"), HITS)
        a.tool("navigate", page="p1", url=f"{PUBLIC}/redirect")
        time.sleep(1.2)
        t.ok("a public redirect is refused", asked("public", "/redirect") and not asked("app", "/delete"), HITS)
        x, err = a.tool("navigate", page="p1", url=f"{LOCAL}/two")
        t.ok("asked for, from a public page, it is let in", not err and x.get("title") == "Two", x)
        a.tool("navigate", page=app, url=f"{LOCAL}/")
        del HITS[:]
        a.tool("click", element=node(read(app), "link", "bounce")["element"])
        time.sleep(1.5)
        t.ok("the app bounced off a public page doesn't come back in",
             asked("public", "/bounce") and not asked("app", "/delete"), HITS)

        # ---- the tab it was turned on from closes
        a.tool("navigate", page=app, url=f"{LOCAL}/")
        sv.cmd({"do": "close", "id": mine})
        time.sleep(1.0)
        x, err = a.tool("read_console", page=app)
        t.ok("closed: the agent reads nothing more", err and code(x) == "bridge_off", x)
        x = read(app)
        t.ok("its page of that site is gone", "Call API" not in json.dumps(x), x)
        x, err = a.tool("navigate", page=app, url=f"{LOCAL}/")
        t.ok("and the site is refused again", err and code(x) == "private_address", x)

        # ---- after the baton
        mine = user_tab(f"{LOCAL}/two")
        bridge(mine, "grant")
        until(lambda: bridge(mine)["granted"] == [LOCAL])
        x, err = a.tool("navigate", page=app, url=f"{LOCAL}/")
        t.ok("on again", not err and x.get("title") == "App", x)
        time.sleep(1.0)
        said, err = a.tool("read_console", page=app)
        t.ok("and read again", not err and "boom" in json.dumps(said), said)
        x, err = a.tool("wait_for_sign_in", page=app)
        t.ok("the tab handed to the person and back", not err and x.get("resumed") is True, x)
        for tool in ("read_console", "read_network_errors", "assert_layout"):
            x, err = a.tool(tool, page=app)
            t.ok(f"after that, {tool} is refused", err and code(x) == "bridge_off", x)
        x = a.resource("cairn://dev/console")
        t.ok("and the resource", "bridge_off" in json.dumps(x.get("error", {})), x)

        # ---- a task that ends leaves nothing of the bridge behind
        a.tool("disconnect")
        t.ok("the task ends and its tabs are handed over", until(lambda: agents().get("handed")), agents())
        left = agents().get("handed", [])
        t.ok("its tabs, handed over, carry none of it",
             left and all(not h["dressed"] and h["heard"] == 0 for h in left), left)
        # A grant is for the task it was given to: it ends with it, so no
        # later client has it without the person's click.
        t.ok("the grant ends with the task", bridge(mine)["granted"] == [], bridge(mine))
    finally:
        if a:
            a.close()
        t.done()
        sv.finish()
    sys.exit(1 if t.failed else 0)


if __name__ == "__main__":
    main()
