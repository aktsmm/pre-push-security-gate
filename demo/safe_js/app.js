const http = require("http");

const escapeHtml = (value) =>
  String(value)
    .replaceAll("&", "&amp;")
    .replaceAll("<", "&lt;")
    .replaceAll(">", "&gt;")
    .replaceAll('"', "&quot;")
    .replaceAll("'", "&#39;");

const server = http.createServer((req, res) => {
  const url = new URL(req.url, "http://localhost");
  const name = escapeHtml(url.searchParams.get("name") || "guest");

  res.writeHead(200, { "Content-Type": "text/html; charset=utf-8" });
  res.end(`<h1>Hello ${name}</h1>`);
});

server.listen(3100, () => {
  console.log("Safe demo app listening on port 3100");
});