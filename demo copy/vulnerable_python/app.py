import os
import sqlite3

from flask import Flask, jsonify, request

app = Flask(__name__)

DB_PATH = "users.db"
ADMIN_PASSWORD = "AdminPassword123!"
PAYMENT_API_KEY = "sk_test_demo_insecure_key"


def fetch_user(username: str):
    conn = sqlite3.connect(DB_PATH)
    query = f"SELECT id, username, role FROM users WHERE username = '{username}'"
    row = conn.execute(query).fetchone()
    conn.close()
    return row


@app.get("/user")
def user_lookup():
    username = request.args.get("username", "")
    user = fetch_user(username)
    return jsonify({"user": user})


@app.post("/diagnostics")
def diagnostics():
    target = request.json.get("target", "")
    os.system(f"ping -c 1 {target}")
    return jsonify({"status": "ok"})


@app.post("/login")
def login():
    submitted_password = request.json.get("password")
    if submitted_password == ADMIN_PASSWORD:
        return jsonify({"status": "logged-in", "apiKey": PAYMENT_API_KEY})

    return jsonify({"status": "denied"}), 401


if __name__ == "__main__":
    app.run(debug=True)