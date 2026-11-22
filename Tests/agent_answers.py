#!/usr/bin/env python3
"""What an agent's answers carry (AgentControl), in a hidden probe.

Build first (`./build.sh`), then `python3 Tests/agent_answers.py`. On pages
served from 127.0.0.1:

  - a page's alert and confirm in an agent's tab are answered as dismissed at
    once, and the next answer tells the agent what they said (no 60 s wait);
  - a tab a page opens is listed in `new_tabs`, already the agent's own;
  - every answer says how long it took (`ms`);
  - a long page is read in pieces: `nodesTruncated` with `nextNodeOffset`, and
    `textTruncated` with `nextTextOffset`, paging through to the end without
    repeating; `viewport_only` returns only what is on screen.
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

sv.use("agent-answers")
ROOT = Path(__file__).resolve().parents[1]
VERBOSE = "-v" in sys.argv

LINKS = "".join(f'<p><a href="#n{i}">link {i}</a></p>' for i in range(120))
WORDS = " ".join(f"word{i}" for i in range(1500))
PAGES = {
    "/dialog": "<h1>Dialogs</h1><script>alert('hello there'); var c = confirm('are you sure?'); document.title = 'confirm=' + c;</script>",
    "/popup": "<h1>Popup</h1><button onclick=\"window.open('/plain')\">Open it</button>",
    "/plain": "<h1>Plain</h1>",
    "/long": f"<h1>Long</h1>{LINKS}<p>{WORDS}</p>",
}


class Page(BaseHTTPRequestHandler):
    def do_GET(self):
        data = f"<!doctype html><title>t</title>{PAGES.get(self.path.split('?')[0], '<p>x</p>')}".encode()
        self.send_response(200)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

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


def agents(action="state", **f):
    return sv.cmd({"do": "agents", "action": action, **f})


def until(check, within=10):
    end = time.time() + within
    while time.time() < end:
        if check():
            return True
        time.sleep(0.1)
    return False


def node(read, role, name):
    return next((n for n in read["nodes"] if n["role"] == role and n["name"] == name), None)


t = sv.T()


def main():
    a = None
    try:
        sv.setup(**{"agents": True})
        sv.launch()
        a = Client()
        n = a.call("open_tab", url=f"{BASE}/dialog")
        t.ok("the connection is asked about", until(lambda: agents().get("state") == "asking"), agents())
        agents("allow")
        started = time.time()
        opened, err = a.result(n)
        t.ok("a page that alerts and confirms does not hold the call", not err and time.time() - started < 15, (opened, time.time() - started))
        t.ok("every answer says how long it took", isinstance(opened.get("ms"), int), opened)
        read, err = a.tool("read_page", page="p1")
        said = read.get("dialogs", [])
        t.ok("the agent is told what the page asked", [d["kind"] for d in said] == ["alert", "confirm"], read.get("dialogs"))
        t.ok("with the page's words", said and said[0]["text"] == "hello there" and said[1]["text"] == "are you sure?", said)
        t.ok("and how each was answered", said and said[0]["answered"] == "closed" and said[1]["answered"] == "no", said)
        t.ok("the confirm got no", read.get("title") == "confirm=false", read.get("title"))
        again, _ = a.tool("read_page", page="p1")
        t.ok("told once", "dialogs" not in again, again.get("dialogs"))

        # ---- a tab the page opens
        x, err = a.tool("navigate", page="p1", url=f"{BASE}/popup")
        read, _ = a.tool("read_page", page="p1")
        x, err = a.tool("click", element=node(read, "button", "Open it")["element"])
        tabs = x.get("new_tabs", [])
        t.ok("a tab the page opened is listed", not err and len(tabs) == 1 and tabs[0]["url"].endswith("/plain"), x)
        mine, _ = a.tool("read_page", page=tabs[0]["page"]) if tabs else ({}, True)
        t.ok("and it is the agent's own: it can be read with handles", any("element" in n for n in mine.get("nodes", [])), mine)
        x, _ = a.tool("list_tabs")
        again, _ = a.tool("read_page", page="p1")
        t.ok("told once", "new_tabs" not in again)

        # ---- reading a long page in pieces
        a.tool("navigate", page="p1", url=f"{BASE}/long")
        first, _ = a.tool("read_page", page="p1", max_nodes=50, max_text=1000)
        t.ok("a long read says it was cut, and where to go on", first.get("nodesTruncated") is True and first.get("nextNodeOffset") == 50, {k: first.get(k) for k in ("nodesTruncated", "nextNodeOffset")})
        t.ok("and the text, with its length", first.get("textTruncated") is True and first.get("nextTextOffset") == 1000 and first.get("textLength", 0) > 5000, {k: first.get(k) for k in ("textTruncated", "nextTextOffset", "textLength")})
        names = [n["name"] for n in first["nodes"]]
        second, _ = a.tool("read_page", page="p1", max_nodes=50, node_offset=50, max_text=1000, text_offset=1000)
        names2 = [n["name"] for n in second["nodes"]]
        t.ok("the next piece starts where the last ended", not set(names) & set(names2) and names2[0] == "link 49", (names[-2:], names2[:2]))
        t.ok("and the text goes on from the same place", second["text"] != first["text"] and second.get("textOffset") == 1000, second.get("text", "")[:40])
        seen = set(names) | set(names2)
        offset = 100
        while True:
            more, _ = a.tool("read_page", page="p1", max_nodes=50, node_offset=offset, text=False)
            seen |= {n["name"] for n in more["nodes"]}
            if not more.get("nodesTruncated"):
                break
            offset = more["nextNodeOffset"]
        t.ok("paging reaches every link, none lost", all(f"link {i}" in seen for i in range(120)), len(seen))
        view, _ = a.tool("read_page", page="p1", viewport_only=True, text=False)
        t.ok("viewport_only is only what is on screen", 0 < len(view["nodes"]) < 120 and all(n.get("inView") for n in view["nodes"]), len(view["nodes"]))
    finally:
        if a:
            a.close()
        t.done()
        sv.finish()
    sys.exit(1 if t.failed else 0)


if __name__ == "__main__":
    main()
