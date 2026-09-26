#!/usr/bin/env python3
"""Apple sign-in for OHealth.

Same contract as Omarchy iCloud Photos' icloud_helper.py: JSON objects on
stdout, password on stdin, never written to disk. The session is stored in
the cookie directory (default ~/.config/icloudpd), which is the jar
icloudpd and Omarchy iCloud Photos already use.

This does not download HealthKit data. After a session exists, the sync
script still needs an Apple Health export on disk. Health records are not
part of the iCloud web API that pyicloud speaks.

    ohealth_helper.py login  --username APPLE_ID [--save-config]
    ohealth_helper.py status
    ohealth_helper.py probe
    ohealth_helper.py logout
"""

from __future__ import annotations

import argparse
import inspect
import json
import logging
import os
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from ohealth_paths import (  # noqa: E402
    cache_dir,
    clear_apple_id,
    ensure_layout,
    read_config,
    write_apple_id,
)


def emit(obj: dict) -> None:
    print(json.dumps(obj), flush=True)


def fail(message: str, **extra) -> None:
    logging.getLogger().error("fail: %s", message)
    emit({"ok": False, "error": message, **extra})
    sys.exit(1)


TERMS_ERROR = (
    "Apple needs the updated iCloud terms accepted before sign-in can finish. "
    "Open icloud.com, accept them, and try again."
)


def needs_terms(exc: BaseException) -> bool:
    """True when Apple blocked the session on an updated terms prompt."""
    if type(exc).__name__ == "PyiCloudAcceptTermsException":
        return True
    return "accept the updated terms" in str(exc).lower()


def fail_apple(exc: BaseException, fallback: str) -> None:
    if needs_terms(exc):
        fail(TERMS_ERROR)
    fail(fallback)


def import_service():
    """Prefer the pyicloud build icloudpd vendors, then the public package."""
    try:
        from pyicloud_ipd.base import PyiCloudService
        from pyicloud_ipd.exceptions import (
            PyiCloudConnectionErrorException,
            PyiCloudException,
            PyiCloudFailedLoginException,
            PyiCloudServiceUnavailableException,
        )
        return "pyicloud_ipd", PyiCloudService, {
            "connection": PyiCloudConnectionErrorException,
            "base": PyiCloudException,
            "login": PyiCloudFailedLoginException,
            "unavailable": PyiCloudServiceUnavailableException,
        }
    except ImportError:
        pass
    try:
        from pyicloud import PyiCloudService
        from pyicloud.exceptions import (
            PyiCloudException,
            PyiCloudFailedLoginException,
        )
        unavailable = getattr(
            sys.modules["pyicloud.exceptions"],
            "PyiCloudServiceUnavailableException",
            PyiCloudException,
        )
        connection = getattr(
            sys.modules["pyicloud.exceptions"],
            "PyiCloudConnectionErrorException",
            PyiCloudException,
        )
        return "pyicloud", PyiCloudService, {
            "connection": connection,
            "base": PyiCloudException,
            "login": PyiCloudFailedLoginException,
            "unavailable": unavailable,
        }
    except ImportError:
        return None, None, None


def construct(service_cls, args: tuple, options: dict):
    """Build a pyicloud service, skipping keywords this build does not take.

    Current pyicloud raises until accept_terms=True, which is the library's
    --accept-terms switch. Older builds, and pyicloud_ipd, reject that name.
    """
    try:
        params = inspect.signature(service_cls).parameters
    except (TypeError, ValueError):
        params = None
    if params is None:
        try:
            return service_cls(*args, **options)
        except TypeError:
            slim = {key: value for key, value in options.items() if key != "accept_terms"}
            try:
                return service_cls(*args, **slim)
            except TypeError:
                return service_cls(*args)
    if not any(param.kind is inspect.Parameter.VAR_KEYWORD for param in params.values()):
        options = {key: value for key, value in options.items() if key in params}
    return service_cls(*args, **options)


def connect(backend: str, service_cls, username: str, password_fn, cookies: str):
    Path(cookies).mkdir(parents=True, exist_ok=True)
    os.chmod(cookies, 0o700)
    options = {"cookie_directory": cookies, "accept_terms": True}
    if backend == "pyicloud_ipd":
        # Country "com", password fetched by the library only if the session
        # is missing. Calling authenticate() again would be a second sign-in.
        return construct(service_cls, ("com", username, password_fn), options)
    password = password_fn() if password_fn else None
    return construct(service_cls, (username, password), options)


def cmd_login(args) -> None:
    password = sys.stdin.readline().rstrip("\n")
    logging.getLogger().info(
        "password: %d characters, non-ascii=%s, ends with space=%s",
        len(password),
        any(ord(ch) > 127 for ch in password),
        password.endswith(" "),
    )
    backend, service_cls, errors = import_service()
    if service_cls is None:
        fail(
            "Apple sign-in needs pyicloud. On Omarchy, run install.sh in this "
            "repository. It creates .venv and installs the same pyicloud module "
            "icloudpd ships. The password was not stored."
        )
    cfg = read_config()
    cookies = cfg["COOKIES"]
    try:
        api = connect(backend, service_cls, args.username, lambda: password or None, cookies)
    except errors["login"]:
        fail("Wrong Apple ID or password")
    except errors["unavailable"]:
        fail(
            "Apple is not taking sign-ins for this account right now, which happens after "
            "several sign-ins in a short time. Leave it for half an hour, then try once; "
            "every attempt before that extends the wait."
        )
    except errors["connection"]:
        fail("Could not reach iCloud. Check the connection and try again.")
    except errors["base"] as exc:
        fail_apple(exc, f"Apple did not accept the login: {exc}")
    except Exception as exc:  # noqa: BLE001
        fail_apple(exc, f"Apple did not accept the login: {exc}")

    if getattr(api, "requires_2fa", False):
        try:
            if hasattr(api, "trigger_push_notification"):
                api.trigger_push_notification()
        except Exception as exc:  # noqa: BLE001
            print(f"push notification not sent: {exc}", file=sys.stderr)
        emit({"step": "2fa"})
        code = sys.stdin.readline().strip()
        if not (len(code) == 6 and code.isdigit()):
            fail("The code should be six digits")
        try:
            accepted = api.validate_2fa_code(code)
        except Exception as exc:  # noqa: BLE001
            # trust_session() runs inside validate_2fa_code and is where
            # current pyicloud raises if Apple's terms still need accepting.
            fail_apple(exc, f"Apple did not accept that code: {exc}")
        if not accepted:
            fail("Apple did not accept that code")
        if hasattr(api, "trust_session"):
            try:
                api.trust_session()
            except Exception as exc:  # noqa: BLE001
                logging.getLogger().warning("trust_session: %s", exc)
    if args.save_config:
        write_apple_id(args.username)
    emit({"ok": True, "username": args.username, "backend": backend})


def cookie_present(cookies: str) -> bool:
    path = Path(cookies)
    if not path.is_dir():
        return False
    return any(path.iterdir())


def cmd_status() -> None:
    """Local only. Does not call Apple."""
    ensure_layout()
    cfg = read_config()
    apple_id = cfg.get("APPLE_ID", "")
    cookies = cfg.get("COOKIES", "")
    backend, _service, _errors = import_service()
    emit({
        "ok": True,
        "appleId": apple_id,
        "signedIn": bool(apple_id),
        "cookies": cookies,
        "cookiesPresent": cookie_present(cookies) if cookies else False,
        "backend": backend or "missing",
    })


def cmd_probe() -> None:
    """One session check against Apple, using the saved cookie, no password."""
    ensure_layout()
    cfg = read_config()
    apple_id = cfg.get("APPLE_ID", "")
    if not apple_id:
        fail("Sign in first. No Apple ID is saved.")
    backend, service_cls, errors = import_service()
    if service_cls is None:
        fail(
            "Cannot probe the Apple session because pyicloud is not installed. "
            "The saved Apple ID is still in the config. Run install.sh to add the helper."
        )
    try:
        api = connect(backend, service_cls, apple_id, lambda: None, cfg["COOKIES"])
    except errors["login"]:
        fail("iCloud session expired. Sign in again.")
    except errors["unavailable"]:
        fail("Apple is not taking sign-ins for this account right now. Leave it for half an hour.")
    except errors["connection"]:
        fail("Could not reach iCloud. Check the connection and try again.")
    except Exception as exc:  # noqa: BLE001
        if needs_terms(exc):
            fail(TERMS_ERROR)
        text = str(exc).lower()
        if "2fa" in text or "two-factor" in text or "required" in text:
            fail("iCloud session expired. Sign in again.")
        fail(f"Could not check the Apple session: {exc}")
    if getattr(api, "requires_2fa", False):
        fail("iCloud session expired. Sign in again.")
    emit({"ok": True, "username": apple_id, "session": "ok", "backend": backend})


def cmd_logout() -> None:
    """Forget the Apple ID in OHealth. Leave the shared cookie jar alone."""
    clear_apple_id()
    emit({
        "ok": True,
        "cleared": "APPLE_ID",
        "cookiesKept": True,
        "note": "The iCloud cookie directory was left in place so Omarchy iCloud Photos can keep using it.",
    })


def main() -> None:
    ensure_layout()
    cache_dir().mkdir(parents=True, exist_ok=True)
    logging.basicConfig(
        filename=cache_dir() / "helper.log",
        level=logging.INFO,
        format="%(asctime)s %(levelname)s %(name)s: %(message)s",
    )
    os.chmod(cache_dir() / "helper.log", 0o600)
    logging.getLogger().info("helper %s", " ".join(sys.argv[1:]))
    parser = argparse.ArgumentParser(description="OHealth Apple sign-in")
    sub = parser.add_subparsers(dest="cmd", required=True)
    login = sub.add_parser("login")
    login.add_argument("--username", required=True)
    login.add_argument("--save-config", action="store_true")
    sub.add_parser("status")
    sub.add_parser("probe")
    sub.add_parser("logout")
    args = parser.parse_args()
    if args.cmd == "login":
        cmd_login(args)
    elif args.cmd == "status":
        cmd_status()
    elif args.cmd == "probe":
        cmd_probe()
    else:
        cmd_logout()


if __name__ == "__main__":
    main()
