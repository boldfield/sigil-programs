#!/usr/bin/env python3
"""Local HTTP fixture server for testing."""
import http.server
import socketserver
import sys
import os
import signal
import threading

class QuietHandler(http.server.SimpleHTTPRequestHandler):
    def log_message(self, format, *args):
        pass  # suppress logs

    def do_GET(self):
        if self.path == "/headers":
            headers_str = ""
            for key, value in self.headers.items():
                headers_str += f"{key}: {value}\n"

            body = headers_str.encode()
            self.send_response(200)
            self.send_header("Content-type", "text/plain")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
        else:
            super().do_GET()

def serve_dir(directory):
    """Serve a directory over HTTP on a free port. Print port to stdout, stop on SIGTERM."""
    os.chdir(directory)

    # Bind to port 0 to get a free port automatically
    with socketserver.TCPServer(("127.0.0.1", 0), QuietHandler) as httpd:
        port = httpd.server_address[1]
        print(port, flush=True)
        sys.stdout.flush()

        # Handle SIGTERM gracefully
        def shutdown_handler(signum, frame):
            sys.exit(0)

        signal.signal(signal.SIGTERM, shutdown_handler)
        signal.signal(signal.SIGINT, shutdown_handler)

        try:
            httpd.serve_forever()
        except (KeyboardInterrupt, SystemExit):
            pass

if __name__ == "__main__":
    if len(sys.argv) < 2:
        print("Usage: fixture.py <directory>", file=sys.stderr)
        sys.exit(1)

    directory = sys.argv[1]
    if not os.path.isdir(directory):
        print(f"Error: {directory} is not a directory", file=sys.stderr)
        sys.exit(1)

    serve_dir(directory)
