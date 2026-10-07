#!/usr/bin/env python3
import hmac
import json
import os
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import urlsplit

EVENT_MARKER = "@DS@"
MAX_LOG_TAIL_BYTES = 4 * 1024 * 1024


def apply_event(count, event):
    if not event:
        return count
    if event.get("ev") == "commands":
        return 0
    if event.get("ev") == "players" and isinstance(event.get("list"), list):
        return len(event["list"])
    return count


def parse_event(line):
    marker = line.find(EVENT_MARKER)
    if marker < 0:
        return None
    try:
        event = json.loads(line[marker + len(EVENT_MARKER):].strip())
    except (json.JSONDecodeError, TypeError):
        return None
    return event if isinstance(event, dict) else None


def player_count_from_lines(lines):
    count = None
    for line in lines:
        count = apply_event(count, parse_event(line))
    return count


class PlayerCountReader:
    def __init__(self, data_dir):
        self.log_path = Path(data_dir) / "logs" / "player-count-console.log"
        self.lock = threading.Lock()
        self.offset = 0
        self.identity = None
        self.pending = b""
        self.count = None
        try:
            stat = self.log_path.stat()
            self.offset = stat.st_size
            self.identity = (stat.st_dev, stat.st_ino)
        except OSError:
            pass

    def read_count(self):
        with self.lock:
            try:
                with self.log_path.open("rb") as log_file:
                    stat = os.fstat(log_file.fileno())
                    identity = (stat.st_dev, stat.st_ino)
                    if identity != self.identity or stat.st_size < self.offset:
                        self.identity = identity
                        self.offset = 0
                        self.pending = b""
                        self.count = None

                    if stat.st_size == self.offset:
                        return self.count

                    delta_size = stat.st_size - self.offset
                    if delta_size > MAX_LOG_TAIL_BYTES:
                        self.offset = stat.st_size - MAX_LOG_TAIL_BYTES
                        self.pending = b""
                        self.count = None
                    log_file.seek(self.offset)
                    data = log_file.read()
                    self.offset += len(data)
            except OSError:
                return None

            parts = (self.pending + data).split(b"\n")
            self.pending = parts.pop()
            for line in parts:
                text = line.decode("utf-8", errors="replace")
                self.count = apply_event(self.count, parse_event(text))
            return self.count


def make_handler(reader, token):
    class PlayerCountHandler(BaseHTTPRequestHandler):
        def do_GET(self):
            if urlsplit(self.path).path != "/player-count":
                self.send_error(404)
                return

            if token:
                authorization = self.headers.get("Authorization", "")
                scheme, separator, supplied = authorization.partition(" ")
                if (
                    not separator
                    or scheme.lower() != "bearer"
                    or not hmac.compare_digest(supplied.strip(), token)
                ):
                    self.send_json(401, {"error": "unauthorized"})
                    return

            count = reader.read_count()
            if count is None:
                self.send_json(503, {"error": "player count not ready"})
                return
            self.send_json(200, {"numPlayers": count, "maxPlayers": None})

        def send_json(self, status, payload):
            body = json.dumps(payload, separators=(",", ":")).encode("utf-8")
            self.send_response(status)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body)))
            self.send_header("Cache-Control", "no-store")
            self.end_headers()
            self.wfile.write(body)

        def log_message(self, _format, *_args):
            return

    return PlayerCountHandler


def main():
    host = os.environ.get("PLAYER_COUNT_HOST", "0.0.0.0")
    try:
        port = int(os.environ.get("PLAYER_COUNT_PORT", "4202"))
    except ValueError as exc:
        raise SystemExit("PLAYER_COUNT_PORT must be an integer from 1 to 65535") from exc
    if not 1 <= port <= 65535:
        raise SystemExit("PLAYER_COUNT_PORT must be an integer from 1 to 65535")

    data_dir = os.environ.get("DATA_DIR", "/home/container/data")
    token = os.environ.get("PLAYER_COUNT_TOKEN", "")
    reader = PlayerCountReader(data_dir)
    server = ThreadingHTTPServer((host, port), make_handler(reader, token))
    print(f"[player-count] listening on {host}:{port}", flush=True)
    server.serve_forever()


if __name__ == "__main__":
    main()
