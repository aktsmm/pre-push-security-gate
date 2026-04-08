# Demo Apps

This folder contains intentionally simple demo material for the pre-push security gate.

## vulnerable_python

- `app.py` contains SQL injection, command injection, hardcoded secrets, and debug mode.
- Use it to confirm that the hook blocks a push.

## vulnerable_js

- `app.js` contains XSS, SSRF, hardcoded credentials, and broken authentication behavior.
- Use it to confirm that the hook blocks a push.

## safe_js

- `app.js` escapes untrusted input and does not expose secrets.
- Use it to confirm that the hook can pass a small safe change when the diff only contains this app.