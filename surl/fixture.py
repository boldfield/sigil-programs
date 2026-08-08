#!/usr/bin/env python3
"""Local HTTP fixture server for testing."""
import http.server
import socketserver
import sys
import os
import signal
import threading

class QuietHandler(http.server.SimpleHTTPRequestHandler):
    # Real HTTP/1.1 servers keep the connection open for reuse rather than
    # closing after every response; this is the persistent-connection path
    # surl must handle without hanging (see
    # docs/fixes/surl-http11-keepalive-hang.md). Overridable via the
    # optional second CLI arg — the oracle also starts an HTTP/1.0 instance
    # to keep exercising the legitimate close-delimited fallback.
    protocol_version = "HTTP/1.1"

    def log_message(self, format, *args):
        pass  # suppress logs

    def do_GET(self):
        if self.path == "/chunked":
            self.send_response(200)
            self.send_header("Content-type", "text/plain")
            self.send_header("Transfer-Encoding", "chunked")
            self.end_headers()
            for part in (b"hello ", b"chunked ", b"world"):
                self.wfile.write(b"%x\r\n%s\r\n" % (len(part), part))
            self.wfile.write(b"0\r\n\r\n")
        elif self.path == "/chunked-lower":
            # Non-canonical header casing on the framing header itself:
            # field names are case-insensitive (RFC 9110), so surl must
            # still detect chunked framing and read to the terminating
            # zero-length chunk, not hang. send_header writes the name
            # verbatim.
            self.send_response(200)
            self.send_header("Content-type", "text/plain")
            self.send_header("transfer-encoding", "chunked")
            self.end_headers()
            for part in (b"hello ", b"chunked ", b"world"):
                self.wfile.write(b"%x\r\n%s\r\n" % (len(part), part))
            self.wfile.write(b"0\r\n\r\n")
        elif self.path == "/length-lower":
            # Non-canonical header casing on Content-Length: surl must
            # still detect the framing and read exactly that many bytes,
            # not hang waiting for connection close.
            body = b"lowercase content-length body"
            self.send_response(200)
            self.send_header("Content-type", "text/plain")
            self.send_header("content-length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
        elif self.path == "/close-delim":
            # No Content-Length and not chunked, so the only way to know
            # the body is complete is the connection closing. Force the
            # close even under HTTP/1.1 keep-alive so this endpoint always
            # exercises that fallback, regardless of which server instance
            # serves it.
            body = b"close-delimited body, no content-length"
            self.send_response(200)
            self.send_header("Content-type", "text/plain")
            self.end_headers()
            self.wfile.write(body)
            self.close_connection = True
        elif self.path == "/headers":
            headers_str = ""
            for key, value in self.headers.items():
                headers_str += f"{key}: {value}\n"

            body = headers_str.encode()
            self.send_response(200)
            self.send_header("Content-type", "text/plain")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
        elif self.path == "/cookies":
            body = b"cookie response"
            self.send_response(200)
            self.send_header("Content-type", "text/plain")
            self.send_header("Set-Cookie", "sessionid=abc123")
            self.send_header("Set-Cookie", "tracking=xyz789")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
        elif self.path == "/cookies-lower":
            # Non-canonical header casing: field names are case-insensitive
            # (RFC 9110), so surl must save this cookie too. send_header
            # writes the name verbatim.
            body = b"cookie response"
            self.send_response(200)
            self.send_header("Content-type", "text/plain")
            self.send_header("set-cookie", "lowered=case42")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
        elif self.path == "/a":
            # Redirect /a to /b with 302 status
            self.send_response(302)
            self.send_header("Location", "/b")
            self.send_header("Content-Length", "0")
            self.end_headers()
        elif self.path == "/b":
            # Redirect target: return content
            body = b"redirect target"
            self.send_response(200)
            self.send_header("Content-type", "text/plain")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
        else:
            super().do_GET()

    def do_POST(self):
        # Drain any request body first so the socket is left clean.
        length = int(self.headers.get("Content-Length", 0) or 0)
        body = self.rfile.read(length) if length > 0 else b""

        if self.path == "/echo":
            # Echo the received request body back verbatim.
            self.send_response(200)
            self.send_header("Content-type", "text/plain")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
        else:
            # No POST handler for other paths — 501, matching curl's view.
            self.send_response(501)
            self.send_header("Content-Length", "0")
            self.end_headers()

def serve_dir(directory, protocol_version="HTTP/1.1"):
    """Serve a directory over HTTP on a free port. Print port to stdout, stop on SIGTERM."""
    os.chdir(directory)
    QuietHandler.protocol_version = protocol_version

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
        print("Usage: fixture.py <directory> [http_version]", file=sys.stderr)
        sys.exit(1)

    directory = sys.argv[1]
    if not os.path.isdir(directory):
        print(f"Error: {directory} is not a directory", file=sys.stderr)
        sys.exit(1)

    protocol_version = sys.argv[2] if len(sys.argv) > 2 else "HTTP/1.1"
    serve_dir(directory, protocol_version)
