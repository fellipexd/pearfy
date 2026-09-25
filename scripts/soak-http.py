#!/usr/bin/env python3
import argparse
import http.client
import json
import signal
import subprocess
import threading
import time
from urllib.error import URLError
from urllib.parse import urlsplit
from urllib.request import urlopen


def main() -> int:
    parser = argparse.ArgumentParser(description="Soak an HTTP executable and terminate it under load")
    parser.add_argument("--target", required=True, help="HTTP server executable to launch")
    parser.add_argument("--url", default="http://127.0.0.1:8080/hello/pear")
    parser.add_argument("--expected-body", default="Hello, pear!")
    parser.add_argument("--duration-seconds", type=float, default=60)
    parser.add_argument("--workers", type=int, default=16)
    arguments = parser.parse_args()

    if arguments.duration_seconds <= 0 or arguments.workers <= 0:
        parser.error("duration and workers must be positive")
    url = urlsplit(arguments.url)
    if url.scheme != "http" or not url.hostname:
        parser.error("url must be an http URL with a host")
    port = url.port or 80
    path = url.path or "/"
    if url.query:
        path += "?" + url.query
    expected_body = arguments.expected_body.encode("utf-8")

    server = subprocess.Popen(
        [arguments.target],
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
    )
    ready = False
    for _ in range(100):
        if server.poll() is not None:
            break
        try:
            with urlopen(arguments.url, timeout=1) as response:
                ready = response.status == 200 and response.read() == expected_body
            if ready:
                break
        except (OSError, URLError):
            time.sleep(0.05)
    if not ready:
        server.terminate()
        server.wait(timeout=5)
        raise RuntimeError("HTTP server did not become ready with the expected response")

    stopping = threading.Event()
    lock = threading.Lock()
    counts = {"ok": 0, "unexpected": 0, "errors": 0}

    def worker() -> None:
        connection = http.client.HTTPConnection(url.hostname, port, timeout=2)
        try:
            while not stopping.is_set():
                try:
                    connection.request("GET", path)
                    response = connection.getresponse()
                    body = response.read()
                    with lock:
                        if response.status == 200 and body == expected_body:
                            counts["ok"] += 1
                        else:
                            counts["unexpected"] += 1
                except OSError:
                    connection.close()
                    connection = http.client.HTTPConnection(url.hostname, port, timeout=2)
                    with lock:
                        counts["errors"] += 1
                    stopping.wait(0.01)
        finally:
            connection.close()

    workers = [threading.Thread(target=worker) for _ in range(arguments.workers)]
    for thread in workers:
        thread.start()

    started = time.monotonic()
    deadline = started + arguments.duration_seconds
    rss_samples = []
    while time.monotonic() < deadline:
        try:
            rss = subprocess.check_output(
                ["ps", "-o", "rss=", "-p", str(server.pid)],
                text=True,
            ).strip()
            if rss.isdigit():
                rss_samples.append(int(rss))
        except (OSError, subprocess.CalledProcessError):
            pass
        time.sleep(min(1, max(0, deadline - time.monotonic())))

    with lock:
        pre_shutdown = dict(counts)
    server.send_signal(signal.SIGTERM)
    time.sleep(0.5)
    stopping.set()
    for thread in workers:
        thread.join(timeout=3)
    try:
        exit_status = server.wait(timeout=10)
    except subprocess.TimeoutExpired:
        server.kill()
        exit_status = server.wait(timeout=5)

    result = {
        "duration_s": round(time.monotonic() - started, 2),
        "workers": arguments.workers,
        "pre_shutdown": pre_shutdown,
        "final": counts,
        "peak_rss_kb": max(rss_samples, default=0),
        "last_rss_kb": rss_samples[-1] if rss_samples else 0,
        "server_exit": exit_status,
    }
    print(json.dumps(result, sort_keys=True))

    if pre_shutdown["ok"] == 0 or pre_shutdown["unexpected"] or pre_shutdown["errors"] or exit_status != 0:
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
