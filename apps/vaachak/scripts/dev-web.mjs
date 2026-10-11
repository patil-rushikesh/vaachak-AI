import http from "node:http";
import { spawn } from "node:child_process";
const child = spawn("npx", ["expo", "start", "--port", "8091"], {
  stdio: "inherit",
  env: process.env,
});
const server = http.createServer((req, res) => {
  const upstream = http.request(
    {
      hostname: "127.0.0.1",
      port: req.url.startsWith("/api/") ? 8000 : 8091,
      path: req.url,
      method: req.method,
      headers: req.headers,
    },
    (r) => {
      res.writeHead(r.statusCode, r.headers);
      r.pipe(res);
    },
  );
  upstream.on("error", () => {
    res.writeHead(503);
    res.end("Development server is starting. Refresh in a moment.");
  });
  req.pipe(upstream);
});
server.listen(8090, "127.0.0.1", () =>
  console.log("Vaachak web: http://localhost:8090 (API → localhost:8000)"),
);
server.on("upgrade", (req, socket, head) => {
  const r = http.request({
    hostname: "127.0.0.1",
    port: 8091,
    path: req.url,
    headers: req.headers,
  });
  r.on("upgrade", (res, upstream, rest) => {
    socket.write(
      "HTTP/1.1 101 Switching Protocols\r\n" +
        Object.entries(res.headers)
          .map(([k, v]) => `${k}: ${v}`)
          .join("\r\n") +
        "\r\n\r\n",
    );
    socket.write(rest);
    upstream.write(head);
    socket.pipe(upstream).pipe(socket);
  });
  r.on("error", () => socket.destroy());
  r.end();
});
for (const signal of ["SIGINT", "SIGTERM"])
  process.on(signal, () => {
    child.kill(signal);
    server.close();
    process.exit();
  });
