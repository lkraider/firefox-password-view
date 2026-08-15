#!/usr/bin/env python3
"""Drives the installed Firefox over Marionette to write fixture profiles.

Fixtures must be produced by real Firefox writing real NSS output. A
generator that encodes this project's own reading of key4.db and
logins.json would only prove the reader agrees with the writer. See
core/testdata/README.md and the plan under milestone 0 for why.

Usage:
    tools/mkfixtures.py fresh       --profile core/testdata/fresh/profile
    tools/mkfixtures.py primary     --profile core/testdata/primary/profile
    tools/mkfixtures.py sync-shaped --profile core/testdata/sync-shaped/profile
    tools/mkfixtures.py migrate     --profile core/testdata/migrated/profile

Each subcommand launches Firefox, drives it, and quits it. Firefox must
be fully closed before the caller reads key4.db or logins.json, so this
script always waits for the child process to exit.
"""

import argparse
import json
import os
import socket
import subprocess
import sys
import time

MARIONETTE_PORT = 2828
DEFAULT_FIREFOX = "/Applications/Firefox.app/Contents/MacOS/firefox"


class MarionetteError(RuntimeError):
    pass


class Marionette:
    """A minimal client for the Marionette wire protocol (v3).

    Every message, in both directions, is framed as ``<byte length>:<json>``.
    A command is the array ``[0, message_id, name, params]``. A response is
    ``[1, message_id, error_or_null, result]``.
    """

    def __init__(self, host="127.0.0.1", port=MARIONETTE_PORT, timeout=30):
        self._sock = socket.create_connection((host, port), timeout=timeout)
        self._buf = b""
        self._next_id = 1
        self._read_handshake()

    def _read_exact(self, n):
        while len(self._buf) < n:
            chunk = self._sock.recv(65536)
            if not chunk:
                raise MarionetteError("connection closed while reading")
            self._buf += chunk
        out, self._buf = self._buf[:n], self._buf[n:]
        return out

    def _read_message(self):
        length = b""
        while True:
            if b":" in self._buf:
                idx = self._buf.index(b":")
                length, self._buf = self._buf[:idx], self._buf[idx + 1 :]
                break
            chunk = self._sock.recv(65536)
            if not chunk:
                raise MarionetteError("connection closed while reading a length prefix")
            self._buf += chunk
        payload = self._read_exact(int(length))
        return json.loads(payload.decode("utf-8"))

    def _read_handshake(self):
        self.handshake = self._read_message()

    def _send(self, name, params):
        msg_id = self._next_id
        self._next_id += 1
        packet = json.dumps([0, msg_id, name, params]).encode("utf-8")
        self._sock.sendall(str(len(packet)).encode("ascii") + b":" + packet)
        return msg_id

    def command(self, name, params=None):
        msg_id = self._send(name, params or {})
        while True:
            reply = self._read_message()
            if reply[0] != 1:
                continue
            _, reply_id, error, result = reply
            if reply_id != msg_id:
                continue
            if error is not None:
                raise MarionetteError(f"{name}: {error}")
            return result

    def new_session(self):
        return self.command("WebDriver:NewSession", {"capabilities": {}})

    def set_context(self, value):
        return self.command("Marionette:SetContext", {"value": value})

    def execute_script(self, script, args=None):
        return self.command(
            "WebDriver:ExecuteScript",
            {
                "script": script,
                "args": args or [],
                "sandbox": None,
                "newSandbox": False,
                "filename": "mkfixtures.py",
                "line": 1,
            },
        )

    def execute_async_script(self, script, args=None):
        return self.command(
            "WebDriver:ExecuteAsyncScript",
            {
                "script": script,
                "args": args or [],
                "sandbox": None,
                "newSandbox": False,
                "filename": "mkfixtures.py",
                "line": 1,
            },
        )

    def quit(self):
        self._sock.close()


def wait_for_marionette(port, deadline):
    while time.time() < deadline:
        try:
            return Marionette(port=port)
        except (ConnectionRefusedError, OSError):
            time.sleep(0.2)
    raise MarionetteError(f"Marionette never answered on port {port}")


class FirefoxDriver:
    """Launches one headless Firefox against one profile and drives it."""

    def __init__(self, firefox, profile_dir, port=MARIONETTE_PORT):
        self.firefox = firefox
        self.profile_dir = profile_dir
        self.port = port
        self.proc = None
        self.client = None

    def __enter__(self):
        os.makedirs(self.profile_dir, exist_ok=True)
        prefs_path = os.path.join(self.profile_dir, "user.js")
        with open(prefs_path, "a", encoding="utf-8") as f:
            f.write('user_pref("app.update.auto", false);\n')
            f.write(f'user_pref("marionette.port", {self.port});\n')

        self.proc = subprocess.Popen(
            [
                self.firefox,
                "--headless",
                "--marionette",
                "--remote-allow-system-access",
                "--profile",
                self.profile_dir,
                "--no-remote",
            ],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )
        self.client = wait_for_marionette(self.port, time.time() + 30)
        self.client.new_session()
        self.client.set_context("chrome")
        return self

    def __exit__(self, exc_type, exc, tb):
        if self.client is not None:
            try:
                self.client.execute_script("Services.startup.quit(Ci.nsIAppStartup.eForceQuit);")
            except (MarionetteError, OSError, BrokenPipeError):
                pass
            self.client.quit()
        if self.proc is not None:
            try:
                self.proc.wait(timeout=20)
            except subprocess.TimeoutExpired:
                self.proc.kill()
                self.proc.wait(timeout=10)
        for name in ("key4.db-wal", "key4.db-shm", "logins.json.bak"):
            p = os.path.join(self.profile_dir, name)
            if os.path.exists(p):
                os.remove(p)


ADD_LOGIN_SCRIPT = """
const [hostname, formActionOrigin, httpRealm, username, password,
       usernameField, passwordField, resolve] = arguments;
(async () => {
  const login = Cc["@mozilla.org/login-manager/loginInfo;1"]
    .createInstance(Ci.nsILoginInfo);
  login.init(
    hostname,
    formActionOrigin === "" ? null : formActionOrigin,
    httpRealm === "" ? null : httpRealm,
    username, password, usernameField, passwordField);
  await Services.logins.addLoginAsync(login);
  resolve("ok");
})().catch(e => resolve("error: " + e));
"""


def add_login(fx, hostname, username, password, form_action_origin="", http_realm="",
              username_field="", password_field=""):
    result = fx.client.execute_async_script(
        ADD_LOGIN_SCRIPT,
        [hostname, form_action_origin, http_realm, username, password,
         username_field, password_field],
    )
    result = result.get("value", result) if isinstance(result, dict) else result
    if result != "ok":
        raise MarionetteError(f"addLoginAsync failed: {result}")


SET_PRIMARY_PASSWORD_SCRIPT = """
const [password, resolve] = arguments;
(async () => {
  const token = Cc["@mozilla.org/security/internalkeytoken;1"]
    .createInstance(Ci.nsIPKCS11Token);
  // A never-initialized token takes its first password through
  // changePassword("", new), not initPassword. See changemp.js: the
  // uninitialized case sets oldpw = "" and calls changePassword.
  token.changePassword("", password);
  resolve("ok " + token.needsLogin() + " " + token.checkPassword(password));
})().catch(e => resolve("error: " + e));
"""


def set_primary_password(fx, password):
    result = fx.client.execute_async_script(SET_PRIMARY_PASSWORD_SCRIPT, [password])
    result = result.get("value", result) if isinstance(result, dict) else result
    if not result.startswith("ok "):
        raise MarionetteError(f"changePassword failed: {result}")


# Synthetic credentials only. See core/testdata/README.md.
STANDARD_LOGINS = [
    dict(hostname="https://example.com", username="fixture-user-1",
         password="fixture-pass-1", form_action_origin="https://example.com",
         username_field="user", password_field="pass"),
    dict(hostname="https://sub.example.org", username="fixture-user-2",
         password="fixture-pass-2", form_action_origin="https://sub.example.org",
         username_field="user", password_field="pass"),
    dict(hostname="http://plain.example.net", username="fixture-user-3",
         password="fixture-pass-3", http_realm="Restricted Area"),
]

PRIMARY_PASSWORD_FIXTURE = "fixture-primary-password-1"


def cmd_fresh(args):
    with FirefoxDriver(args.firefox, args.profile, args.port) as fx:
        for login in STANDARD_LOGINS:
            add_login(fx, **login)


def cmd_primary(args):
    with FirefoxDriver(args.firefox, args.profile, args.port) as fx:
        for login in STANDARD_LOGINS:
            add_login(fx, **login)
        set_primary_password(fx, PRIMARY_PASSWORD_FIXTURE)


def cmd_sync_shaped(args):
    with FirefoxDriver(args.firefox, args.profile, args.port) as fx:
        for login in STANDARD_LOGINS:
            add_login(fx, **login)
        add_login(
            fx,
            hostname="chrome://FirefoxAccounts",
            username="fixture@example.com",
            password=json.dumps({"kSync": "fixture-sync-key", "kXCS": "fixture-kxcs"}),
            http_realm="Firefox Accounts credentials",
        )
        add_login(
            fx,
            hostname="moz-extension://fixture-extension-id",
            username="fixture-ext-user",
            password="fixture-ext-pass",
            http_realm="fixture-extension-realm",
        )

    logins_path = os.path.join(args.profile, "logins.json")
    with open(logins_path, encoding="utf-8") as f:
        data = json.load(f)
    now = int(time.time() * 1000)
    data["logins"].append({
        "id": 9001,
        "guid": "{fixture-tombstone-0000-000000000001}",
        "deleted": True,
        "everSynced": True,
        "syncCounter": 1,
        "timePasswordChanged": now,
    })
    data["logins"].append({
        "id": 9002,
        "guid": "{fixture-tombstone-0000-000000000002}",
        "deleted": True,
        "everSynced": True,
        "syncCounter": 1,
        "timePasswordChanged": now,
    })
    with open(logins_path, "w", encoding="utf-8") as f:
        json.dump(data, f, indent=2)


def cmd_migrate(args):
    """Reopens an existing (unmigrated) profile once with this Firefox."""
    with FirefoxDriver(args.firefox, args.profile, args.port):
        pass


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--firefox", default=DEFAULT_FIREFOX, help="path to the firefox binary")
    parser.add_argument("--profile", required=True, help="profile directory to create or reopen")
    parser.add_argument("--port", type=int, default=MARIONETTE_PORT)
    sub = parser.add_subparsers(dest="fixture", required=True)
    sub.add_parser("fresh")
    sub.add_parser("primary")
    sub.add_parser("sync-shaped")
    sub.add_parser("migrate")

    args = parser.parse_args()
    if os.path.exists(os.path.join(args.profile, "key4.db")) and args.fixture != "migrate":
        sys.exit(f"refusing to overwrite an existing profile at {args.profile}")

    {
        "fresh": cmd_fresh,
        "primary": cmd_primary,
        "sync-shaped": cmd_sync_shaped,
        "migrate": cmd_migrate,
    }[args.fixture](args)
    print(f"wrote {args.profile}")


if __name__ == "__main__":
    main()
