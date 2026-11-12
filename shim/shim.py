#!/usr/bin/env python3
"""OpenAI-compatible shim backed by the local `opencode serve` session API.

This process exposes:
  GET  /v1/models
  POST /v1/chat/completions   (JSON or SSE)

It starts `opencode serve` on demand, creates a short-lived session for each
request, and asks the free OpenCode models for a plain-text answer. No account,
API key, or signup is required. The fake model name is `opus-5.5`, served by a
fallback chain of every free OpenCode model: if one fails or is rate limited,
the next one is tried automatically.
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

DEFAULT_OPENCODE_BIN = r"C:\nvm4w\nodejs\node_modules\opencode-ai\bin\opencode.exe"
DEFAULT_MODEL = ",".join(
    [
        "opencode/pulse-alpha-free",
        "opencode/glm-5.3-flash-free",
        "opencode/deepseek-v4.1-flash-free",
        "opencode/mimo-v2.6-flash-free",
        "opencode/flint-40b-free",
        "opencode/nemotron-3.5-lightning-free",
        "opencode/nemotron-3.5-super-vl-free",
        "opencode/crouton-alpha-free",
        "opencode/beam-free",
        "opencode/big-pickle",
    ]
)
DEFAULT_PUBLIC_MODEL = "opus-5.5"
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
        return f"http://127.0.0.1:{self.port}"

    def healthy(self, *, timeout: float = 1.0) -> bool:
        try:
            with urllib.request.urlopen(
                f"{self.base_url}/global/health", timeout=timeout
            ) as response:
                payload = json.loads(response.read().decode("utf-8"))
            return bool(payload.get("healthy"))
        except Exception:
            return False

    def ensure_started(self, *, wait_seconds: float = 45.0) -> None:
        with self._lock:
            if self.healthy():
                LOG.info("Reusing existing opencode server on port %s", self.port)
                return
            if not self.binary or not Path(self.binary).is_file():
                raise UpstreamError(
                    "OpenCode binary not found. Set OPENCODE_BIN to opencode.exe.",
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
            LOG.info(
                "Starting opencode serve on port %s: %s", self.port, self.binary
            )
            self.process = subprocess.Popen(
                [
                    self.binary,
                    "serve",
                    "--hostname",
                    "127.0.0.1",
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
                )
            else:
                process.terminate()
                process.wait(timeout=10)
        except Exception:
            LOG.warning("Could not stop opencode serve cleanly", exc_info=True)


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
        DEFAULT_OPENCODE_BIN,
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
            continue  # .cmd shims are not directly spawnable either
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
    max_chars = 96_000
    if len(transcript) > max_chars:
        transcript = (
            "[Earlier conversation truncated]\n\n"
            + transcript[-max_chars:]
        )
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
        raise UpstreamError(
            "OpenCode returned an empty assistant message", status=502
        )
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
        models: list[tuple[str, str]],
        public_model: str,
        attempt_timeout: float = 75.0,
    ) -> None:
        self.opencode = opencode
        self.models = models
        self.public_model = public_model
        self.attempt_timeout = attempt_timeout
        self._failed_tail: list[tuple[str, str]] = []
        self._order_lock = threading.Lock()
        self._tool_map: dict[str, bool] | None = None
        self._tool_lock = threading.Lock()

    def _demote(self, model: tuple[str, str]) -> None:
        with self._order_lock:
            if model in self.models:
                self.models.remove(model)
                self._failed_tail.append(model)

    def _promote(self, model: tuple[str, str]) -> None:
        with self._order_lock:
            if model in self._failed_tail:
                self._failed_tail.remove(model)
                self.models.insert(0, model)

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
        request = urllib.request.Request(url, data=data, method=method, headers=headers)
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

    def _ask(self, provider: str, model: str, system: str, transcript: str) -> tuple[str, dict[str, int]]:
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
            try:
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
            except UpstreamError:
                raise
            except Exception as error:
                raise UpstreamError(
                    f"model {provider}/{model} did not answer: {error}",
                    status=504,
                ) from None
            return _extract_answer(payload)
        finally:
            if session_id:
                try:
                    self._api(
                        "POST", f"/session/{session_id}/abort", timeout=10
                    )
                except Exception:
                    pass
                try:
                    self._api(
                        "DELETE", f"/session/{session_id}", timeout=15
                    )
                except Exception:
                    LOG.debug("Could not delete session %s", session_id)

    def complete(self, messages: Any, request_system: str) -> tuple[str, dict[str, int], str]:
        system, transcript = _flatten_messages(messages)
        if request_system.strip():
            system = f"{system}\n\n{request_system}" if system else request_system
        system = _build_system(system)
        self.opencode.ensure_started()
        with self._order_lock:
            candidates = list(self.models) + list(self._failed_tail)
        last_error: UpstreamError | None = None
        for provider, model in candidates:
            label = f"{provider}/{model}"
            try:
                answer, usage = self._ask(provider, model, system, transcript)
                self._promote((provider, model))
                LOG.info("Answered via %s", label)
                return answer, usage, label
            except UpstreamError as error:
                self._demote((provider, model))
                LOG.warning(
                    "Backend %s failed (%s); trying the next free model",
                    label,
                    error,
                )
                last_error = error
        raise last_error or UpstreamError("No free OpenCode model answered", status=502)


class Handler(BaseHTTPRequestHandler):
    server_version = "CCCShim/1.0"
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
                    "model": self.shim.public_model,
                    "backends": [
                        f"{provider}/{model}" for provider, model in self.shim.models
                    ],
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
                            "id": self.shim.public_model,
                            "object": "model",
                            "created": int(time.time()),
                            "owned_by": "opencode",
                        }
                    ],
                },
            )
            return
        if path == "/":
            self._send_json(
                200,
                {
                    "name": "Claude Opus 5.5 shim",
                    "model": self.shim.public_model,
                    "backends": [
                        f"{provider}/{model}" for provider, model in self.shim.models
                    ],
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
            answer, usage, _backend = self.shim.complete(messages, system)
        except UpstreamError as error:
            LOG.warning("Request failed: %s", error)
            self._send_json(
                error.status,
                {
                    "error": {
                        "message": str(error),
                        "type": "upstream_error",
                    }
                },
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

        prompt_tokens = usage.get("prompt_tokens") or max(1, len(messages or []) * 8)
        completion_tokens = usage.get("completion_tokens") or max(
            1, len(answer) // 4
        )
        total_tokens = usage.get("total_tokens") or (
            prompt_tokens + completion_tokens
        )
        usage = {
            "prompt_tokens": prompt_tokens,
            "completion_tokens": completion_tokens,
            "total_tokens": total_tokens,
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
            "model": self.shim.public_model,
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
                "model": self.shim.public_model,
                "choices": [
                    {
                        "index": 0,
                        "delta": delta,
                        "finish_reason": finish_reason,
                    }
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


def _free_port(preferred: int) -> int:
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as sock:
        try:
            sock.bind(("127.0.0.1", preferred))
            return preferred
        except OSError:
            pass
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as sock:
        sock.bind(("127.0.0.1", 0))
        return int(sock.getsockname()[1])


def _configure_logging(log_path: Path, verbose: bool) -> None:
    log_path.parent.mkdir(parents=True, exist_ok=True)
    level = logging.DEBUG if verbose else logging.INFO
    LOG.setLevel(level)
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


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--shim-port", type=int, default=4097)
    parser.add_argument("--opencode-port", type=int, default=4096)
    parser.add_argument("--shim-host", default="127.0.0.1")
    parser.add_argument("--opencode-bin", default=None)
    parser.add_argument(
        "--backend-model",
        default=DEFAULT_MODEL,
        help="Comma-separated provider/model fallback chain",
    )
    parser.add_argument("--public-model", default=DEFAULT_PUBLIC_MODEL)
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

    models: list[tuple[str, str]] = []
    for entry in args.backend_model.split(","):
        provider, separator, model = entry.strip().partition("/")
        if not separator or not provider or not model:
            parser.error(
                "--backend-model must be comma-separated provider/model pairs"
            )
        models.append((provider, model))
    if not models:
        parser.error("--backend-model must list at least one provider/model")

    opencode_port = _free_port(args.opencode_port)
    shim_port = _free_port(args.shim_port)
    binary = _find_opencode(args.opencode_bin)
    opencode = OpenCodeServer(
        binary=binary,
        port=opencode_port,
        log_path=log_path.with_name("opencode-serve.log"),
    )
    shim = Shim(
        opencode=opencode,
        models=models,
        public_model=args.public_model,
        attempt_timeout=args.attempt_timeout,
    )

    try:
        opencode.ensure_started()
    except Exception as error:
        LOG.error("Could not start opencode serve: %s", error)
        return 1

    server = ShimServer((args.shim_host, shim_port), shim)
    LOG.info(
        "Claude Opus 5.5 shim listening on http://%s:%s/v1 (backends: %s)",
        args.shim_host,
        shim_port,
        args.backend_model,
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
