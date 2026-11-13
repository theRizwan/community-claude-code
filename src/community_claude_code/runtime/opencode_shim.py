"""OpenAI-compatible shim backed by the local ``opencode serve`` session API.

This process exposes:

  GET  /v1/models
  POST /v1/chat/completions   (JSON or SSE)

It reuses or starts ``opencode serve`` on demand, creates a short-lived session
for each request, and asks the free OpenCode models for a plain-text answer. No
account, API key, or signup is required. Every public model name is backed by
its own free OpenCode model, with automatic fallback to the remaining free
models when one fails or is rate limited.
"""

from __future__ import annotations

import argparse
import json
import logging
import os
import shutil
import socket
import subprocess
import sys
import threading
import time
import traceback
import urllib.error
import urllib.request
import uuid
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from logging.handlers import RotatingFileHandler
from pathlib import Path
from typing import Any

LOG = logging.getLogger("ccc.shim")

OPENCODE_SERVE_HOST = "127.0.0.1"
OPENCODE_SERVE_PORT = 4096
SHIM_DEFAULT_PORT = 4097

# Fastest free OpenCode models first. Each public name starts with one of these
# and falls back through the rest in order.
FREE_MODELS: tuple[str, ...] = (
    "opencode/glm-5.3-flash-free",
    "opencode/deepseek-v4.1-flash-free",
    "opencode/mimo-v2.6-flash-free",
    "opencode/flint-40b-free",
    "opencode/big-pickle",
    "opencode/iceman-free",
    "opencode/minimax-m3.1-flash-free",
    "opencode/longcat-2.5-free",
    "opencode/nemotron-3.5-super-vl-free",
    "opencode/nemotron-3.5-lightning-free",
    "opencode/beam-free",
    "opencode/inkling-2-small-free",
)

DEFAULT_MODEL_BACKENDS: dict[str, str] = {
    "fable-5-free": "opencode/glm-5.3-flash-free",
    "opus-4.5-free": "opencode/deepseek-v4.1-flash-free",
    "sonnet-4.5-free": "opencode/mimo-v2.6-flash-free",
    "haiku-4.5-free": "opencode/flint-40b-free",
    "opus-5.5": "opencode/deepseek-v4.1-flash-free",
}

DEFAULT_PUBLIC_MODEL = "fable-5-free"

DEFAULT_TOOL_IDS = [
    "invalid",
    "question",
    "bash",
    "read",
    "glob",
    "grep",
    "edit",
    "write",
    "task",
    "webfetch",
    "todowrite",
    "websearch",
    "skill",
    "apply_patch",
]
SAFETY_SUFFIX = (
    "You are answering in a plain-text chat interface. "
    "Never call or use tools. Answer the user's latest message directly."
)
MAX_TRANSCRIPT_CHARS = 96_000


def build_default_chains() -> dict[str, list[tuple[str, str]]]:
    """Return the public-model to free-backend chain mapping."""

    chains: dict[str, list[tuple[str, str]]] = {}
    for public, primary in DEFAULT_MODEL_BACKENDS.items():
        ordered = [primary, *(model for model in FREE_MODELS if model != primary)]
        chains[public] = [_split_ref(model) for model in ordered]
    return chains


def _split_ref(value: str) -> tuple[str, str]:
    provider, separator, model = value.strip().partition("/")
    if not separator or not provider or not model:
        raise ValueError(f"Expected provider/model, got {value!r}")
    return provider, model


class UpstreamError(RuntimeError):
    def __init__(self, message: str, *, status: int = 502) -> None:
        super().__init__(message)
        self.status = status


class OpenCodeServer:
    def __init__(self, *, binary: str, port: int, log_path: Path) -> None:
        self.binary = binary
        self.port = port
        self.log_path = log_path
        self.process: subprocess.Popen[bytes] | None = None
        self._lock = threading.Lock()

    @property
    def base_url(self) -> str:
        return f"http://{OPENCODE_SERVE_HOST}:{self.port}"

    def healthy(self, *, timeout: float = 1.5) -> bool:
        try:
            with urllib.request.urlopen(
                f"{self.base_url}/global/health", timeout=timeout
            ) as response:
                payload = json.loads(response.read().decode("utf-8"))
        except Exception:
            return False
        return bool(payload.get("healthy"))

    def ensure_started(self, *, wait_seconds: float = 45.0) -> None:
        with self._lock:
            if self.healthy():
                LOG.info("Reusing existing opencode server on port %s", self.port)
                return
            if _port_in_use(self.port):
                raise UpstreamError(
                    f"Port {self.port} is already used by another program, but it is not "
                    "OpenCode 1.19.x. Stop that program (for example the OpenCode 2 "
                    "server) and try again.",
                    status=503,
                )
            if not self.binary or not Path(self.binary).is_file():
                raise UpstreamError(
                    "OpenCode 1 binary not found. Install opencode-ai 1.19.x.",
                    status=503,
                )
            self.log_path.parent.mkdir(parents=True, exist_ok=True)
            log_file = open(self.log_path, "ab", buffering=0)
            creationflags = 0
            if os.name == "nt":
                creationflags = (
                    subprocess.CREATE_NO_WINDOW
                    | subprocess.CREATE_NEW_PROCESS_GROUP
                )
            LOG.info("Starting opencode serve on port %s: %s", self.port, self.binary)
            self.process = subprocess.Popen(
                [
                    self.binary,
                    "serve",
                    "--hostname",
                    OPENCODE_SERVE_HOST,
                    "--port",
                    str(self.port),
                    "--print-logs",
                ],
                stdout=log_file,
                stderr=log_file,
                stdin=subprocess.DEVNULL,
                creationflags=creationflags,
                close_fds=True,
            )
            deadline = time.time() + wait_seconds
            while time.time() < deadline:
                if self.healthy():
                    LOG.info("opencode serve is healthy (pid %s)", self.process.pid)
                    return
                if self.process.poll() is not None:
                    break
                time.sleep(0.2)
            tail = _tail(self.log_path, 4000)
            self.stop()
            raise UpstreamError(
                "opencode serve did not become healthy.\n"
                f"Log: {self.log_path}\n{tail}",
                status=503,
            )

    def stop(self) -> None:
        process = self.process
        self.process = None
        if process is None or process.poll() is not None:
            return
        LOG.info("Stopping opencode serve (pid %s)", process.pid)
        try:
            if os.name == "nt":
                subprocess.run(
                    ["taskkill", "/PID", str(process.pid), "/T", "/F"],
                    capture_output=True,
                    timeout=20,
                    creationflags=subprocess.CREATE_NO_WINDOW,
                    check=False,
                )
            else:
                process.terminate()
                process.wait(timeout=10)
        except Exception:
            LOG.warning("Could not stop opencode serve cleanly", exc_info=True)


def _port_in_use(port: int) -> bool:
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as sock:
        sock.settimeout(0.5)
        return sock.connect_ex((OPENCODE_SERVE_HOST, port)) == 0


def _tail(path: Path, limit: int) -> str:
    try:
        data = path.read_bytes()
    except OSError:
        return ""
    return data[-limit:].decode("utf-8", "replace")


def _find_opencode(explicit: str | None) -> str:
    candidates = [
        explicit,
        os.environ.get("OPENCODE_BIN"),
        shutil.which("opencode"),
        shutil.which("opencode.exe"),
        shutil.which("opencode.cmd"),
        str(Path.home() / ".opencode" / "bin" / "opencode.exe"),
        str(Path(os.environ.get("APPDATA", "")) / "npm" / "opencode.exe"),
    ]
    for candidate in candidates:
        if not candidate or not Path(candidate).is_file():
            continue
        suffix = Path(candidate).suffix.lower()
        if suffix in {".ps1", ".sh"}:
            continue  # not directly spawnable via CreateProcess
        if suffix == ".cmd":
            resolved = (
                Path(candidate).parent
                / "node_modules"
                / "opencode-ai"
                / "bin"
                / "opencode.exe"
            )
            if resolved.is_file():
                return str(resolved)
            continue
        return candidate
    return ""


def _content_to_text(content: Any) -> str:
    if content is None:
        return ""
    if isinstance(content, str):
        return content
    if isinstance(content, dict):
        if isinstance(content.get("text"), str):
            return content["text"]
        if "content" in content:
            return _content_to_text(content["content"])
        return ""
    if isinstance(content, list):
        pieces: list[str] = []
        for part in content:
            if isinstance(part, str):
                pieces.append(part)
            elif isinstance(part, dict):
                kind = part.get("type")
                if kind in (None, "text", "input_text", "output_text"):
                    pieces.append(_content_to_text(part.get("text") or part))
        return "\n".join(piece for piece in pieces if piece)
    return str(content)


def _flatten_messages(messages: Any) -> tuple[str, str]:
    if not isinstance(messages, list):
        raise UpstreamError("messages must be a list", status=400)
    systems: list[str] = []
    lines: list[str] = []
    for message in messages:
        if not isinstance(message, dict):
            continue
        role = str(message.get("role") or "user").lower()
        text = _content_to_text(message.get("content")).strip()
        if role == "system":
            if text:
                systems.append(text)
        elif role == "user":
            lines.append(f"User: {text}")
        elif role == "assistant":
            lines.append(f"Assistant: {text}")
        elif role in {"tool", "function"}:
            lines.append(f"Tool result: {text}")
        else:
            lines.append(f"{role}: {text}")
    transcript = "\n\n".join(line for line in lines if line.strip())
    if not transcript.strip():
        raise UpstreamError("No user message was provided", status=400)
    if len(transcript) > MAX_TRANSCRIPT_CHARS:
        transcript = "[Earlier conversation truncated]\n\n" + transcript[
            -MAX_TRANSCRIPT_CHARS:
        ]
    if transcript.rstrip().endswith("Assistant:"):
        transcript += "\n\n(Continue as the assistant.)"
    return "\n\n".join(systems), transcript


def _build_system(request_system: str) -> str:
    request_system = request_system.strip()
    if len(request_system) > 20_000:
        request_system = request_system[:20_000]
    if request_system:
        return f"{request_system}\n\n{SAFETY_SUFFIX}"
    return f"You are a helpful assistant.\n\n{SAFETY_SUFFIX}"


def _extract_answer(payload: Any) -> tuple[str, dict[str, int]]:
    if not isinstance(payload, dict):
        raise UpstreamError("Unexpected opencode response", status=502)
    info = payload.get("info") or {}
    if not isinstance(info, dict):
        info = {}
    error = info.get("error")
    if error:
        message = error.get("message") if isinstance(error, dict) else str(error)
        raise UpstreamError(f"OpenCode error: {message or error}", status=502)
    parts = payload.get("parts") or []
    texts: list[str] = []
    if isinstance(parts, list):
        for part in parts:
            if not isinstance(part, dict):
                continue
            if part.get("type") == "text" and isinstance(part.get("text"), str):
                texts.append(part["text"])
    answer = "".join(texts).strip()
    if not answer:
        raise UpstreamError("OpenCode returned an empty assistant message", status=502)
    tokens = info.get("tokens") if isinstance(info, dict) else None
    usage: dict[str, int] = {}
    if isinstance(tokens, dict):
        for source, target in (
            ("input", "prompt_tokens"),
            ("output", "completion_tokens"),
            ("total", "total_tokens"),
        ):
            value = tokens.get(source)
            if isinstance(value, int):
                usage[target] = value
    return answer, usage


class Shim:
    def __init__(
        self,
        *,
        opencode: OpenCodeServer,
        chains: dict[str, list[tuple[str, str]]],
        default_public: str,
        attempt_timeout: float = 75.0,
    ) -> None:
        self.opencode = opencode
        self.chains = chains
        self.default_public = default_public
        self.attempt_timeout = attempt_timeout
        self._orders = {name: list(chain) for name, chain in chains.items()}
        self._failed: dict[str, list[tuple[str, str]]] = {
            name: [] for name in chains
        }
        self._order_lock = threading.Lock()
        self._tool_map: dict[str, bool] | None = None
        self._tool_lock = threading.Lock()

    @property
    def public_models(self) -> list[str]:
        return list(self.chains)

    def _public(self, requested: Any) -> str:
        name = requested if isinstance(requested, str) else ""
        if name in self.chains:
            return name
        # Desktop model IDs are hex encoded; fall back to the default chain.
        return self.default_public

    def _demote(self, public: str, model: tuple[str, str]) -> None:
        with self._order_lock:
            order = self._orders[public]
            if model in order:
                order.remove(model)
                self._failed[public].append(model)

    def _promote(self, public: str, model: tuple[str, str]) -> None:
        with self._order_lock:
            failed = self._failed[public]
            if model in failed:
                failed.remove(model)
                self._orders[public].insert(0, model)

    def _api(
        self,
        method: str,
        path: str,
        body: Any | None = None,
        *,
        timeout: float = 300.0,
    ) -> Any:
        url = f"{self.opencode.base_url}{path}"
        data = None
        headers = {"Accept": "application/json"}
        if body is not None:
            data = json.dumps(body).encode("utf-8")
            headers["Content-Type"] = "application/json"
        request = urllib.request.Request(
            url, data=data, method=method, headers=headers
        )
        try:
            with urllib.request.urlopen(request, timeout=timeout) as response:
                raw = response.read().decode("utf-8", "replace")
        except urllib.error.HTTPError as error:
            raw = error.read().decode("utf-8", "replace")
            raise UpstreamError(
                f"opencode {method} {path} failed: HTTP {error.code}: {raw[:2000]}",
                status=502,
            ) from None
        except urllib.error.URLError as error:
            raise UpstreamError(
                f"opencode {method} {path} failed: {error.reason}", status=503
            ) from None
        if not raw.strip():
            return None
        try:
            return json.loads(raw)
        except ValueError:
            return raw

    def _tool_names(self) -> list[str]:
        try:
            payload = self._api("GET", "/experimental/tool/ids", timeout=15)
        except Exception:
            LOG.warning("Could not read tool ids; using built-in list", exc_info=True)
            return list(DEFAULT_TOOL_IDS)
        if isinstance(payload, dict):
            payload = payload.get("ids") or payload.get("data") or []
        if not isinstance(payload, list):
            return list(DEFAULT_TOOL_IDS)
        names = [item for item in payload if isinstance(item, str)]
        return names or list(DEFAULT_TOOL_IDS)

    def tool_map(self) -> dict[str, bool]:
        with self._tool_lock:
            if self._tool_map is None:
                names = self._tool_names()
                for required in ("bash", "read"):
                    if required not in names:
                        names.append(required)
                self._tool_map = {
                    name: name in {"bash", "read"} for name in dict.fromkeys(names)
                }
            return dict(self._tool_map)

    def _ask(
        self, provider: str, model: str, system: str, transcript: str
    ) -> tuple[str, dict[str, int]]:
        session_id: str | None = None
        try:
            session = self._api(
                "POST",
                "/session",
                {
                    "permission": [
                        {"permission": "*", "pattern": "*", "action": "deny"}
                    ]
                },
                timeout=30,
            )
            if not isinstance(session, dict) or not isinstance(
                session.get("id"), str
            ):
                raise UpstreamError("opencode returned no session id", status=502)
            session_id = session["id"]
            payload = self._api(
                "POST",
                f"/session/{session_id}/message",
                {
                    "model": {"providerID": provider, "modelID": model},
                    "system": system,
                    "tools": self.tool_map(),
                    "parts": [{"type": "text", "text": transcript}],
                },
                timeout=self.attempt_timeout,
            )
            return _extract_answer(payload)
        finally:
            if session_id:
                try:
                    self._api("POST", f"/session/{session_id}/abort", timeout=10)
                except Exception:
                    pass
                try:
                    self._api("DELETE", f"/session/{session_id}", timeout=15)
                except Exception:
                    LOG.debug("Could not delete session %s", session_id)

    def complete(
        self, *, model: Any, messages: Any, request_system: str
    ) -> tuple[str, dict[str, int], str]:
        public = self._public(model)
        system, transcript = _flatten_messages(messages)
        if request_system.strip():
            system = f"{system}\n\n{request_system}" if system else request_system
        system = _build_system(system)
        self.opencode.ensure_started()
        with self._order_lock:
            candidates = list(self._orders[public]) + list(self._failed[public])
        last_error: UpstreamError | None = None
        for provider, backend in candidates:
            label = f"{provider}/{backend}"
            try:
                answer, usage = self._ask(provider, backend, system, transcript)
                self._promote(public, (provider, backend))
                LOG.info("Answered %s via %s", public, label)
                return answer, usage, label
            except UpstreamError as error:
                self._demote(public, (provider, backend))
                LOG.warning(
                    "Backend %s failed for %s (%s); trying the next free model",
                    label,
                    public,
                    error,
                )
                last_error = error
        raise last_error or UpstreamError(
            "No free OpenCode model answered", status=502
        )


class Handler(BaseHTTPRequestHandler):
    server_version = "CCCShim/2.0"
    protocol_version = "HTTP/1.1"

    @property
    def shim(self) -> Shim:
        return self.server.shim  # type: ignore[attr-defined]

    def log_message(self, fmt: str, *args: Any) -> None:
        LOG.debug("%s - %s", self.address_string(), fmt % args)

    def _send_json(self, status: int, payload: Any) -> None:
        data = json.dumps(payload).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.send_header("Cache-Control", "no-store")
        self.send_header("Connection", "close")
        self.end_headers()
        self.close_connection = True
        self.wfile.write(data)

    def _read_body(self) -> Any:
        length = int(self.headers.get("Content-Length") or 0)
        if length <= 0:
            return {}
        raw = self.rfile.read(length)
        try:
            return json.loads(raw.decode("utf-8"))
        except ValueError:
            raise UpstreamError("Invalid JSON body", status=400) from None

    def do_GET(self) -> None:  # noqa: N802
        path = self.path.split("?", 1)[0].rstrip("/") or "/"
        if path in {"/health", "/v1/health", "/api/health"}:
            self._send_json(
                200,
                {
                    "ok": True,
                    "opencode": self.shim.opencode.healthy(),
                    "models": {
                        name: [
                            f"{provider}/{model}"
                            for provider, model in self.shim.chains[name]
                        ]
                        for name in self.shim.public_models
                    },
                },
            )
            return
        if path in {"/v1/models", "/models"}:
            self._send_json(
                200,
                {
                    "object": "list",
                    "data": [
                        {
                            "id": name,
                            "object": "model",
                            "created": int(time.time()),
                            "owned_by": "opencode",
                        }
                        for name in self.shim.public_models
                    ],
                },
            )
            return
        if path == "/":
            self._send_json(
                200,
                {
                    "name": "Community Claude Code free model shim",
                    "models": self.shim.public_models,
                },
            )
            return
        self._send_json(404, {"error": {"message": "Not found"}})

    def do_POST(self) -> None:  # noqa: N802
        path = self.path.split("?", 1)[0].rstrip("/") or "/"
        if path not in {"/v1/chat/completions", "/chat/completions"}:
            self._send_json(404, {"error": {"message": "Not found"}})
            return
        try:
            body = self._read_body()
            if not isinstance(body, dict):
                raise UpstreamError("Body must be a JSON object", status=400)
            messages = body.get("messages")
            system = body.get("system")
            if system is None:
                system = body.get("instructions") or ""
            if not isinstance(system, str):
                system = _content_to_text(system)
            answer, usage, _backend = self.shim.complete(
                model=body.get("model"), messages=messages, request_system=system
            )
        except UpstreamError as error:
            LOG.warning("Request failed: %s", error)
            self._send_json(
                error.status,
                {"error": {"message": str(error), "type": "upstream_error"}},
            )
            return
        except Exception as error:
            LOG.error("Unhandled request failure: %s", traceback.format_exc())
            self._send_json(
                500,
                {
                    "error": {
                        "message": f"Shim failure: {error}",
                        "type": "internal_error",
                    }
                },
            )
            return

        prompt_tokens = usage.get("prompt_tokens") or max(
            1, len(messages or []) * 8
        )
        completion_tokens = usage.get("completion_tokens") or max(
            1, len(answer) // 4
        )
        usage = {
            "prompt_tokens": prompt_tokens,
            "completion_tokens": completion_tokens,
            "total_tokens": usage.get("total_tokens")
            or prompt_tokens + completion_tokens,
        }
        if body.get("stream"):
            self._stream(answer, usage)
        else:
            self._send_json(200, self._completion(answer, usage))

    def _completion(self, answer: str, usage: dict[str, int]) -> dict[str, Any]:
        return {
            "id": f"chatcmpl-{uuid.uuid4().hex}",
            "object": "chat.completion",
            "created": int(time.time()),
            "model": self.shim.default_public,
            "choices": [
                {
                    "index": 0,
                    "message": {"role": "assistant", "content": answer},
                    "finish_reason": "stop",
                }
            ],
            "usage": usage,
        }

    def _stream(self, answer: str, usage: dict[str, int]) -> None:
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream; charset=utf-8")
        self.send_header("Cache-Control", "no-cache")
        self.send_header("Connection", "keep-alive")
        self.send_header("X-Accel-Buffering", "no")
        self.end_headers()

        completion_id = f"chatcmpl-{uuid.uuid4().hex}"
        created = int(time.time())

        def chunk(
            delta: dict[str, Any],
            *,
            finish_reason: str | None = None,
            include_usage: dict[str, int] | None = None,
        ) -> None:
            payload: dict[str, Any] = {
                "id": completion_id,
                "object": "chat.completion.chunk",
                "created": created,
                "model": self.shim.default_public,
                "choices": [
                    {"index": 0, "delta": delta, "finish_reason": finish_reason}
                ],
            }
            if include_usage is not None:
                payload["usage"] = include_usage
            data = json.dumps(payload).encode("utf-8")
            self.wfile.write(b"data: " + data + b"\n\n")
            self.wfile.flush()

        try:
            chunk({"role": "assistant", "content": ""})
            for index in range(0, len(answer), 800):
                chunk({"content": answer[index : index + 800]})
            chunk({}, finish_reason="stop", include_usage=usage)
            self.wfile.write(b"data: [DONE]\n\n")
            self.wfile.flush()
        except (BrokenPipeError, ConnectionResetError):
            LOG.debug("Client disconnected during stream")
        finally:
            self.close_connection = True


class ShimServer(ThreadingHTTPServer):
    daemon_threads = True
    allow_reuse_address = True

    def __init__(self, address: tuple[str, int], shim: Shim) -> None:
        super().__init__(address, Handler)
        self.shim = shim


def _shim_is_up(host: str, port: int) -> bool:
    try:
        with urllib.request.urlopen(
            f"http://{host}:{port}/health", timeout=1.5
        ) as response:
            payload = json.loads(response.read().decode("utf-8"))
    except Exception:
        return False
    return bool(isinstance(payload, dict) and payload.get("ok"))


def _free_port(preferred: int) -> int:
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as sock:
        try:
            sock.bind((OPENCODE_SERVE_HOST, preferred))
            return preferred
        except OSError:
            pass
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as sock:
        sock.bind((OPENCODE_SERVE_HOST, 0))
        return int(sock.getsockname()[1])


def _configure_logging(log_path: Path, verbose: bool) -> None:
    log_path.parent.mkdir(parents=True, exist_ok=True)
    LOG.setLevel(logging.DEBUG if verbose else logging.INFO)
    handler = RotatingFileHandler(
        log_path, maxBytes=2_000_000, backupCount=3, encoding="utf-8"
    )
    handler.setFormatter(
        logging.Formatter("%(asctime)s %(levelname)s %(name)s: %(message)s")
    )
    LOG.addHandler(handler)
    stream = logging.StreamHandler(sys.stderr)
    stream.setFormatter(logging.Formatter("%(levelname)s: %(message)s"))
    LOG.addHandler(stream)


def _parse_chains(spec: str | None) -> dict[str, list[tuple[str, str]]]:
    chains = build_default_chains()
    if not spec:
        return chains
    parsed: dict[str, list[tuple[str, str]]] = {}
    for entry in spec.split(";"):
        entry = entry.strip()
        if not entry:
            continue
        public, separator, models = entry.partition("=")
        if not separator or not public.strip() or not models.strip():
            raise SystemExit(f"Invalid model mapping: {entry!r}")
        parsed[public.strip()] = [
            _split_ref(item) for item in models.split(",") if item.strip()
        ]
    return parsed or chains


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--shim-port", type=int, default=SHIM_DEFAULT_PORT)
    parser.add_argument("--opencode-port", type=int, default=OPENCODE_SERVE_PORT)
    parser.add_argument("--shim-host", default=OPENCODE_SERVE_HOST)
    parser.add_argument("--opencode-bin", default=None)
    parser.add_argument(
        "--models",
        default=None,
        help="Optional ';' separated public=provider/model,... chains",
    )
    parser.add_argument(
        "--attempt-timeout",
        type=float,
        default=75.0,
        help="Seconds to wait for one model before falling back to the next",
    )
    parser.add_argument("--log-file", default=None)
    parser.add_argument("--verbose", action="store_true")
    args = parser.parse_args(argv)

    log_path = Path(
        args.log_file
        or Path(os.environ.get("LOCALAPPDATA") or Path.home())
        / "CCC"
        / "shim.log"
    )
    _configure_logging(log_path, args.verbose)

    chains = _parse_chains(args.models)
    default_public = next(iter(chains))
    if _shim_is_up(args.shim_host, args.shim_port):
        LOG.info(
            "Free model shim already listening on http://%s:%s/v1; nothing to do",
            args.shim_host,
            args.shim_port,
        )
        return 0
    shim_port = _free_port(args.shim_port)
    binary = _find_opencode(args.opencode_bin)
    # Always use the shared OpenCode port: reuse a healthy server there and let
    # ensure_started() start one only when the port is actually free.
    opencode = OpenCodeServer(
        binary=binary,
        port=args.opencode_port,
        log_path=log_path.with_name("opencode-serve.log"),
    )
    shim = Shim(
        opencode=opencode,
        chains=chains,
        default_public=default_public,
        attempt_timeout=args.attempt_timeout,
    )

    try:
        opencode.ensure_started()
    except Exception as error:
        LOG.error("Could not start opencode serve: %s", error)
        return 1

    server = ShimServer((args.shim_host, shim_port), shim)
    LOG.info(
        "Free model shim listening on http://%s:%s/v1 (models: %s)",
        args.shim_host,
        shim_port,
        ", ".join(chains),
    )
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        LOG.info("Shim interrupted")
    finally:
        server.server_close()
        opencode.stop()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
