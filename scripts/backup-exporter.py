#!/usr/bin/env python3
import json
import os
from http.server import BaseHTTPRequestHandler, HTTPServer


def escape_label_value(value: str) -> str:
    return value.replace("\\", "\\\\").replace("\n", "\\n").replace('"', '\\"')


def read_state(state_file: str) -> tuple[float, float]:
    try:
        with open(state_file, "r", encoding="utf-8") as f:
            data = json.load(f)
    except (FileNotFoundError, json.JSONDecodeError, OSError):
        return 0.0, 0.0

    last_success = float(data.get("last_success_epoch", 0.0) or 0.0)
    last_size = float(data.get("last_backup_size_bytes", 0.0) or 0.0)
    return last_success, last_size


class Handler(BaseHTTPRequestHandler):
    def do_GET(self) -> None:  # noqa: N802
        if self.path == "/healthz":
            body = b"ok\n"
            self.send_response(200)
            self.send_header("Content-Type", "text/plain; charset=utf-8")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
            return

        if self.path != "/metrics":
            self.send_error(404, "Not Found")
            return

        db = escape_label_value(os.getenv("POSTGRES_DB", "unknown"))
        bucket = escape_label_value(os.getenv("BUCKET_BACKUP_NAME", "unknown"))
        state_file = os.getenv("BACKUP_STATE_FILE", "/backup-state/last-backup-state.json")
        last_success, last_size = read_state(state_file)

        metrics = (
            "# HELP backup_last_success_timestamp_seconds Unix timestamp of the last successful backup.\n"
            "# TYPE backup_last_success_timestamp_seconds gauge\n"
            f'backup_last_success_timestamp_seconds{{db="{db}",bucket="{bucket}"}} {last_success:.0f}\n'
            "# HELP backup_last_size_bytes Size in bytes of the last successful backup.\n"
            "# TYPE backup_last_size_bytes gauge\n"
            f'backup_last_size_bytes{{db="{db}",bucket="{bucket}"}} {last_size:.0f}\n'
        ).encode("utf-8")

        self.send_response(200)
        self.send_header("Content-Type", "text/plain; version=0.0.4; charset=utf-8")
        self.send_header("Content-Length", str(len(metrics)))
        self.end_headers()
        self.wfile.write(metrics)

    def log_message(self, format: str, *args) -> None:  # noqa: A003
        return


if __name__ == "__main__":
    server = HTTPServer(("0.0.0.0", 9808), Handler)
    server.serve_forever()
