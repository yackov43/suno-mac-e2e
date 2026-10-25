#!/usr/bin/env python3
"""Passwordless view-only macOS desktop over plain HTTP.

Screen Sharing offers Apple RFB types 30 and 33 beside legacy VNC. noVNC then
asks for a Mac username and password, and VNC_PASSWORD does not answer that
dialog. This server never speaks RFB. It serves the latest console picture
on 127.0.0.1 with no basic-auth, so a Cloudflare quick tunnel can publish it
as a normal HTTPS page. The Actions script captures with screencapture from
bash (the same way the GUI check does) and passes --serve-only. Running this
file by itself captures in-process.

The page is view only. Mouse and keyboard stay on ttyd or noVNC.
"""

from __future__ import annotations

import argparse
import os
import struct
import subprocess
import sys
import threading
import time
import urllib.error
import urllib.request
import zlib
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

# The browser polls at this cadence. Keep it inside 1–2 seconds.
PAGE_REFRESH_MS = 1000
DEFAULT_INTERVAL = 1.0

PAGE_TEMPLATE = """<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>macOS desktop — view only</title>
<noscript><meta http-equiv="refresh" content="2"></noscript>
<style>
  html, body { margin: 0; height: 100%; background: #000; color: #f5f5f7;
    font: 14px/1.35 -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif; }
  body { display: flex; flex-direction: column; height: 100vh; overflow: hidden; }
  header { flex: 0 0 auto; padding: 8px 12px; background: #1c1c1e; }
  h1 { margin: 0; font-size: 16px; font-weight: 600; }
  p { margin: 4px 0 0; color: #d1d1d6; }
  main { flex: 1 1 auto; min-height: 0; display: flex; }
  img { width: 100%; height: 100%; object-fit: contain; background: #000; display: block; }
  .err { color: #ffd60a; }
</style>
</head>
<body>
<header>
  <h1>macOS desktop — view only</h1>
  <p id="status">Nothing to type. This page updates about every second. View only. Mouse and keyboard stay on the browser shell or noVNC.</p>
</header>
<main>
  <img id="screen" src="/screen" alt="macOS desktop">
</main>
<script>
var img = document.getElementById("screen");
var status = document.getElementById("status");
function tick() {
  var next = "/screen?t=" + Date.now();
  var probe = new Image();
  probe.onload = function () {
    img.src = probe.src;
    status.className = "";
    status.textContent = "Live · updated " + new Date().toLocaleTimeString() +
      " · view only. Mouse and keyboard stay on the browser shell or noVNC.";
  };
  probe.onerror = function () {
    status.className = "err";
    status.textContent = "Waiting for a console capture. View only. Mouse and keyboard stay on the browser shell or noVNC.";
  };
  probe.src = next;
}
tick();
setInterval(tick, __REFRESH_MS__);
</script>
</body>
</html>
"""

PAGE_HTML = PAGE_TEMPLATE.replace("__REFRESH_MS__", str(PAGE_REFRESH_MS))

_last_capture_log = 0.0


def log_capture_failure(message: str) -> None:
    global _last_capture_log
    now = time.time()
    if now - _last_capture_log < 30:
        return
    _last_capture_log = now
    sys.stderr.write(message.rstrip() + "\n")


def clamp_interval(value: float) -> float:
    if value < 0.5:
        return 0.5
    if value > 2:
        return 2.0
    return value


def screencapture_bin() -> str:
    path = "/usr/sbin/screencapture"
    if os.path.isfile(path) and os.access(path, os.X_OK):
        return path
    return "screencapture"


def screencapture_commands(dest_jpg: str, dest_png: str) -> list[list[str]]:
    binary = screencapture_bin()
    # -x is non-interactive (no shutter sound, no dialog). -m is the main
    # display. -C includes the cursor. jpg keeps a full-screen frame small
    # enough to refresh through a quick tunnel. Later rows are fallbacks.
    return [
        [binary, "-x", "-C", "-m", "-t", "jpg", dest_jpg],
        [binary, "-x", "-C", "-t", "jpg", dest_jpg],
        [binary, "-x", "-m", "-t", "png", dest_png],
        [binary, "-x", dest_png],
    ]


def image_kind(blob: bytes) -> str:
    if blob.startswith(b"\xff\xd8\xff"):
        return "image/jpeg"
    if blob.startswith(b"\x89PNG\r\n\x1a\n"):
        return "image/png"
    return ""


def image_file_ok(path: str) -> bool:
    try:
        size = os.path.getsize(path)
    except OSError:
        return False
    if size < 24:
        return False
    try:
        with open(path, "rb") as handle:
            head = handle.read(8)
    except OSError:
        return False
    return image_kind(head) != ""


def read_image(path: str) -> bytes | None:
    try:
        with open(path, "rb") as handle:
            blob = handle.read()
    except OSError:
        return None
    if image_kind(blob) == "":
        return None
    return blob


def screencapture_to(dest: str) -> bool:
    jpg_tmp = dest + ".next.jpg"
    png_tmp = dest + ".next.png"
    commands = screencapture_commands(jpg_tmp, png_tmp)
    errors: list[str] = []
    wrote = False
    for command in commands:
        tmp = command[-1]
        try:
            os.remove(tmp)
        except OSError:
            pass
        try:
            completed = subprocess.run(
                command,
                timeout=8,
                check=False,
                stdout=subprocess.PIPE,
                stderr=subprocess.STDOUT,
            )
        except (OSError, subprocess.TimeoutExpired) as exc:
            errors.append(str(exc))
            continue
        if completed.returncode != 0 or not image_file_ok(tmp):
            detail = completed.stdout.decode("utf-8", "replace").strip().replace("\n", " ")
            errors.append("exit %s (%s) %s" % (completed.returncode, command[1] if len(command) > 1 else command[0], detail[:180]))
            continue
        os.replace(tmp, dest)
        wrote = True
        break
    for tmp in (jpg_tmp, png_tmp):
        try:
            os.remove(tmp)
        except OSError:
            pass
    if not wrote and errors:
        log_capture_failure("desktop view capture failed: %s" % errors[-1])
    return wrote


def capture_loop(dest: str, interval: float, stop: threading.Event, capture_fn) -> None:
    while not stop.is_set():
        started = time.monotonic()
        try:
            capture_fn(dest)
        except Exception as exc:
            log_capture_failure("desktop view capture error: %s" % exc)
        remaining = interval - (time.monotonic() - started)
        if remaining < 0:
            remaining = 0
        if stop.wait(remaining):
            return


class ViewerHandler(BaseHTTPRequestHandler):
    server_version = "DesktopView/1"
    sys_version = ""

    def do_GET(self) -> None:
        self._respond(send_body=True)

    def do_HEAD(self) -> None:
        self._respond(send_body=False)

    def log_message(self, fmt: str, *args) -> None:
        return

    def _respond(self, send_body: bool) -> None:
        path = self.path.split("?", 1)[0]
        if path in ("/", "/index.html"):
            body = PAGE_HTML.encode("utf-8")
            self._write(200, "text/html; charset=utf-8", body, send_body)
            return
        if path == "/screen":
            blob = read_image(self.server.image_path)
            if blob is None:
                self._write(503, "text/plain; charset=utf-8", b"capture not ready\n", send_body, retry=True)
                return
            self._write(200, image_kind(blob), blob, send_body)
            return
        if path == "/health":
            self._write(200, "text/plain; charset=utf-8", b"ok\n", send_body)
            return
        if path == "/favicon.ico":
            self._write(204, "text/plain; charset=utf-8", b"", send_body)
            return
        self._write(404, "text/plain; charset=utf-8", b"not found\n", send_body)

    def _write(self, code: int, content_type: str, body: bytes, send_body: bool, retry: bool = False) -> None:
        self.send_response(code)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.send_header("X-Content-Type-Options", "nosniff")
        if retry:
            self.send_header("Retry-After", "1")
        self.end_headers()
        if send_body and body:
            self.wfile.write(body)


class ViewerServer(ThreadingHTTPServer):
    allow_reuse_address = True
    daemon_threads = True
    image_path = ""


def serve_forever(host: str, port: int, image_path: str, interval: float, capture_fn, serve_only: bool = False) -> int:
    if host not in ("127.0.0.1", "localhost"):
        sys.stderr.write("desktop view refuses to bind %s; use 127.0.0.1\n" % host)
        return 1
    directory = os.path.dirname(image_path)
    if directory:
        os.makedirs(directory, exist_ok=True)
    stop = threading.Event()
    if not serve_only:
        worker = threading.Thread(
            target=capture_loop,
            args=(image_path, interval, stop, capture_fn),
            daemon=True,
        )
        worker.start()
    try:
        httpd = ViewerServer((host, port), ViewerHandler)
    except OSError as exc:
        stop.set()
        sys.stderr.write("desktop view bind failed: %s\n" % exc)
        return 1
    httpd.image_path = image_path
    bound = httpd.server_address[1]
    sys.stderr.write(
        "desktop view listening on http://%s:%s (no password, view only, refresh %sms)\n"
        % (host, bound, PAGE_REFRESH_MS)
    )
    try:
        httpd.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        stop.set()
        httpd.server_close()
    return 0


def start_background(host: str, port: int, image_path: str, interval: float, capture_fn):
    stop = threading.Event()
    directory = os.path.dirname(image_path)
    if directory:
        os.makedirs(directory, exist_ok=True)
    httpd = ViewerServer((host, port), ViewerHandler)
    httpd.image_path = image_path
    worker = threading.Thread(
        target=capture_loop,
        args=(image_path, interval, stop, capture_fn),
        daemon=True,
    )
    worker.start()
    thread = threading.Thread(target=httpd.serve_forever, daemon=True)
    thread.start()
    return httpd, stop, thread


def tiny_png(red: int, green: int, blue: int) -> bytes:
    def chunk(tag: bytes, data: bytes) -> bytes:
        return (
            struct.pack(">I", len(data))
            + tag
            + data
            + struct.pack(">I", zlib.crc32(tag + data) & 0xFFFFFFFF)
        )

    raw = b"\x00" + bytes((red & 255, green & 255, blue & 255))
    return (
        b"\x89PNG\r\n\x1a\n"
        + chunk(b"IHDR", struct.pack(">IIBBBBB", 1, 1, 8, 2, 0, 0, 0))
        + chunk(b"IDAT", zlib.compress(raw))
        + chunk(b"IEND", b"")
    )


def fetch(url: str) -> tuple[int, dict[str, str], bytes]:
    try:
        with urllib.request.urlopen(url, timeout=2) as response:
            return response.status, {key: value for key, value in response.headers.items()}, response.read()
    except urllib.error.HTTPError as exc:
        body = exc.read()
        return exc.code, {key: value for key, value in exc.headers.items()}, body


def header_ci(headers: dict[str, str], name: str) -> str:
    for key, value in headers.items():
        if key.lower() == name.lower():
            return value
    return ""


def stop_server(httpd, stop: threading.Event) -> None:
    stop.set()
    httpd.shutdown()
    httpd.server_close()


def self_test() -> None:
    if serve_forever("0.0.0.0", 9, "/tmp/desktop-view-refused", 1, None) != 1:
        raise SystemExit("desktop view agreed to bind a non-loopback host")
    if PAGE_REFRESH_MS < 1000 or PAGE_REFRESH_MS > 2000:
        raise SystemExit("page refresh %s ms is outside 1–2 seconds" % PAGE_REFRESH_MS)
    if not (0.5 <= DEFAULT_INTERVAL <= 2):
        raise SystemExit("capture interval %s is outside 0.5–2 seconds" % DEFAULT_INTERVAL)
    if clamp_interval(0) != 0.5 or clamp_interval(5) != 2 or clamp_interval(1) != 1:
        raise SystemExit("clamp_interval drifted from 0.5..2")
    if "<title>macOS desktop — view only</title>" not in PAGE_HTML:
        raise SystemExit("page title missing")
    if "setInterval(tick, %d)" % PAGE_REFRESH_MS not in PAGE_HTML:
        raise SystemExit("page does not poll on the refresh interval")
    if "width: 100%" not in PAGE_HTML or "height: 100%" not in PAGE_HTML or "100vh" not in PAGE_HTML:
        raise SystemExit("page does not fill the window")
    if "object-fit: contain" not in PAGE_HTML:
        raise SystemExit("page crops the desktop")
    lowered = PAGE_HTML.lower()
    if "<input" in lowered or 'type="password"' in lowered or "www-authenticate" in lowered:
        raise SystemExit("page has a login field")
    if "view only" not in lowered:
        raise SystemExit("page does not say it is view only")
    if "basic-auth" in lowered or "vnc_password" in lowered:
        raise SystemExit("page mentions credentials")
    commands = screencapture_commands("/tmp/console.next.jpg", "/tmp/console.next.png")
    if commands[0][0] != screencapture_bin() or "-x" not in commands[0] or "jpg" not in commands[0]:
        raise SystemExit("screencapture command is not a non-interactive jpg capture: %s" % commands[0])
    blob = tiny_png(10, 20, 30)
    if image_kind(blob) != "image/png":
        raise SystemExit("tiny png was not recognized")

    import tempfile

    directory = tempfile.mkdtemp(prefix="desktop-view-")
    try:
        missing = os.path.join(directory, "none.jpg")

        def never(_dest: str) -> bool:
            return False

        cold, cold_stop, _thread = start_background("127.0.0.1", 0, missing, 0.5, never)
        try:
            cold_port = cold.server_address[1]
            page_status = 0
            page_headers: dict[str, str] = {}
            page_body = b""
            deadline = time.time() + 3
            while time.time() < deadline:
                try:
                    page_status, page_headers, page_body = fetch("http://127.0.0.1:%d/" % cold_port)
                except Exception:
                    time.sleep(0.05)
                    continue
                if page_status == 200:
                    break
                time.sleep(0.05)
            if page_status != 200:
                raise SystemExit("viewer page status %s" % page_status)
            if header_ci(page_headers, "WWW-Authenticate"):
                raise SystemExit("viewer page asked for authentication")
            if "no-store" not in header_ci(page_headers, "Cache-Control"):
                raise SystemExit("viewer page is cacheable")
            text = page_body.decode("utf-8")
            if "<title>macOS desktop — view only</title>" not in text:
                raise SystemExit("served page lost its title")
            screen_status, screen_headers, screen_body = fetch("http://127.0.0.1:%d/screen" % cold_port)
            if screen_status != 503:
                raise SystemExit("missing capture returned %s" % screen_status)
            if header_ci(screen_headers, "WWW-Authenticate"):
                raise SystemExit("screen response asked for authentication")
            if b"capture not ready" not in screen_body:
                raise SystemExit("missing capture body was %r" % screen_body[:80])
            missing_status, _headers, missing_body = fetch("http://127.0.0.1:%d/etc/passwd" % cold_port)
            if missing_status != 404 or b"root:" in missing_body:
                raise SystemExit("unexpected path was served")
            with open(missing, "wb") as handle:
                handle.write(tiny_png(9, 40, 70))
            served_status, served_headers, served_body = fetch("http://127.0.0.1:%d/screen?t=external" % cold_port)
            if served_status != 200 or image_kind(served_body) != "image/png":
                raise SystemExit("external capture was not served: %s" % served_status)
            if "no-store" not in header_ci(served_headers, "Cache-Control"):
                raise SystemExit("external capture is cacheable")
            if header_ci(served_headers, "WWW-Authenticate"):
                raise SystemExit("external capture asked for authentication")
        finally:
            stop_server(cold, cold_stop)

        live_path = os.path.join(directory, "screen.jpg")
        counter = {"n": 0}

        def fake(dest: str) -> bool:
            counter["n"] += 1
            tmp = dest + ".next.png"
            with open(tmp, "wb") as handle:
                handle.write(tiny_png(counter["n"] & 255, 80, 160))
            os.replace(tmp, dest)
            return True

        live, live_stop, _thread = start_background("127.0.0.1", 0, live_path, 0.1, fake)
        try:
            live_port = live.server_address[1]
            seen: set[bytes] = set()
            kinds: set[str] = set()
            deadline = time.time() + 3
            while time.time() < deadline and len(seen) < 2:
                try:
                    status, headers, body = fetch("http://127.0.0.1:%d/screen?t=%s" % (live_port, time.time()))
                except Exception:
                    time.sleep(0.05)
                    continue
                if status != 200:
                    time.sleep(0.05)
                    continue
                if header_ci(headers, "WWW-Authenticate"):
                    raise SystemExit("live screen asked for authentication")
                if "no-store" not in header_ci(headers, "Cache-Control"):
                    raise SystemExit("live screen is cacheable")
                kind = image_kind(body)
                if kind == "":
                    raise SystemExit("live screen was not an image")
                kinds.add(header_ci(headers, "Content-Type"))
                seen.add(body)
                time.sleep(0.05)
            if len(seen) < 2:
                raise SystemExit("screen did not update; saw %s frame(s)" % len(seen))
            if kinds != {"image/png"}:
                raise SystemExit("content type was %s" % sorted(kinds))
            health, _headers, health_body = fetch("http://127.0.0.1:%d/health" % live_port)
            if health != 200 or health_body != b"ok\n":
                raise SystemExit("health was %s %r" % (health, health_body))
        finally:
            stop_server(live, live_stop)
    finally:
        try:
            for name in os.listdir(directory):
                os.remove(os.path.join(directory, name))
            os.rmdir(directory)
        except OSError:
            pass


def parse_args(argv: list[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="View-only macOS desktop over HTTP. No password.")
    parser.add_argument("--host", default="127.0.0.1")
    parser.add_argument("--port", type=int, default=8090)
    parser.add_argument("--interval", type=float, default=DEFAULT_INTERVAL)
    parser.add_argument("--image", default="/tmp/suno-mac-e2e/desktop-view/screen.jpg")
    parser.add_argument(
        "--serve-only",
        action="store_true",
        help="Serve the image file only. The caller runs screencapture.",
    )
    return parser.parse_args(argv)


def main(argv: list[str]) -> int:
    if len(argv) > 1 and argv[1] == "--self-test":
        self_test()
        sys.stdout.write("desktop view self-test ok\n")
        return 0
    args = parse_args(argv[1:])
    if args.port < 1 or args.port > 65535:
        sys.stderr.write("desktop view port is out of range\n")
        return 2
    return serve_forever(
        args.host,
        args.port,
        args.image,
        clamp_interval(args.interval),
        None if args.serve_only else screencapture_to,
        serve_only=args.serve_only,
    )


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
