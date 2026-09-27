#!/usr/bin/env python3
"""Listen for the OHealth iPhone app on the local network.

The window turns this on from Settings. While it is on, the computer
advertises `_ohealth._tcp` and accepts one paired phone. The pairing
code is shown in Settings. The phone sends that code once, over TLS,
and keeps the token that comes back. Health numbers are stored for the
person the window has open.
"""

from __future__ import annotations

import argparse
import hashlib
import hmac
import json
import os
import secrets
import shutil
import signal
import socket
import ssl
import subprocess
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from ohealth_paths import (  # noqa: E402
    cache_dir,
    companion_dir,
    companion_status_path,
    ensure_layout,
)
from ohealth_sync import (  # noqa: E402
    connect_db,
    current_person,
    ingest_companion_samples,
    save_meta,
    write_json,
)

SERVICE_TYPE = "_ohealth._tcp"
PORT = 47623
MAX_FRAME = 8_000_000
_META_KEYS = ("companionEnabled", "companionCode", "companionToken", "companionDevice")


def _stored() -> dict[str, str]:
    conn = connect_db()
    try:
        return {
            row["key"]: row["value"]
            for row in conn.execute(
                f"SELECT key, value FROM meta WHERE key IN ({','.join('?' for _ in _META_KEYS)})",
                _META_KEYS,
            )
        }
    finally:
        conn.close()


def _save(values: dict[str, str]) -> None:
    conn = connect_db()
    try:
        save_meta(conn, values)
        conn.commit()
    finally:
        conn.close()


def _match(got: object, expected: str) -> bool:
    if not expected or not isinstance(got, str):
        return False
    text = got.strip()
    if len(text) != len(expected):
        return False
    return hmac.compare_digest(text, expected)


def _device_name(value: object) -> str:
    text = " ".join(str(value or "").split())
    cleaned = "".join(ch for ch in text if ch.isalnum() or ch in " '-._")
    return (cleaned or "iPhone")[:64]


def _new_code() -> str:
    return f"{secrets.randbelow(1_000_000):06d}"


def certificate_fingerprint(cert: Path) -> str:
    der = subprocess.check_output(["openssl", "x509", "-in", str(cert), "-outform", "der"])
    return ":".join(f"{byte:02X}" for byte in hashlib.sha256(der).digest())


def ensure_certificate() -> tuple[Path, Path, str]:
    if shutil.which("openssl") is None:
        raise RuntimeError("openssl is required before an iPhone can pair.")
    folder = companion_dir()
    folder.mkdir(parents=True, exist_ok=True)
    os.chmod(folder, 0o700)
    cert = folder / "cert.pem"
    key = folder / "key.pem"
    if not cert.is_file() or not key.is_file():
        subprocess.run(
            [
                "openssl", "req", "-x509", "-newkey", "rsa:2048",
                "-keyout", str(key), "-out", str(cert),
                "-days", "3650", "-nodes", "-subj", "/CN=OHealth",
            ],
            check=True,
            capture_output=True,
            text=True,
        )
        os.chmod(cert, 0o600)
        os.chmod(key, 0o600)
    return cert, key, certificate_fingerprint(cert)


def public_companion(*, listening: bool | None = None, port: int | None = None, error: str | None = None) -> dict:
    stored = _stored()
    token = stored.get("companionToken") or ""
    enabled = stored.get("companionEnabled") == "1"
    paired = bool(token)
    code = stored.get("companionCode") or ""
    fingerprint = ""
    cert = companion_dir() / "cert.pem"
    if cert.is_file() and shutil.which("openssl"):
        try:
            fingerprint = certificate_fingerprint(cert)
        except (OSError, subprocess.CalledProcessError):
            fingerprint = ""
    current: dict = {}
    path = companion_status_path()
    if path.is_file():
        try:
            current = json.loads(path.read_text())
        except json.JSONDecodeError:
            current = {}
    if listening is None:
        listening = bool(current.get("listening")) and enabled
    if port is None:
        port = int(current.get("port") or 0) if listening else 0
    if error is None:
        error = "" if enabled else str(current.get("error") or "")
    return {
        "enabled": enabled,
        "paired": paired,
        "device": stored.get("companionDevice") or "" if paired else "",
        "code": code if enabled and not paired else "",
        "fingerprint": fingerprint,
        "service": SERVICE_TYPE,
        "name": service_name(),
        "port": port,
        "listening": bool(listening) and enabled,
        "error": error,
    }


def write_public(**runtime) -> dict:
    payload = public_companion(**runtime)
    path = companion_status_path()
    text = json.dumps(payload, indent=2) + "\n"
    if path.is_file() and path.read_text() == text:
        return payload
    write_json(path, payload)
    return payload


def apply_companion_config(patch: dict) -> dict:
    ensure_layout()
    stored = _stored()
    enabled = stored.get("companionEnabled") == "1"
    if "enabled" in patch:
        enabled = bool(patch["enabled"])
    code = stored.get("companionCode") or ""
    token = stored.get("companionToken") or ""
    device = stored.get("companionDevice") or ""
    rotate = bool(patch.get("pair"))
    if rotate:
        enabled = True
    if rotate or (enabled and not token and not code):
        code = _new_code()
        token = ""
        device = ""
    if enabled:
        ensure_certificate()
    _save({
        "companionEnabled": "1" if enabled else "0",
        "companionCode": code,
        "companionToken": token,
        "companionDevice": device,
    })
    if not enabled:
        return write_public(listening=False, port=0, error="")
    return write_public(error="")


def handle_message(message: dict) -> dict:
    if not isinstance(message, dict):
        return {"type": "error", "error": "Expected a JSON object."}
    stored = _stored()
    if stored.get("companionEnabled") != "1":
        return {"type": "error", "error": "iPhone sync is turned off on this computer."}
    kind = str(message.get("type") or "")
    if kind == "pair":
        if not _match(message.get("code"), stored.get("companionCode") or ""):
            return {"type": "error", "error": "That pairing code is not valid."}
        token = secrets.token_hex(32)
        device = _device_name(message.get("device"))
        _save({
            "companionEnabled": "1",
            "companionCode": "",
            "companionToken": token,
            "companionDevice": device,
        })
        _uid, name = current_person()
        write_public(error="")
        return {"type": "paired", "token": token, "person": name, "device": device}
    if kind == "sync":
        if not _match(message.get("token"), stored.get("companionToken") or ""):
            return {"type": "error", "error": "This iPhone is not paired."}
        try:
            result = ingest_companion_samples(list(message.get("samples") or []))
        except ValueError as exc:
            return {"type": "error", "error": str(exc)}
        return {"type": "synced", "saved": result["saved"], "days": result["days"]}
    return {"type": "error", "error": "Unknown message."}


def service_name() -> str:
    host = socket.gethostname().split(".")[0][:24] or "computer"
    return f"OHealth ({host})"


def _read_exact(stream, size: int) -> bytes:
    chunks = []
    remaining = size
    while remaining:
        chunk = stream.read(remaining)
        if not chunk:
            raise ConnectionError("The iPhone closed the connection.")
        chunks.append(chunk)
        remaining -= len(chunk)
    return b"".join(chunks)


def read_frame(stream) -> dict:
    size = int.from_bytes(_read_exact(stream, 4), "big")
    if size <= 0 or size > MAX_FRAME:
        raise ValueError("That sync message is the wrong size.")
    payload = json.loads(_read_exact(stream, size))
    if not isinstance(payload, dict):
        raise ValueError("Expected a JSON object.")
    return payload


def write_frame(stream, payload: dict) -> None:
    body = json.dumps(payload, separators=(",", ":")).encode()
    stream.sendall(len(body).to_bytes(4, "big") + body)


def _log(message: str) -> None:
    path = cache_dir() / "companion.log"
    try:
        path.parent.mkdir(parents=True, exist_ok=True)
        with path.open("a", encoding="utf-8") as handle:
            handle.write(f"{time.strftime('%Y-%m-%dT%H:%M:%S')} {message}\n")
    except OSError:
        pass


def _pid_path() -> Path:
    return cache_dir() / "companion.pid"


def _live_pid() -> int | None:
    path = _pid_path()
    if not path.is_file():
        return None
    try:
        pid = int(path.read_text().strip())
    except ValueError:
        return None
    try:
        os.kill(pid, 0)
    except OSError:
        return None
    return pid


def stop_serve() -> None:
    pid = _live_pid()
    _pid_path().unlink(missing_ok=True)
    if pid is None or pid == os.getpid():
        return
    try:
        os.kill(pid, signal.SIGTERM)
    except OSError:
        return
    for _ in range(30):
        try:
            os.kill(pid, 0)
        except OSError:
            return
        time.sleep(0.1)
    try:
        os.kill(pid, signal.SIGKILL)
    except OSError:
        pass


def ensure_serve() -> None:
    """Keep the listener up while Settings has iPhone sync on, even if the window closes."""
    if os.environ.get("OHEALTH_COMPANION_NO_SERVE") == "1":
        if _stored().get("companionEnabled") != "1":
            stop_serve()
        return
    if _stored().get("companionEnabled") != "1":
        stop_serve()
        write_public(listening=False, port=0, error="")
        return
    if _live_pid() is not None:
        return
    log = cache_dir() / "companion.log"
    log.parent.mkdir(parents=True, exist_ok=True)
    handle = log.open("a", encoding="utf-8")
    subprocess.Popen(
        [sys.executable, str(Path(__file__).resolve()), "serve"],
        start_new_session=True,
        stdin=subprocess.DEVNULL,
        stdout=handle,
        stderr=handle,
    )


def _lan_ipv4() -> str | None:
    """Address the iPhone can open. The machine's public IPv6 is not that path."""
    probe = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    try:
        probe.connect(("192.0.2.1", 9))
        address = probe.getsockname()[0]
    except OSError:
        return None
    finally:
        probe.close()
    if not address or address.startswith("127."):
        return None
    return address


def _pair_host() -> str:
    host = socket.gethostname().split(".")[0].lower()
    safe = "".join(ch if ch.isalnum() or ch == "-" else "-" for ch in host).strip("-")[:24] or "computer"
    return f"ohealth-{safe}.local"


def _advertise(port: int, fingerprint: str) -> list[subprocess.Popen]:
    service_bin = shutil.which("avahi-publish-service")
    if service_bin is None:
        return []
    ip = _lan_ipv4()
    host = _pair_host()
    procs: list[subprocess.Popen] = []
    address_bin = shutil.which("avahi-publish-address")
    if address_bin and ip:
        procs.append(subprocess.Popen(
            [address_bin, "-R", host, ip],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.PIPE,
            text=True,
        ))
        time.sleep(0.3)
    command = [service_bin, "-s"]
    if ip:
        command.extend(["-H", host])
    command.extend([
        service_name(), SERVICE_TYPE, str(port),
        "v=1", f"fp={fingerprint.replace(':', '')}",
    ])
    procs.append(subprocess.Popen(
        command,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.PIPE,
        text=True,
    ))
    return procs


def _open_server() -> socket.socket:
    """Accept the address the iPhone picks. Bonjour often offers IPv6 first."""
    try:
        server = socket.socket(socket.AF_INET6, socket.SOCK_STREAM)
        server.setsockopt(socket.IPPROTO_IPV6, socket.IPV6_V6ONLY, 0)
        server.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        server.bind(("::", PORT))
        return server
    except OSError:
        server = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        server.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        try:
            server.bind(("0.0.0.0", PORT))
        except OSError:
            server.bind(("0.0.0.0", 0))
        return server


def _connection(ctx: ssl.SSLContext, client: socket.socket) -> None:
    client.settimeout(60)
    tls = ctx.wrap_socket(client, server_side=True)
    try:
        peer = "?"
        try:
            peer = str(tls.getpeername()[0])
        except OSError:
            pass
        _log(f"tls from {peer}")
        while True:
            try:
                message = read_frame(tls)
            except (TimeoutError, ConnectionError, json.JSONDecodeError, ValueError):
                break
            reply = handle_message(message)
            _log(f"reply {reply.get('type')} to {peer}")
            write_frame(tls, reply)
            if reply.get("type") == "error":
                break
    finally:
        tls.close()


def serve() -> int:
    ensure_layout()
    stored = _stored()
    if stored.get("companionEnabled") != "1":
        write_public(listening=False, port=0, error="")
        return 0
    try:
        cert, key, fingerprint = ensure_certificate()
    except (RuntimeError, subprocess.CalledProcessError, OSError) as exc:
        write_public(listening=False, port=0, error=str(exc) or "Could not prepare the pairing certificate.")
        return 1
    _pid_path().write_text(str(os.getpid()))
    os.chmod(_pid_path(), 0o600)
    server = _open_server()
    server.listen(4)
    server.settimeout(1.0)
    port = int(server.getsockname()[1])
    _log(f"listening on {server.family.name} port {port}")
    context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    context.minimum_version = ssl.TLSVersion.TLSv1_2
    context.load_cert_chain(cert, key)
    publishers = _advertise(port, fingerprint)
    error = ""
    if not publishers:
        error = "avahi-publish-service is not installed, so an iPhone cannot discover this computer."
    else:
        time.sleep(0.4)
        failed = [proc for proc in publishers if proc.poll() is not None]
        if failed:
            err = ""
            if failed[-1].stderr:
                err = failed[-1].stderr.read() or ""
            error = (err.strip().splitlines() or ["The network service could not be advertised."])[-1]
            for proc in publishers:
                if proc.poll() is None:
                    proc.terminate()
            publishers = []
    write_public(listening=True, port=port, error=error)

    def _stop(_signum, _frame) -> None:
        raise SystemExit(0)

    signal.signal(signal.SIGTERM, _stop)
    try:
        while _stored().get("companionEnabled") == "1":
            try:
                client, addr = server.accept()
            except socket.timeout:
                continue
            except OSError:
                break
            _log(f"connection from {addr[0]}")
            try:
                _connection(context, client)
            except Exception as exc:  # noqa: BLE001 — one phone must not stop the listener
                _log(f"connection closed: {exc.__class__.__name__}: {exc}")
            finally:
                client.close()
    finally:
        for proc in publishers:
            if proc.poll() is None:
                proc.terminate()
        server.close()
        if _pid_path().is_file() and _pid_path().read_text().strip() == str(os.getpid()):
            _pid_path().unlink(missing_ok=True)
        write_public(listening=False, port=0, error="")
    return 0


def main() -> None:
    parser = argparse.ArgumentParser(description="Pair and receive Health samples from the OHealth iPhone app")
    parser.add_argument("command", choices=("status", "config", "serve", "ensure"))
    args = parser.parse_args()
    try:
        ensure_layout()
        if args.command == "serve":
            sys.exit(serve())
        if args.command == "config":
            raw = sys.stdin.readline()
            patch = json.loads(raw) if raw.strip() else {}
            if not isinstance(patch, dict):
                raise ValueError("Expected a JSON object.")
            payload = apply_companion_config(patch)
            ensure_serve()
            payload = write_public()
        elif args.command == "ensure":
            ensure_serve()
            payload = write_public()
        else:
            payload = write_public()
    except Exception as exc:  # noqa: BLE001 — one error string for the window
        print(str(exc) or exc.__class__.__name__, file=sys.stderr)
        sys.exit(1)
    print(json.dumps(payload), flush=True)


if __name__ == "__main__":
    main()
