#!/usr/bin/env python3
"""Classify a macOS console screenshot or VNC framebuffer.

A logged-in desktop is a picture. The failure this script exists to catch is
the near-uniform dark grey loginwindow framebuffer (about #121211) that
Screen Sharing was publishing instead of Finder.

The VNC probe speaks just enough RFB 3.8 to authenticate with the legacy VNC
password (security type 2) and sample Raw rectangles. Apple authentication
(security type 30) is reported as a skip: noVNC can still use it, and a skip
must not fail setup. A decoded framebuffer that is black does fail setup.
"""

from __future__ import annotations

import os
import socket
import struct
import subprocess
import sys
import time
import zlib

# Observed on the broken runner: the noVNC canvas averaged about #121211.
# Mean luminance of that grey is ~18, and essentially every pixel is dark.
BLACK_MEAN_MAX = 26
BLACK_DARK_PPM_MIN = 950
DARK_LUMA = 40


def picture_kind(mean: int, dark_ppm: int) -> str:
    if mean < BLACK_MEAN_MAX and dark_ppm > BLACK_DARK_PPM_MIN:
        return "black"
    return "picture"


def _luma(r: int, g: int, b: int) -> int:
    return (r * 2126 + g * 7152 + b * 722) // 10000


def stats_rgb(pixels: list[tuple[int, int, int]]) -> tuple[int, int, int]:
    if not pixels:
        return 0, 1000, 0
    total = 0
    dark = 0
    seen: set[tuple[int, int, int]] = set()
    step = 1
    if len(pixels) > 80000:
        step = len(pixels) // 80000
    sampled = 0
    for i in range(0, len(pixels), step):
        r, g, b = pixels[i]
        seen.add((r, g, b))
        luma = _luma(r, g, b)
        total += luma
        sampled += 1
        if luma < DARK_LUMA:
            dark += 1
    mean = total // sampled
    dark_ppm = (dark * 1000) // sampled
    return mean, dark_ppm, len(seen)


def _paeth(a: int, b: int, c: int) -> int:
    p = a + b - c
    pa = abs(p - a)
    pb = abs(p - b)
    pc = abs(p - c)
    if pa <= pb and pa <= pc:
        return a
    if pb <= pc:
        return b
    return c


def _unfilter(data: bytes, height: int, width_bytes: int, bpp: int) -> bytes:
    rows = []
    expected = height * (width_bytes + 1)
    if len(data) < expected:
        raise ValueError("truncated image data")
    prev = bytearray(width_bytes)
    offset = 0
    for _ in range(height):
        filt = data[offset]
        row = bytearray(data[offset + 1 : offset + 1 + width_bytes])
        offset += 1 + width_bytes
        if filt == 0:
            pass
        elif filt == 1:
            for i in range(width_bytes):
                left = row[i - bpp] if i >= bpp else 0
                row[i] = (row[i] + left) & 0xFF
        elif filt == 2:
            for i in range(width_bytes):
                row[i] = (row[i] + prev[i]) & 0xFF
        elif filt == 3:
            for i in range(width_bytes):
                left = row[i - bpp] if i >= bpp else 0
                row[i] = (row[i] + ((left + prev[i]) // 2)) & 0xFF
        elif filt == 4:
            for i in range(width_bytes):
                left = row[i - bpp] if i >= bpp else 0
                up_left = prev[i - bpp] if i >= bpp else 0
                row[i] = (row[i] + _paeth(left, prev[i], up_left)) & 0xFF
        else:
            raise ValueError("unsupported png filter %s" % filt)
        rows.append(bytes(row))
        prev = row
    return b"".join(rows)


def _read_chunks(blob: bytes) -> tuple[dict, bytes]:
    if not blob.startswith(b"\x89PNG\r\n\x1a\n"):
        raise ValueError("not a png")
    pos = 8
    ihdr = None
    idat = []
    while pos + 8 <= len(blob):
        length = struct.unpack(">I", blob[pos : pos + 4])[0]
        pos += 4
        tag = blob[pos : pos + 4]
        pos += 4
        data = blob[pos : pos + length]
        pos += length
        pos += 4  # crc
        if tag == b"IHDR":
            ihdr = data
        elif tag == b"IDAT":
            idat.append(data)
        elif tag == b"IEND":
            break
    if ihdr is None or not idat:
        raise ValueError("png missing image data")
    return {"ihdr": ihdr}, b"".join(idat)


def png_pixels(path: str) -> tuple[int, int, list[tuple[int, int, int]]]:
    with open(path, "rb") as handle:
        blob = handle.read()
    meta, compressed = _read_chunks(blob)
    width, height, bit_depth, color_type, _comp, _filt, interlace = struct.unpack(
        ">IIBBBBB", meta["ihdr"]
    )
    if interlace != 0:
        raise ValueError("interlaced png")
    if bit_depth != 8:
        raise ValueError("unsupported bit depth")
    if color_type == 2:
        bpp = 3
    elif color_type == 6:
        bpp = 4
    else:
        raise ValueError("unsupported color type %s" % color_type)
    raw = zlib.decompress(compressed)
    rows = _unfilter(raw, height, width * bpp, bpp)
    pixels = []
    for y in range(height):
        row = rows[y * width * bpp : (y + 1) * width * bpp]
        for x in range(width):
            i = x * bpp
            pixels.append((row[i], row[i + 1], row[i + 2]))
    return width, height, pixels


def png_stats_line(path: str) -> str:
    width, height, pixels = png_pixels(path)
    mean, dark_ppm, distinct = stats_rgb(pixels)
    kind = picture_kind(mean, dark_ppm)
    return "%s %s %s %s %s %s" % (kind, mean, dark_ppm, distinct, width, height)


def _bitrev(value: int) -> int:
    value = ((value & 0xF0) >> 4) | ((value & 0x0F) << 4)
    value = ((value & 0xCC) >> 2) | ((value & 0x33) << 2)
    value = ((value & 0xAA) >> 1) | ((value & 0x55) << 1)
    return value


def vnc_des_response(password: str, challenge: bytes) -> bytes:
    """VNC auth: DES-ECB with the bit-reversed password as the key."""
    raw = password.encode("utf-8", "replace")[:8]
    raw = raw + b"\0" * (8 - len(raw))
    key = bytes(_bitrev(b) for b in raw)
    key_hex = key.hex()
    commands = [
        ["openssl", "enc", "-des-ecb", "-nopad", "-K", key_hex, "-nosalt"],
        [
            "openssl",
            "enc",
            "-des-ecb",
            "-nopad",
            "-K",
            key_hex,
            "-nosalt",
            "-provider",
            "legacy",
            "-provider",
            "default",
        ],
    ]
    last_err = ""
    for cmd in commands:
        proc = subprocess.run(cmd, input=challenge, capture_output=True, check=False)
        if proc.returncode == 0 and len(proc.stdout) == 16:
            return proc.stdout
        last_err = proc.stderr.decode("utf-8", "replace").strip()
    raise RuntimeError(last_err or "openssl DES failed")


def _recv_exact(sock: socket.socket, count: int) -> bytes:
    buf = b""
    while len(buf) < count:
        chunk = sock.recv(count - len(buf))
        if not chunk:
            raise EOFError("short read")
        buf += chunk
    return buf


def _read_framebuffer(sock: socket.socket) -> bytes | str:
    """Read server messages until one Raw framebuffer update arrives."""
    while True:
        kind = _recv_exact(sock, 1)[0]
        if kind == 0:
            _recv_exact(sock, 1)
            rects = struct.unpack(">H", _recv_exact(sock, 2))[0]
            chunks = []
            for _ in range(rects):
                _x, _y, width, height, encoding = struct.unpack(">HHHHi", _recv_exact(sock, 12))
                if encoding != 0:
                    return "encoding-%s" % encoding
                nbytes = width * height * 4
                if nbytes < 0 or nbytes > 8_000_000:
                    return "rect-too-large"
                chunks.append(_recv_exact(sock, nbytes))
            return b"".join(chunks)
        if kind == 2:
            continue
        if kind == 3:
            _recv_exact(sock, 3)
            length = struct.unpack(">I", _recv_exact(sock, 4))[0]
            if length > 1_000_000:
                return "cut-too-large"
            _recv_exact(sock, length)
            continue
        return "message-%s" % kind


def _bgra_pixels(raw: bytes) -> list[tuple[int, int, int]]:
    pixels = []
    step = 4
    # Sample at most ~80k pixels. Stride in pixels.
    count = len(raw) // 4
    stride = 1
    if count > 80000:
        stride = count // 80000
    for index in range(0, count, stride):
        i = index * 4
        b, g, r = raw[i], raw[i + 1], raw[i + 2]
        pixels.append((r, g, b))
    return pixels


def sample_vnc(host: str, port: int, password: str) -> str:
    """Return one line: kind mean dark_ppm distinct width height note."""
    sock = socket.socket()
    sock.settimeout(8)
    try:
        sock.connect((host, port))
        banner = _recv_exact(sock, 12)
        if not banner.startswith(b"RFB "):
            return "skip 0 0 0 0 0 note=not-rfb"
        sock.sendall(b"RFB 003.008\n")
        ntypes = _recv_exact(sock, 1)[0]
        if ntypes == 0:
            return "skip 0 0 0 0 0 note=no-security-types"
        types = list(_recv_exact(sock, ntypes))
        type_note = ",".join(str(item) for item in types)
        chosen = None
        for candidate in (2, 1):
            if candidate in types:
                chosen = candidate
                break
        if chosen is None:
            return "skip 0 0 0 0 0 note=types:%s" % type_note
        sock.sendall(bytes([chosen]))
        if chosen == 2:
            challenge = _recv_exact(sock, 16)
            try:
                sock.sendall(vnc_des_response(password, challenge))
            except Exception as exc:
                return "skip 0 0 0 0 0 note=des:%s" % str(exc).splitlines()[-1][:120]
        result = struct.unpack(">I", _recv_exact(sock, 4))[0]
        if result != 0:
            reason = ""
            if result == 1:
                try:
                    length = struct.unpack(">I", _recv_exact(sock, 4))[0]
                    reason = _recv_exact(sock, min(length, 200)).decode("utf-8", "replace")
                except Exception:
                    reason = ""
            return "skip 0 0 0 0 0 note=auth-failed:%s" % reason[:80]
        sock.sendall(b"\x01")  # shared
        width, height = struct.unpack(">HH", _recv_exact(sock, 4))
        _recv_exact(sock, 16)  # pixel format
        name_len = struct.unpack(">I", _recv_exact(sock, 4))[0]
        if name_len:
            _recv_exact(sock, name_len)
        if width < 2 or height < 2 or width > 8000 or height > 8000:
            return "skip 0 0 0 %s %s note=bad-size" % (width, height)
        fmt = bytearray(20)
        fmt[0] = 0
        fmt[4] = 32
        fmt[5] = 24
        fmt[6] = 0
        fmt[7] = 1
        struct.pack_into(">HHH", fmt, 8, 255, 255, 255)
        fmt[14] = 16
        fmt[15] = 8
        fmt[16] = 0
        sock.sendall(fmt)
        sock.sendall(struct.pack(">BBHi", 2, 0, 1, 0))
        strip_h = 48 if height >= 48 else height
        regions = [(0, 0, width, strip_h)]
        mid_y = max(0, (height // 2) - (strip_h // 2))
        if mid_y != 0:
            regions.append((0, mid_y, width, strip_h))
        # Screen Sharing sometimes answers the first update with an empty
        # black buffer and only fills it on the next request.
        blobs = []
        for round_index in range(2):
            round_blobs = []
            failed = ""
            for x, y, w, h in regions:
                sock.sendall(struct.pack(">BBHHHH", 3, 0, x, y, w, h))
                got = _read_framebuffer(sock)
                if isinstance(got, str):
                    failed = got
                    break
                round_blobs.append(got)
            if failed:
                if blobs:
                    break
                return "skip 0 0 0 %s %s note=%s" % (width, height, failed)
            blobs = round_blobs
            if round_index == 0:
                time.sleep(0.4)
        pixels = _bgra_pixels(b"".join(blobs))
        mean, dark_ppm, distinct = stats_rgb(pixels)
        kind = picture_kind(mean, dark_ppm)
        return "%s %s %s %s %s %s note=types:%s" % (
            kind,
            mean,
            dark_ppm,
            distinct,
            width,
            height,
            type_note,
        )
    except Exception as exc:
        text = str(exc).splitlines()[-1][:160] if str(exc) else exc.__class__.__name__
        return "skip 0 0 0 0 0 note=%s" % text
    finally:
        try:
            sock.close()
        except Exception:
            pass


def write_solid_png(path: str, width: int, height: int, rgb: tuple[int, int, int], filt: int) -> None:
    r, g, b = rgb
    rows = []
    prev = bytearray(width * 3)
    for _y in range(height):
        raw = bytearray()
        for _x in range(width):
            raw.extend((r, g, b))
        stored = bytearray(len(raw))
        if filt == 0:
            stored[:] = raw
        elif filt == 1:
            for i in range(len(raw)):
                left = raw[i - 3] if i >= 3 else 0
                stored[i] = (raw[i] - left) & 0xFF
        elif filt == 2:
            for i in range(len(raw)):
                stored[i] = (raw[i] - prev[i]) & 0xFF
        elif filt == 3:
            for i in range(len(raw)):
                left = raw[i - 3] if i >= 3 else 0
                stored[i] = (raw[i] - ((left + prev[i]) // 2)) & 0xFF
        elif filt == 4:
            for i in range(len(raw)):
                left = raw[i - 3] if i >= 3 else 0
                up_left = prev[i - 3] if i >= 3 else 0
                stored[i] = (raw[i] - _paeth(left, prev[i], up_left)) & 0xFF
        else:
            raise ValueError("filter")
        rows.append(bytes([filt]) + bytes(stored))
        prev = raw
    payload = zlib.compress(b"".join(rows))

    def chunk(tag: bytes, data: bytes) -> bytes:
        crc = zlib.crc32(tag + data) & 0xFFFFFFFF
        return struct.pack(">I", len(data)) + tag + data + struct.pack(">I", crc)

    ihdr = struct.pack(">IIBBBBB", width, height, 8, 2, 0, 0, 0)
    blob = b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", ihdr) + chunk(b"IDAT", payload) + chunk(b"IEND", b"")
    with open(path, "wb") as handle:
        handle.write(blob)


def _serve_rfb(conn: socket.socket, rgb: tuple[int, int, int], security: int) -> None:
    conn.sendall(b"RFB 003.008\n")
    version = _recv_exact(conn, 12)
    if version[:3] != b"RFB":
        return
    conn.sendall(bytes([1, security]))
    chosen = _recv_exact(conn, 1)[0]
    if chosen != security:
        return
    if security == 2:
        challenge = bytes(range(16))
        conn.sendall(challenge)
        _recv_exact(conn, 16)
    conn.sendall(struct.pack(">I", 0))
    _recv_exact(conn, 1)
    width, height = 16, 8
    name = b"test"
    pixel = struct.pack(">BBBBHHHBBB3x", 32, 24, 0, 1, 255, 255, 255, 16, 8, 0)
    conn.sendall(struct.pack(">HH", width, height) + pixel + struct.pack(">I", len(name)) + name)
    # Swallow SetPixelFormat and SetEncodings, then answer each update request.
    pending = b""
    while True:
        try:
            chunk = conn.recv(64)
        except socket.timeout:
            return
        if not chunk:
            return
        pending += chunk
        while pending:
            kind = pending[0]
            if kind == 0 and len(pending) >= 20:
                pending = pending[20:]
                continue
            if kind == 2 and len(pending) >= 8:
                count = struct.unpack(">H", pending[2:4])[0]
                need = 4 + count * 4
                if len(pending) < need:
                    break
                pending = pending[need:]
                continue
            if kind == 3 and len(pending) >= 10:
                pending = pending[10:]
                raw = bytes([rgb[2], rgb[1], rgb[0], 0]) * (width * height)
                conn.sendall(struct.pack(">BBHHHHHi", 0, 0, 1, 0, 0, width, height, 0) + raw)
                continue
            break


def self_test() -> None:
    import tempfile

    password = "12345678"
    challenge = bytes(range(16))
    response = vnc_des_response(password, challenge)
    if response.hex() != "83dd2b4dbd04367f28578fdd5b142740":
        raise SystemExit("unexpected VNC DES response %s" % response.hex())

    tmp = tempfile.mkdtemp()
    dark = os.path.join(tmp, "dark.png")
    bright = os.path.join(tmp, "bright.png")
    write_solid_png(dark, 32, 16, (0x12, 0x12, 0x11), 0)
    kind = png_stats_line(dark).split()[0]
    if kind != "black":
        raise SystemExit("dark png classified as %s" % kind)
    for filt in (0, 1, 2, 3, 4):
        write_solid_png(bright, 24, 12, (80, 140, 210), filt)
        line = png_stats_line(bright)
        if not line.startswith("picture "):
            raise SystemExit("filter %s classified as %s" % (filt, line))
        _kind, mean, _dark, distinct, width, height = line.split()[:6]
        if int(width) != 24 or int(height) != 12 or int(distinct) < 1 or int(mean) < 80:
            raise SystemExit("bad stats for filter %s: %s" % (filt, line))

    for security, rgb, expect in ((1, (0x12, 0x12, 0x11), "black"), (1, (180, 200, 220), "picture")):
        server = socket.socket()
        server.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        server.bind(("127.0.0.1", 0))
        server.listen(1)
        port = server.getsockname()[1]

        import threading

        holder: dict[str, str] = {}

        def client() -> None:
            holder["line"] = sample_vnc("127.0.0.1", port, "secret")

        thread = threading.Thread(target=client)
        thread.start()
        conn, _addr = server.accept()
        conn.settimeout(5)
        try:
            _serve_rfb(conn, rgb, security)
        finally:
            conn.close()
            server.close()
        thread.join(10)
        line = holder.get("line", "")
        if not line.startswith(expect + " "):
            raise SystemExit("vnc %s expected %s got %s" % (rgb, expect, line))

    # Security type 30 alone cannot be sampled and must not look like black.
    server = socket.socket()
    server.bind(("127.0.0.1", 0))
    server.listen(1)
    port = server.getsockname()[1]
    holder = {}

    def client30() -> None:
        holder["line"] = sample_vnc("127.0.0.1", port, "secret")

    thread = threading.Thread(target=client30)
    thread.start()
    conn, _addr = server.accept()
    conn.settimeout(5)
    try:
        conn.sendall(b"RFB 003.008\n")
        _recv_exact(conn, 12)
        conn.sendall(bytes([1, 30]))
        try:
            _recv_exact(conn, 1)
        except EOFError:
            pass
    finally:
        conn.close()
        server.close()
    thread.join(10)
    if not str(holder.get("line", "")).startswith("skip "):
        raise SystemExit("type 30 should skip, got %s" % holder.get("line"))
    print("gui-check self-test ok")


def main() -> None:
    cmd = sys.argv[1] if len(sys.argv) > 1 else ""
    if cmd == "png-stats":
        try:
            sys.stdout.write(png_stats_line(sys.argv[2]) + "\n")
        except Exception as exc:
            sys.stdout.write("error 0 0 0 0 0 note=%s\n" % str(exc).splitlines()[-1][:160])
            raise SystemExit(1) from exc
        return
    if cmd == "vnc-sample":
        port = int(sys.argv[2] if len(sys.argv) > 2 else "5900")
        password = os.environ.get("VNC_PASSWORD", "")
        sys.stdout.write(sample_vnc("127.0.0.1", port, password) + "\n")
        return
    if cmd == "self-test":
        self_test()
        return
    sys.stderr.write("Usage: macos-gui-check.py png-stats FILE | vnc-sample [port] | self-test\n")
    raise SystemExit(2)


if __name__ == "__main__":
    main()
