"""Exercise native HTTP against an ephemeral local fixture, never the user's Anki."""
import json
import subprocess
import sys
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

actions = []
failures = []


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *_):
        pass

    def do_POST(self):
        if "fail=1" in self.path:
            self.send_response(503)
            self.end_headers()
            return
        try:
            assert self.path == "/anki?fixture=1"
            data = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
            assert data["version"] == 6 and data["key"] == "test-key"
            assert isinstance(data["params"], dict), "params must be a JSON object"
            action = data["action"]
            actions.append(action)
            result, error = None, None
            if action == "version":
                result = 6
            elif action == "deckNames":
                result = ["日本語"]
            elif action == "modelNames":
                result = ["Japanese"]
            elif action == "modelFieldNames":
                assert data["params"]["modelName"] == "Japanese"
                result = ["Expression", "Meaning"]
            elif action == "addNote":
                note = data["params"]["note"]
                assert note["deckName"] == "日本語" and note["modelName"] == "Japanese"
                assert note["fields"] == {
                    "Expression": "日本",
                    "Meaning": "にほん<br><br>Japan &amp; &lt;country&gt;<br><br>日本へ行く。",
                }
                assert note["options"]["allowDuplicate"] is False
                assert note["tags"] == ["touitsu"]
                if actions.count(action) == 1:
                    result = 1700000000123
                else:
                    error = "cannot create note because it is a duplicate"
            elif action == "guiBrowse":
                assert data["params"]["query"] == "nid:1700000000123"
                result = [1700000000456]
            elif action == "malformed":
                self.send_response(200)
                self.end_headers()
                self.wfile.write(b"not json")
                return
            else:
                raise AssertionError(action)
            response = json.dumps({"result": result, "error": error}, ensure_ascii=False).encode()
            self.send_response(200)
            self.send_header("Content-Length", str(len(response)))
            self.end_headers()
            self.wfile.write(response)
        except Exception as exc:
            failures.append(repr(exc))
            self.send_error(500)


with ThreadingHTTPServer(("127.0.0.1", 0), Handler) as server:
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    try:
        subprocess.run([sys.argv[1], f"http://127.0.0.1:{server.server_port}/anki?fixture=1"], check=True, timeout=30)
        assert not failures, failures
        assert actions == ["version", "deckNames", "modelNames", "modelFieldNames", "addNote", "addNote", "guiBrowse", "malformed"], actions
        print("Anki mock HTTP flow passed.")
    finally:
        server.shutdown()
