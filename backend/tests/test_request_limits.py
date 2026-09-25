from fastapi import FastAPI, Request
from fastapi.testclient import TestClient

from vaachak_backend.middleware import RequestSizeLimit


def client():
    app = FastAPI()
    app.add_middleware(RequestSizeLimit, max_bytes=16)

    @app.post("/")
    async def read(request: Request):
        return {"size": len(await request.body())}

    return TestClient(app)


def test_declared_body_size_limit():
    with client() as http:
        assert http.post("/", content=b"x" * 16).json() == {"size": 16}
        assert http.post("/", content=b"x" * 17).status_code == 413
        assert http.post("/", content=b"x", headers={"Content-Length": "-1"}).status_code == 400
        assert http.post("/", content=b"x", headers={"Content-Length": "nonsense"}).status_code == 400


def test_chunked_and_misdeclared_body_size_limit():
    with client() as http:
        assert http.post("/", content=iter([b"x" * 8, b"x" * 9])).status_code == 413
        assert http.post("/", content=b"x" * 17, headers={"Content-Length": "1"}).status_code == 413
