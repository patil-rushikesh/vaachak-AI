"""One redacted completion event per request, including routing and validation errors."""

import json
import logging
import os
import sqlite3
import time
import uuid
from datetime import datetime, timezone

from fastapi.exceptions import RequestValidationError
from fastapi.responses import JSONResponse
from starlette.exceptions import HTTPException

log = logging.getLogger("vaachak.requests")
log.setLevel(logging.INFO)
if not log.handlers:
    handler = logging.StreamHandler()
    handler.setFormatter(logging.Formatter("%(message)s"))
    log.addHandler(handler)
log.propagate = False
CODES = {
    400: "bad_request",
    401: "authentication_required",
    403: "forbidden",
    404: "not_found",
    405: "method_not_allowed",
    409: "conflict",
    413: "payload_too_large",
    415: "unsupported_media",
    422: "validation_error",
    429: "rate_limited",
    500: "internal_error",
    502: "provider_error",
    503: "service_unavailable",
}


def error_response(request, status, detail, code=None, headers=None):
    code = code or CODES.get(status, "request_error")
    request.scope["error_code"] = code
    return JSONResponse(
        {
            "detail": detail,
            "error": {
                "code": code,
                "message": detail,
                "request_id": request.scope.get("request_id", ""),
            },
        },
        status_code=status,
        headers=headers,
    )


def install(app):
    @app.exception_handler(HTTPException)
    async def http_error(request, exc):
        if request.scope.get("body_too_large"):
            return error_response(request, 413, "Request body is too large.")
        if isinstance(exc.detail, dict):
            return error_response(
                request,
                exc.status_code,
                exc.detail.get("message", "Request failed."),
                exc.detail.get("code"),
                exc.headers,
            )
        return error_response(request, exc.status_code, exc.detail, headers=exc.headers)

    @app.exception_handler(RequestValidationError)
    async def validation_error(request, exc):
        # Pydantic errors may contain passwords, tokens or transcripts in input/context.
        errors = [
            {"loc": list(e["loc"]), "type": e["type"], "msg": "Invalid value."}
            for e in exc.errors()
        ]
        response = error_response(request, 422, "Request validation failed.")
        body = json.loads(response.body)
        body["fields"] = errors
        return JSONResponse(body, status_code=422)

    @app.exception_handler(sqlite3.IntegrityError)
    async def integrity_error(request, exc):
        return error_response(
            request, 409, "This operation conflicts with existing data."
        )

    @app.exception_handler(sqlite3.OperationalError)
    async def database_error(request, exc):
        return error_response(
            request,
            503,
            "Storage is temporarily unavailable. Retry later.",
            headers={"Retry-After": "2"},
        )

    app.add_middleware(RequestLogMiddleware)


class RequestLogMiddleware:
    def __init__(self, app):
        self.app = app

    async def __call__(self, scope, receive, send):
        if scope["type"] != "http":
            return await self.app(scope, receive, send)
        # Generate our own ID: untrusted caller values never enter logs.
        request_id = uuid.uuid4().hex
        scope["request_id"] = request_id
        started = time.monotonic()
        status, sent = 500, False
        size = 0

        async def wrapped_send(message):
            nonlocal status, sent, size
            if message["type"] == "http.response.start":
                status, sent = message["status"], True
                message["headers"] = list(message["headers"]) + [
                    (b"x-request-id", request_id.encode()),
                    (b"cache-control", b"no-store"),
                    (b"x-content-type-options", b"nosniff"),
                ]
            if message["type"] == "http.response.body":
                size += len(message.get("body", b""))
            await send(message)

        try:
            from starlette.requests import Request

            headers = dict(scope.get("headers", []))
            try:
                length = int(headers.get(b"content-length", b"0"))
            except ValueError:
                length = -1
            if length < 0 or length > 22 * 1024 * 1024:
                await error_response(Request(scope), 413, "Request body is too large.")(
                    scope, receive, wrapped_send
                )
                return
            # Limits are persisted and shared with endpoint limits. Never log client addresses.
            if scope.get("path") in (
                "/api/auth/register",
                "/api/auth/login",
                "/api/auth/reset-password",
            ):
                import hashlib
                import db
                import evidence
                from starlette.concurrency import run_in_threadpool

                bucket = hashlib.sha256(
                    str(scope.get("client", ("unknown",))[0]).encode()
                ).hexdigest()

                def check_limit():
                    with db.connect() as conn:
                        evidence.limit(
                            conn,
                            "auth:" + bucket,
                            int(os.getenv("VAACHAK_AUTH_PER_MINUTE", "60")),
                        )

                try:
                    await run_in_threadpool(check_limit)
                except HTTPException as exc:
                    await error_response(
                        Request(scope), exc.status_code, exc.detail, headers=exc.headers
                    )(scope, receive, wrapped_send)
                    return
            received = 0

            async def limited_receive():
                nonlocal received
                message = await receive()
                received += len(message.get("body", b""))
                if received > 22 * 1024 * 1024:
                    scope["body_too_large"] = True
                    raise HTTPException(413, "Request body is too large.")
                return message

            await self.app(scope, limited_receive, wrapped_send)
        except Exception as exc:
            scope["error_code"] = "internal_error"
            scope["exception_type"] = type(exc).__name__
            if not sent:
                response = JSONResponse(
                    {
                        "detail": "An unexpected error occurred.",
                        "error": {
                            "code": "internal_error",
                            "message": "An unexpected error occurred.",
                            "request_id": request_id,
                        },
                    },
                    status_code=500,
                )
                await response(scope, receive, wrapped_send)
            else:
                raise
        finally:
            route = scope.get("route")
            # Route templates, never raw URLs, query strings, headers or bodies.
            log.info(
                json.dumps(
                    {
                        "timestamp": datetime.now(timezone.utc).isoformat(),
                        "event": "http_request",
                        "request_id": request_id,
                        "method": scope["method"],
                        "route": getattr(route, "path", "unmatched"),
                        "status": status,
                        "duration_ms": round((time.monotonic() - started) * 1000, 2),
                        "response_bytes": size,
                        "error_code": scope.get("error_code"),
                        "exception_type": scope.get("exception_type"),
                    }
                )
            )
