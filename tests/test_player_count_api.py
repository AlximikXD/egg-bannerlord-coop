import json
import tempfile
import threading
import unittest
from http.server import HTTPServer
from pathlib import Path
from urllib.error import HTTPError
from urllib.request import Request, urlopen

from player_count_api import (
    PlayerCountReader,
    make_handler,
    parse_event,
    player_count_from_lines,
)


class PlayerCountTests(unittest.TestCase):
    def test_parses_structured_player_snapshot(self):
        event = parse_event(
            '01:01:03.015 [DedicatedServer] @DS@'
            '{"ev":"players","list":[{"id":1},{"id":2}]}'
        )
        self.assertEqual(event["ev"], "players")
        self.assertEqual(len(event["list"]), 2)

    def test_counts_latest_snapshot_after_startup(self):
        lines = [
            '@DS@{"ev":"commands","list":["players"]}',
            '@DS@{"ev":"players","list":[{"id":1},{"id":2}]}',
            '@DS@{"ev":"players","list":[{"id":1}]}',
        ]
        self.assertEqual(player_count_from_lines(lines), 1)

    def test_empty_snapshot_is_zero(self):
        lines = [
            '@DS@{"ev":"commands","list":["players"]}',
            '@DS@{"ev":"players","list":[]}',
        ]
        self.assertEqual(player_count_from_lines(lines), 0)

    def test_new_session_without_snapshot_starts_at_zero(self):
        lines = [
            '@DS@{"ev":"players","list":[{"id":1}]}',
            '@DS@{"ev":"commands","list":["players"]}',
        ]
        self.assertEqual(player_count_from_lines(lines), 0)

    def test_returns_unavailable_until_startup_event(self):
        self.assertIsNone(player_count_from_lines(["server starting"]))

    def test_reads_new_events_from_coop_server_log(self):
        with tempfile.TemporaryDirectory() as tmp:
            log_dir = Path(tmp) / "logs"
            log_dir.mkdir()
            reader = PlayerCountReader(tmp)
            log_path = log_dir / "Coop_server.log"
            log_path.write_text(
                '@DS@{"ev":"commands","list":["players"]}\n'
                '@DS@{"ev":"players","list":[{"id":1},{"id":2}]}\n',
                encoding="utf-8",
            )
            self.assertEqual(reader.read_count(), 2)

    def test_does_not_return_previous_session_snapshot(self):
        with tempfile.TemporaryDirectory() as tmp:
            log_dir = Path(tmp) / "logs"
            log_dir.mkdir()
            log_path = log_dir / "Coop_server.log"
            log_path.write_text(
                '@DS@{"ev":"commands","list":[]}\n'
                '@DS@{"ev":"players","list":[{"id":1}]}\n',
                encoding="utf-8",
            )
            reader = PlayerCountReader(tmp)
            self.assertIsNone(reader.read_count())

            with log_path.open("a", encoding="utf-8") as log_file:
                log_file.write('@DS@{"ev":"commands","list":[]}\n')
            self.assertEqual(reader.read_count(), 0)

    def test_http_endpoint_authenticates_and_returns_count(self):
        with tempfile.TemporaryDirectory() as tmp:
            log_dir = Path(tmp) / "logs"
            log_dir.mkdir()
            reader = PlayerCountReader(tmp)
            log_path = log_dir / "Coop_server.log"
            log_path.write_text(
                '@DS@{"ev":"commands","list":[]}\n'
                '@DS@{"ev":"players","list":[{"id":1},{"id":2}]}\n',
                encoding="utf-8",
            )
            server = HTTPServer(
                ("127.0.0.1", 0),
                make_handler(reader, "test-token"),
            )
            thread = threading.Thread(target=server.serve_forever, daemon=True)
            thread.start()
            self.addCleanup(server.server_close)
            self.addCleanup(thread.join, 1)
            self.addCleanup(server.shutdown)
            url = f"http://127.0.0.1:{server.server_port}/player-count"

            with self.assertRaises(HTTPError) as error:
                urlopen(url)
            self.assertEqual(error.exception.code, 401)
            error.exception.close()

            request = Request(
                url,
                headers={"Authorization": "Bearer test-token"},
            )
            with urlopen(request) as response:
                self.assertEqual(response.status, 200)
                self.assertEqual(
                    json.load(response),
                    {"numPlayers": 2, "maxPlayers": None},
                )

    def test_ignores_malformed_events(self):
        lines = [
            '@DS@{"ev":"commands","list":[]}',
            '@DS@not json',
        ]
        self.assertEqual(player_count_from_lines(lines), 0)
        self.assertIsNone(parse_event("ordinary server log line"))


if __name__ == "__main__":
    unittest.main()
