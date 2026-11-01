# SPDX-License-Identifier: MIT
#
# A stand-in for the Hex API, for the publish check. It accepts the two
# requests `mix-purifier publish` makes, saves each body under the directory
# given as the first argument, and writes the port it listens on to
# `<dir>/port`:
#
#   POST /packages/<name>/releases          -> <dir>/release.tar
#   POST /packages/<name>/releases/<v>/docs -> <dir>/docs.tar.gz
#
# It also saves the authorization header of the release request to
# <dir>/authorization.
import http.server
import pathlib
import re
import sys

out = pathlib.Path(sys.argv[1])


class Handler(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def do_POST(self):
        body = self.rfile.read(int(self.headers["content-length"]))
        path = self.path.split("?")[0]
        if re.fullmatch(r"/packages/[^/]+/releases", path):
            (out / "release.tar").write_bytes(body)
            (out / "authorization").write_text(self.headers.get("authorization", ""))
        elif re.fullmatch(r"/packages/[^/]+/releases/[^/]+/docs", path):
            (out / "docs.tar.gz").write_bytes(body)
        else:
            self.send_response(404)
            self.send_header("content-length", "0")
            self.end_headers()
            return
        reply = b"{}"
        self.send_response(201)
        self.send_header("content-type", "application/json")
        self.send_header("content-length", str(len(reply)))
        self.end_headers()
        self.wfile.write(reply)


server = http.server.HTTPServer(("127.0.0.1", 0), Handler)
(out / "port").write_text(str(server.server_address[1]))
server.serve_forever()
