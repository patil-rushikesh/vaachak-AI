"""Explicit browser origins for separately hosted clients. Native clients need no CORS."""

import os
from urllib.parse import urlsplit

from fastapi.middleware.cors import CORSMiddleware


def allowed_origins(value: str, production: bool = False) -> list[str]:
    origins = []
    for entry in value.split(","):
        origin = entry.strip().rstrip("/")
        if not origin:
            continue
        try:
            url = urlsplit(origin)
            port = url.port
            valid = (
                url.scheme in ({"https"} if production else {"http", "https"})
                and url.hostname
                and "*" not in origin
                and not url.username
                and not url.password
                and not url.path
                and not url.query
                and not url.fragment
                and (port is None or port > 0)
            )
        except ValueError:
            valid = False
        if not valid:
            raise ValueError("VAACHAK_CORS_ORIGINS must contain exact web origins (HTTPS in production), without paths or wildcards")
        if origin not in origins:
            origins.append(origin)
    return origins


def install(app):
    origins = allowed_origins(
        os.getenv("VAACHAK_CORS_ORIGINS", ""),
        os.getenv("VAACHAK_ENV") == "production",
    )
    if origins:
        # Installed outside the request/error middleware so error responses also
        # reach the browser with their request ID and structured error message.
        app.add_middleware(
            CORSMiddleware,
            allow_origins=origins,
            allow_credentials=False,  # Bearer tokens; no cross-site cookies.
            allow_methods=["GET", "POST", "PUT", "PATCH", "DELETE", "OPTIONS"],
            allow_headers=["Authorization", "Content-Type", "X-Request-ID", "Range"],
            expose_headers=["X-Request-ID", "Retry-After", "Content-Disposition"],
            max_age=600,
        )
