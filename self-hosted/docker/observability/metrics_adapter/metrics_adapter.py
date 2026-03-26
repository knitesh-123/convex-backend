from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from os import getenv
from urllib.error import HTTPError, URLError
from urllib.request import urlopen


UPSTREAM_METRICS_URL = getenv("UPSTREAM_METRICS_URL", "http://backend:3210/metrics")
LISTEN_HOST = getenv("LISTEN_HOST", "0.0.0.0")
LISTEN_PORT = int(getenv("LISTEN_PORT", "9464"))


def filter_metrics(text: str) -> str:
    lines = []
    for line in text.splitlines():
        if line.startswith("# TYPE ") and line.endswith(" vmhistogram"):
            continue
        lines.append(line)
    return "\n".join(lines) + "\n"


class Handler(BaseHTTPRequestHandler):
    def do_GET(self) -> None:
        if self.path == "/health":
            self.send_response(200)
            self.send_header("Content-Type", "text/plain; charset=utf-8")
            self.end_headers()
            self.wfile.write(b"ok\n")
            return

        if self.path != "/metrics":
            self.send_response(404)
            self.end_headers()
            return

        try:
            with urlopen(UPSTREAM_METRICS_URL, timeout=10) as response:
                body = response.read().decode("utf-8", errors="replace")
        except HTTPError as err:
            self.send_response(err.code)
            self.end_headers()
            self.wfile.write(str(err).encode("utf-8"))
            return
        except URLError as err:
            self.send_response(502)
            self.end_headers()
            self.wfile.write(str(err).encode("utf-8"))
            return

        filtered = filter_metrics(body).encode("utf-8")
        self.send_response(200)
        self.send_header("Content-Type", "text/plain; version=0.0.4; charset=utf-8")
        self.send_header("Content-Length", str(len(filtered)))
        self.end_headers()
        self.wfile.write(filtered)

    def log_message(self, format: str, *args) -> None:
        return


if __name__ == "__main__":
    server = ThreadingHTTPServer((LISTEN_HOST, LISTEN_PORT), Handler)
    server.serve_forever()
