"""Bound incoming bodies before multipart parsers can fill the local disk."""
from starlette.exceptions import HTTPException
from starlette.responses import JSONResponse


class ApiResponseHeaders:
    """Keep account, classroom and assessment responses out of shared caches."""
    def __init__(self, app):
        self.app = app

    async def __call__(self, scope, receive, send):
        if scope["type"] != "http":
            return await self.app(scope, receive, send)

        async def protected_send(message):
            if message["type"] == "http.response.start":
                headers = list(message.get("headers", []))
                private = scope.get("path", "").startswith(("/auth/", "/teacher/", "/student/", "/problems", "/recordings/", "/attempts/"))
                if private:
                    headers = [(k, v) for k, v in headers if k.lower() != b"cache-control"]
                    headers.append((b"cache-control", b"no-store"))
                headers.append((b"x-content-type-options", b"nosniff"))
                message = {**message, "headers": headers}
            await send(message)

        await self.app(scope, receive, protected_send)


class RequestSizeLimit:
    def __init__(self, app, max_bytes=22 * 1024 * 1024):
        self.app, self.max_bytes = app, max_bytes

    async def __call__(self, scope, receive, send):
        if scope["type"] != "http":
            return await self.app(scope, receive, send)
        lengths = [value for key, value in scope.get("headers", []) if key.lower() == b"content-length"]
        if lengths:
            try:
                length = int(lengths[0])
                if len(lengths) != 1 or length < 0:
                    raise ValueError
            except ValueError:
                return await JSONResponse({"detail": "Invalid Content-Length"}, status_code=400)(scope, receive, send)
            if length > self.max_bytes:
                return await JSONResponse({"detail": "Request is too large; maximum upload is 20 MiB"}, status_code=413)(scope, receive, send)
        seen = 0

        async def bounded_receive():
            nonlocal seen
            message = await receive()
            if message["type"] == "http.request":
                seen += len(message.get("body", b""))
                if seen > self.max_bytes:
                    raise HTTPException(413, "Request is too large; maximum upload is 20 MiB")
            return message

        await self.app(scope, bounded_receive, send)
