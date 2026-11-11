"""OpenAI-compatible `POST /v1/audio/transcriptions` over faster-whisper,
plus a small web page for transcribing a file from a browser.

The API serves the subset Mila sends (`RemoteWhisperEngine.multipartBody`):
a multipart `file`, `model` (ignored: one model is loaded), `language` and
`response_format` (`json`, `verbose_json` or `text`), behind a bearer key.

The web page (`/`) asks for a username and password (HTTP Basic). Users are
`{"name": "<hash>"}` with hashes from `python api.py hash-password`.

`modal_app.py` deploys it on a GPU. Run it locally on the CPU, no auth:

    python server/modal/api.py
"""
import hashlib
import hmac
import os
import secrets
from pathlib import Path

from fastapi import Depends, FastAPI, File, Form, Header, HTTPException, UploadFile
from fastapi.responses import HTMLResponse, PlainTextResponse
from fastapi.security import HTTPBasic, HTTPBasicCredentials

MODEL_ID = "ivrit-ai/whisper-large-v3-turbo-ct2"
PAGE = Path(__file__).with_name("web.html")


def hash_password(password: str) -> str:
    salt = secrets.token_bytes(16)
    digest = hashlib.scrypt(password.encode(), salt=salt, n=2**14, r=8, p=1)
    return f"scrypt${salt.hex()}${digest.hex()}"


def check_password(password: str, stored: str) -> bool:
    try:
        _, salt, digest = stored.split("$")
        actual = hashlib.scrypt(password.encode(), salt=bytes.fromhex(salt), n=2**14, r=8, p=1)
    except ValueError:
        return False
    return hmac.compare_digest(actual.hex(), digest)


# Checked for unknown usernames too, so a wrong name takes as long as a
# wrong password.
_DUMMY_HASH = hash_password(secrets.token_hex(16))


def build_app(model, api_key: str | None, users: dict[str, str] | None = None) -> FastAPI:
    """`api_key` None turns API auth off; only the local run passes None.
    `users` None or empty: nobody can sign in to the web page."""
    app = FastAPI(docs_url=None, redoc_url=None, openapi_url=None)
    basic = HTTPBasic(realm="Mila")

    def web_user(creds: HTTPBasicCredentials = Depends(basic)) -> str:
        stored = (users or {}).get(creds.username)
        if not check_password(creds.password, stored or _DUMMY_HASH) or stored is None:
            raise HTTPException(401, "Wrong username or password.", headers={"WWW-Authenticate": 'Basic realm="Mila"'})
        return creds.username

    def transcribe(file: UploadFile, language: str | None) -> dict:
        # vad_filter: skip long silences, where whisper hallucinates.
        segments, info = model.transcribe(file.file, language=language or None, vad_filter=True)
        segs = [{"id": i, "start": s.start, "end": s.end, "text": s.text} for i, s in enumerate(segments)]
        return {"task": "transcribe", "language": info.language, "duration": info.duration,
                "text": "".join(s["text"] for s in segs).strip(), "segments": segs}

    @app.get("/health")
    def health():
        return {"status": "ok"}

    # The endpoints are sync on purpose: FastAPI runs them on a worker
    # thread, so a long transcription doesn't block the event loop.
    @app.post("/v1/audio/transcriptions")
    def transcriptions(
        file: UploadFile = File(...),
        language: str | None = Form(None),
        response_format: str = Form("json"),
        authorization: str | None = Header(None),
    ):
        if api_key is not None and not hmac.compare_digest(
            (authorization or "").encode(), f"Bearer {api_key}".encode()
        ):
            raise HTTPException(401, "Missing or wrong API key.")
        result = transcribe(file, language)
        if response_format == "text":
            return PlainTextResponse(result["text"])
        if response_format == "verbose_json":
            return result
        return {"text": result["text"]}

    @app.get("/", response_class=HTMLResponse)
    def page(user: str = Depends(web_user)):
        return PAGE.read_text(encoding="utf-8")

    @app.post("/web/transcribe")
    def web_transcribe(file: UploadFile = File(...), language: str = Form("he"),
                       user: str = Depends(web_user)):
        return transcribe(file, None if language == "auto" else language)

    return app


if __name__ == "__main__":
    import json
    import sys

    if sys.argv[1:] == ["hash-password"]:
        import getpass

        print(hash_password(getpass.getpass("Password: ")))
        sys.exit()

    import uvicorn
    from faster_whisper import WhisperModel

    model = WhisperModel(MODEL_ID, device="cpu", compute_type="int8")
    users = json.loads(os.environ.get("MILA_WEB_USERS", "{}"))
    uvicorn.run(build_app(model, os.environ.get("MILA_API_KEY"), users), host="127.0.0.1", port=8000)
