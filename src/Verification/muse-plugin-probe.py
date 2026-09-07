"""Live native Muse checks. Builds an isolated plugin/backend, using a temporary private login.

Run: python3 src/Verification/muse-plugin-probe.py
Requires Go, the bundled backend, and a logged-in Muse CLI account in macOS Keychain.
No credentials or raw provider responses are printed. The temporary login is deleted on exit.
"""
import json
import os
import pathlib
import socket
import subprocess
import tempfile
import time
import urllib.error
import urllib.request

ROOT = pathlib.Path(__file__).resolve().parents[2]


def verify(base):
    def call(path, payload):
        request = urllib.request.Request(base + path, data=json.dumps(payload).encode(),
                                         headers={"Content-Type": "application/json"})
        return urllib.request.urlopen(request, timeout=90)

    common = {"model": "muse-spark-1.3", "max_output_tokens": 1024,
              "reasoning": {"effort": "minimal"}}
    for streaming in (False, True):
        with call("/v1/responses", dict(common, input="Reply only MUSE_PLUGIN_OK.", stream=streaming)) as response:
            content = response.read()
            assert b"MUSE_PLUGIN_OK" in content
            if streaming:
                assert b"response.completed" in content
            else:
                body = json.loads(content)
                assert body["status"] == "completed"
                assert body["usage"]["output_tokens"] <= 1024
        print("PASS: Responses streaming=" + str(streaming), flush=True)

    tools = [{"type": "function", "name": "probe_echo", "description": "Echo a value",
              "parameters": {"type": "object", "properties": {"value": {"type": "string"}},
                             "required": ["value"], "additionalProperties": False}}]
    initial = [{"role": "user", "content": "Call probe_echo with value MUSE_TOOL_OK. After its result, reply with the exact value."}]
    tool_common = dict(common, tools=tools, tool_choice="auto", max_output_tokens=2048)
    with call("/v1/responses", dict(tool_common, input=initial)) as response:
        first = json.load(response)
    function = next(item for item in first["output"] if item["type"] == "function_call")
    assert function["name"] == "probe_echo"
    assert json.loads(function["arguments"]) == {"value": "MUSE_TOOL_OK"}
    tool_result = {"type": "function_call_output", "call_id": function["call_id"], "output": "MUSE_TOOL_OK"}
    with call("/v1/responses", dict(tool_common, input=initial + first["output"] + [tool_result])) as response:
        assert "MUSE_TOOL_OK" in json.dumps(json.load(response)["output"])
    print("PASS: complete automatic tool round trip", flush=True)
    try:
        call("/v1/responses", dict(common, input="Reply OK", tools=tools, tool_choice="required"))
    except urllib.error.HTTPError as error:
        assert error.code == 400
        assert b"automatic tool choice" in error.read()
    else:
        raise AssertionError("Forced tool choice should fail")
    print("PASS: forced tool choice returns HTTP 400", flush=True)


def main():
    with tempfile.TemporaryDirectory(prefix="muse-plugin-") as directory:
        folder = pathlib.Path(directory)
        plugins = folder / "plugins"
        plugins.mkdir()
        subprocess.run(["go", "build", "-buildmode=c-shared", "-o", str(plugins / "muse.dylib"), "."],
                       cwd=ROOT / "muse-plugin", check=True)
        auth = folder / "auth"
        auth.mkdir(mode=0o700)
        secret = json.loads(subprocess.check_output([
            "security", "find-generic-password", "-s", "ai.meta.dev.credentials", "-a", "meta", "-w"]))
        with os.fdopen(os.open(auth / "muse.json", os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600), "w") as output:
            json.dump({"type": "muse", "access_token": secret["access_token"], "email": "probe@example.com"}, output)
        with socket.socket() as sock:
            sock.bind(("127.0.0.1", 0))
            port = sock.getsockname()[1]
        config = folder / "config.json"
        config.write_text(json.dumps({"host": "127.0.0.1", "port": port, "auth-dir": str(auth),
            "request-retry": 0, "remote-management": {"secret-key": "isolated-test", "disable-control-panel": True},
            "plugins": {"enabled": True, "dir": str(plugins), "configs": {"muse": {"enabled": True}}}}))
        backend = subprocess.Popen([str(ROOT / "src/Sources/Resources/cli-proxy-api-plus"), "-config", str(config)],
                                   cwd=folder, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        base = f"http://127.0.0.1:{port}"
        try:
            for _ in range(100):
                if backend.poll() is not None:
                    raise RuntimeError("Backend exited before model registration")
                try:
                    with urllib.request.urlopen(base + "/v1/models", timeout=1) as response:
                        if any(m["id"] == "muse-spark-1.3" for m in json.load(response)["data"]):
                            break
                except OSError:
                    pass
                time.sleep(0.1)
            else:
                raise RuntimeError("Muse model was not registered")
            verify(base)
            headers = {"Authorization": "Bearer isolated-test", "Content-Type": "application/json"}
            with urllib.request.urlopen(urllib.request.Request(base + "/v0/management/auth-files", headers=headers)) as response:
                accounts = response.read()
            assert secret["access_token"].encode() not in accounts
            account = next(a for a in json.loads(accounts)["files"] if a["provider"] == "muse")
            payload = {"auth_index": account["auth_index"], "method": "POST", "url": "https://api.meta.ai/muse-code/key",
                       "header": {"Authorization": "Bearer $TOKEN$", "Content-Type": "application/json", "x-api-version": "1.0.0"}, "data": "{}"}
            req = urllib.request.Request(base + "/v0/management/api-call", headers=headers, data=json.dumps(payload).encode())
            with urllib.request.urlopen(req, timeout=30) as response:
                result = json.load(response)
            assert result["status_code"] == 200
            usage = json.loads(result["body"])["subs_usage"]
            assert usage["window"]["window_duration_mins"] == 300
            assert 0 <= usage["weekly"]["used_percent"] <= 100
            print("PASS: management usage and sanitized account listing", flush=True)
        finally:
            backend.terminate()
            try:
                backend.wait(timeout=10)
            except subprocess.TimeoutExpired:
                backend.kill()
                backend.wait()


if __name__ == "__main__":
    main()
