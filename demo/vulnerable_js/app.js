const express = require("express");

const app = express();
app.use(express.json());

const JWT_SECRET = "demo-hardcoded-jwt-secret";
const ADMIN_PASSWORD = "password123";

app.get("/profile", (req, res) => {
  const name = req.query.name || "guest";
  res.send(`<h1>Hello ${name}</h1>`);
});

app.post("/proxy", async (req, res) => {
  const url = req.body.url;
  const response = await fetch(url);
  const text = await response.text();
  res.json({ preview: text.slice(0, 200) });
});

app.post("/admin/login", (req, res) => {
  if (req.body.password === ADMIN_PASSWORD) {
    res.json({ token: JWT_SECRET, role: "admin" });
    return;
  }

  res.status(401).json({ error: "invalid credentials" });
});

app.listen(3000, () => {
  console.log("Vulnerable demo app listening on port 3000");
});