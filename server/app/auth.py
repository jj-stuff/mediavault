"""Shared-password session auth.

The iOS client signs in through a web page rendered in a WKWebView, then copies the
resulting cookie into HTTPURLSession's shared storage so API calls and AVPlayer's own
range requests are both authenticated. That means the session must live in a plain
signed cookie — no bearer tokens, no custom headers.
"""

from __future__ import annotations

import secrets
import threading
import time
from collections import defaultdict

from fastapi import APIRouter, Depends, Form, HTTPException, Request, status
from fastapi.responses import HTMLResponse, RedirectResponse

from .config import Settings

_SESSION_KEY = "authenticated"


class LoginThrottle:
    """Per-client failed-login limiter.

    A shared password is only as strong as the number of guesses an attacker gets,
    and this server is likely to be reachable from the internet. Held on app.state
    rather than in a module global so each app instance owns its own counters.
    """

    def __init__(self, max_attempts: int = 8, window_seconds: int = 300) -> None:
        self._max_attempts = max_attempts
        self._window = window_seconds
        self._lock = threading.Lock()
        self._attempts: dict[str, list[float]] = defaultdict(list)

    def _prune(self, key: str) -> list[float]:
        now = time.monotonic()
        recent = [t for t in self._attempts[key] if now - t < self._window]
        self._attempts[key] = recent
        return recent

    def is_throttled(self, key: str) -> bool:
        with self._lock:
            return len(self._prune(key)) >= self._max_attempts

    def record_failure(self, key: str) -> None:
        with self._lock:
            self._prune(key).append(time.monotonic())

    def clear(self, key: str) -> None:
        with self._lock:
            self._attempts.pop(key, None)


def _client_key(request: Request) -> str:
    return request.client.host if request.client else "unknown"


def _throttle(request: Request) -> LoginThrottle:
    return request.app.state.login_throttle


def is_authenticated(request: Request) -> bool:
    return bool(request.session.get(_SESSION_KEY))


def require_auth(request: Request) -> None:
    """FastAPI dependency guarding every media and metadata route."""
    if not is_authenticated(request):
        raise HTTPException(
            status_code=status.HTTP_401_UNAUTHORIZED, detail="Not signed in"
        )


def _settings(request: Request) -> Settings:
    return request.app.state.settings


def _login_page(*, signed_in: bool, error: str | None = None) -> str:
    if signed_in:
        body = """
        <p class="ok">Signed in.</p>
        <p class="hint">Tap <strong>Done</strong> in the top right to return to the app.</p>
        <form method="post" action="/logout"><button type="submit">Sign out</button></form>
        """
    else:
        error_html = f'<p class="error">{error}</p>' if error else ""
        body = f"""
        {error_html}
        <form method="post" action="/login">
            <input type="password" name="password" placeholder="Password"
                   autocomplete="current-password" autofocus required>
            <button type="submit">Sign In</button>
        </form>
        """

    return f"""<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover">
<title>MediaVault</title>
<style>
  :root {{ color-scheme: light dark; }}
  * {{ box-sizing: border-box; }}
  body {{
    margin: 0; min-height: 100vh; display: flex; align-items: center;
    justify-content: center; padding: 24px;
    font: 16px/1.5 -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif;
    background: Canvas; color: CanvasText;
  }}
  .card {{ width: 100%; max-width: 320px; text-align: center; }}
  h1 {{ font-size: 22px; margin: 0 0 4px; }}
  .sub {{ color: color-mix(in srgb, CanvasText 55%, transparent); margin: 0 0 24px; font-size: 14px; }}
  input, button {{ width: 100%; padding: 14px; font-size: 16px; border-radius: 12px; }}
  input {{ border: 1px solid color-mix(in srgb, CanvasText 20%, transparent);
           background: color-mix(in srgb, CanvasText 5%, transparent); color: CanvasText; }}
  button {{ margin-top: 12px; border: 0; background: #7c3aed; color: #fff; font-weight: 600; }}
  .error {{ color: #dc2626; font-size: 14px; }}
  .ok {{ color: #16a34a; font-weight: 600; }}
  .hint {{ font-size: 14px; color: color-mix(in srgb, CanvasText 55%, transparent); }}
</style>
</head>
<body>
  <div class="card">
    <h1>MediaVault</h1>
    <p class="sub">Sign in to browse your library.</p>
    {body}
  </div>
</body>
</html>"""


router = APIRouter()


@router.get("/", response_class=HTMLResponse)
def login_form(request: Request) -> HTMLResponse:
    return HTMLResponse(_login_page(signed_in=is_authenticated(request)))


@router.post("/login", response_class=HTMLResponse)
def login(request: Request, password: str = Form(...)) -> HTMLResponse:
    key = _client_key(request)
    throttle = _throttle(request)
    if throttle.is_throttled(key):
        return HTMLResponse(
            _login_page(signed_in=False, error="Too many attempts. Try again shortly."),
            status_code=status.HTTP_429_TOO_MANY_REQUESTS,
        )

    # Constant-time comparison so response timing does not leak the password.
    if not secrets.compare_digest(password, _settings(request).password):
        throttle.record_failure(key)
        return HTMLResponse(
            _login_page(signed_in=False, error="Incorrect password."),
            status_code=status.HTTP_401_UNAUTHORIZED,
        )

    throttle.clear(key)
    request.session[_SESSION_KEY] = True
    return RedirectResponse("/", status_code=status.HTTP_303_SEE_OTHER)


@router.post("/logout")
def logout(request: Request) -> RedirectResponse:
    request.session.clear()
    return RedirectResponse("/", status_code=status.HTTP_303_SEE_OTHER)


@router.get("/api/auth/check", dependencies=[Depends(require_auth)])
def auth_check() -> dict[str, bool]:
    """200 when the session cookie is valid, 401 otherwise — the client only reads
    the status code."""
    return {"authenticated": True}
