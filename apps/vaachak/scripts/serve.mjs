import http from "node:http";
import fs from "node:fs";
import path from "node:path";
const root = path.resolve("dist"),
  port = Number(process.env.PORT || 8090);
const types = {
  ".html": "text/html",
  ".js": "application/javascript",
  ".css": "text/css",
  ".json": "application/json",
  ".png": "image/png",
  ".ttf": "font/ttf",
  ".ico": "image/x-icon",
};
http
  .createServer((req, res) => {
    if (req.url.startsWith("/api/")) {
      const upstream = http.request(
        {
          hostname: "127.0.0.1",
          port: Number(process.env.API_PORT || 8000),
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
        res.writeHead(503, { "Content-Type": "application/json" });
        res.end(
          JSON.stringify({
            detail:
              "The local API is unavailable. Start the backend and try again.",
          }),
        );
      });
      req.pipe(upstream);
      return;
    }
    let file;
    try {
      file = path.resolve(
        root,
        "." + decodeURIComponent(req.url.split("?")[0]),
      );
    } catch {
      res.writeHead(400).end("Invalid URL");
      return;
    }
    if (!file.startsWith(root + path.sep) && file !== root) {
      res.writeHead(403).end();
      return;
    }
    const target =
      fs.existsSync(file) && fs.statSync(file).isFile()
        ? file
        : path.join(root, "index.html");
    res.setHeader(
      "Content-Type",
      types[path.extname(target)] || "application/octet-stream",
    );
    fs.createReadStream(target).pipe(res);
  })
  .listen(port, "127.0.0.1", () =>
    console.log(`Vaachak web: http://localhost:${port}`),
  );
