"""Mila's server: the transcription API the Mac and iPad apps use, and the
JSON API behind the web app (`web/`).

- `POST /v1/audio/transcriptions`: OpenAI-compatible, the subset Mila sends
  (`RemoteWhisperEngine.multipartBody`), behind the bearer `MILA_API_KEY`.
- `/api/*`: the web app. `POST /api/login` trades a username and password
  (scrypt hashes in `MILA_WEB_USERS`) for a signed token; every other route
  needs it as a bearer token, or as `?token=` for media, since `<audio>`
  can't send headers.

Transcription, storage and job start are injected, so on Modal this runs on
a CPU while whisper runs on a GPU (`modal_app.py`), and locally it runs on
its own with whisper on the CPU:

    python server/modal/api.py
"""
import base64
import hashlib
import hmac
import json
import os
import re
import secrets
import threading
import time
import uuid
from datetime import datetime, timezone
from pathlib import Path

from fastapi import Depends, FastAPI, File, Form, Header, HTTPException, Query, UploadFile
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import FileResponse, PlainTextResponse
from pydantic import BaseModel

MODEL_ID = "ivrit-ai/whisper-large-v3-turbo-ct2"
TOKEN_DAYS = 30
ID = re.compile(r"^[0-9a-f]{32}$")


# MARK: - Passwords and tokens

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


def make_token(user: str, secret: bytes, now: float | None = None) -> str:
    body = f"{user}:{int((now or time.time()) + TOKEN_DAYS * 86400)}".encode()
    sig = hmac.new(secret, body, hashlib.sha256).hexdigest()
    return base64.urlsafe_b64encode(body).decode().rstrip("=") + "." + sig


def read_token(token: str, secret: bytes, now: float | None = None) -> str | None:
    """The token's user, or None if it is forged, malformed or expired."""
    try:
        encoded, sig = token.split(".")
        body = base64.urlsafe_b64decode(encoded + "=" * (-len(encoded) % 4))
        user, expires = body.decode().rsplit(":", 1)
        expired = int(expires) < (now or time.time())
    except (ValueError, UnicodeDecodeError):
        return None
    expected = hmac.new(secret, body, hashlib.sha256).hexdigest()
    return user if hmac.compare_digest(sig, expected) and not expired else None


# MARK: - Transcription

def run_whisper(model, path: str, language: str | None, **options) -> dict:
    """One file through faster-whisper, as a `verbose_json` response."""
    # vad_filter: skip long silences, where whisper hallucinates.
    segments, info = model.transcribe(path, language=language or None, vad_filter=True, **options)
    segs = [{"id": i, "start": round(s.start, 2), "end": round(s.end, 2), "text": s.text}
            for i, s in enumerate(segments)]
    return {"task": "transcribe", "language": info.language, "duration": info.duration,
            "text": "".join(s["text"] for s in segs).strip(), "segments": segs}


def download_url(url: str, directory: Path) -> dict:
    """Fetch a page's media (YouTube, Vimeo, a direct file link…) with yt-dlp.
    Audio only: it's all whisper needs, and a fraction of the size."""
    import yt_dlp

    options = {"format": "bestaudio/best", "outtmpl": str(directory / "media.%(ext)s"),
               "noplaylist": True, "quiet": True, "no_warnings": True}
    # YouTube refuses datacenter IPs ("confirm you're not a bot") unless the
    # request carries a signed-in browser's cookies (Netscape format).
    cookies = directory / ".cookies.txt"
    if os.environ.get("YT_COOKIES"):
        cookies.write_text(os.environ["YT_COOKIES"])
        options["cookiefile"] = str(cookies)
    try:
        with yt_dlp.YoutubeDL(options) as ydl:
            info = ydl.extract_info(url, download=True)
            path = Path(ydl.prepare_filename(info))
    except Exception as error:
        if "not a bot" in str(error):
            raise RuntimeError("YouTube blocked the download from the server. Upload the file "
                               "instead, or add YouTube cookies (server/modal/README.md).") from error
        raise
    finally:
        cookies.unlink(missing_ok=True)
    return {"file": path.name, "title": info.get("title") or "", "duration": info.get("duration")}


# MARK: - Recordings

def now_iso() -> str:
    return datetime.now(timezone.utc).isoformat(timespec="seconds")


def record_key(user: str, rec_id: str) -> str:
    return f"rec:{user}:{rec_id}"


# Large fields, left out of the library listing.
HEAVY = ("segments", "text", "chat")


def process_recording(user: str, rec_id: str, *, store, media_root: Path, transcribe,
                      refresh=lambda: None, persist=lambda: None) -> None:
    """The job behind every new recording: download (for a link), then
    transcribe. Writes its progress into the record as it goes."""
    key = record_key(user, rec_id)

    def update(**fields):
        # ponytail: read-modify-write; an edit made in the same instant can
        # be lost. Fine for one person's library.
        record = store[key]
        record.update(fields)
        store[key] = record

    record = store[key]
    directory = media_root / user / rec_id
    try:
        if record.get("url"):
            update(status="downloading")
            directory.mkdir(parents=True, exist_ok=True)
            got = download_url(record["url"], directory)
            persist()
            update(media=got["file"], mediaType="audio", duration=got["duration"],
                   title=record["title"] or got["title"] or record["url"])
            record = store[key]
        update(status="transcribing")
        refresh()
        result = transcribe(f"{user}/{rec_id}/{record['media']}", record.get("language"))
        update(status="done", segments=result["segments"], text=result["text"],
               duration=record.get("duration") or result["duration"],
               detectedLanguage=result["language"])
    except Exception as error:  # surfaced to the user, then retried by hand
        update(status="error", error=str(error)[:500])


class Login(BaseModel):
    username: str
    password: str


class LinkIn(BaseModel):
    url: str
    language: str = "he"
    title: str = ""


class Patch(BaseModel):
    title: str | None = None
    analysis: dict | None = None
    chat: list | None = None


def build_app(*, api_key: str | None, users: dict[str, str], store, media_root: Path,
              transcribe, start_job, refresh=lambda: None, persist=lambda: None) -> FastAPI:
    """`transcribe(relative_path, language)` returns `run_whisper`'s dict;
    `start_job(user, id)` runs `process_recording` in the background.
    `api_key` None turns the app API's auth off (local run only)."""
    app = FastAPI(docs_url=None, redoc_url=None, openapi_url=None)
    # Auth is a bearer token, never a cookie, so any origin may call.
    app.add_middleware(CORSMiddleware, allow_origins=["*"], allow_methods=["*"],
                       allow_headers=["*"])
    session_secret = hmac.new((api_key or "local").encode(), b"web-session", hashlib.sha256).digest()

    def user_of(authorization: str | None = Header(None), token: str | None = Query(None)) -> str:
        raw = token or (authorization or "").removeprefix("Bearer ").strip()
        user = read_token(raw, session_secret) if raw else None
        if user is None or user not in users:
            raise HTTPException(401, "Sign in again.")
        return user

    def get_record(user: str, rec_id: str) -> dict:
        record = store.get(record_key(user, rec_id)) if ID.match(rec_id) else None
        if record is None:
            raise HTTPException(404, "No such recording.")
        return record

    def new_record(user: str, **fields) -> dict:
        record = {"id": uuid.uuid4().hex, "createdAt": now_iso(), "status": "queued",
                  "title": "", "language": "he", **fields}
        store[record_key(user, record["id"])] = record
        return record

    @app.get("/health")
    def health():
        return {"status": "ok"}

    # MARK: Apps

    # The endpoints are sync on purpose: FastAPI runs them on worker
    # threads, so a long transcription doesn't block the event loop.
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
        relative = f"_incoming/{uuid.uuid4().hex}"
        path = media_root / relative
        path.parent.mkdir(parents=True, exist_ok=True)
        with path.open("wb") as out:
            while chunk := file.file.read(1 << 20):
                out.write(chunk)
        persist()
        try:
            result = transcribe(relative, language)
        finally:
            path.unlink(missing_ok=True)
            persist()
        if response_format == "text":
            return PlainTextResponse(result["text"])
        if response_format == "verbose_json":
            return result
        return {"text": result["text"]}

    # MARK: Web app

    @app.post("/api/login")
    def login(body: Login):
        stored = users.get(body.username)
        if not check_password(body.password, stored or _DUMMY_HASH) or stored is None:
            raise HTTPException(401, "Wrong username or password.")
        return {"token": make_token(body.username, session_secret), "username": body.username}

    @app.get("/api/recordings")
    def list_recordings(user: str = Depends(user_of)):
        prefix = record_key(user, "")
        records = [{k: v for k, v in r.items() if k not in HEAVY}
                   for key, r in store.items() if key.startswith(prefix)]
        return sorted(records, key=lambda r: r["createdAt"], reverse=True)

    @app.post("/api/recordings")
    def upload(file: UploadFile = File(...), language: str = Form("he"), title: str = Form(""),
               source: str = Form("upload"), user: str = Depends(user_of)):
        ext = re.sub(r"[^a-z0-9]", "", Path(file.filename or "").suffix.lower())[:5] or "bin"
        kind = "video" if (file.content_type or "").startswith("video/") else "audio"
        record = new_record(user, title=title or Path(file.filename or "Recording").stem,
                            language=language, source="recording" if source == "recording" else "upload",
                            media=f"media.{ext}", mediaType=kind)
        directory = media_root / user / record["id"]
        directory.mkdir(parents=True, exist_ok=True)
        with (directory / record["media"]).open("wb") as out:
            while chunk := file.file.read(1 << 20):
                out.write(chunk)
        persist()
        start_job(user, record["id"])
        return record

    @app.post("/api/recordings/link")
    def link(body: LinkIn, user: str = Depends(user_of)):
        if not re.match(r"^https?://", body.url.strip()):
            raise HTTPException(400, "Paste an http(s) link.")
        record = new_record(user, title=body.title, language=body.language, source="url",
                            url=body.url.strip())
        start_job(user, record["id"])
        return record

    @app.get("/api/recordings/{rec_id}")
    def get_one(rec_id: str, user: str = Depends(user_of)):
        return get_record(user, rec_id)

    @app.patch("/api/recordings/{rec_id}")
    def edit(rec_id: str, body: Patch, user: str = Depends(user_of)):
        record = get_record(user, rec_id)
        record.update(body.model_dump(exclude_none=True))
        store[record_key(user, rec_id)] = record
        return record

    @app.post("/api/recordings/{rec_id}/retry")
    def retry(rec_id: str, user: str = Depends(user_of)):
        record = get_record(user, rec_id)
        if record["status"] not in ("error", "done"):
            raise HTTPException(409, "It's still working on this one.")
        record.update(status="queued", error=None)
        store[record_key(user, rec_id)] = record
        start_job(user, rec_id)
        return record

    @app.delete("/api/recordings/{rec_id}")
    def delete(rec_id: str, user: str = Depends(user_of)):
        get_record(user, rec_id)
        directory = media_root / user / rec_id
        for path in directory.glob("*"):
            path.unlink()
        if directory.exists():
            directory.rmdir()
        persist()
        del store[record_key(user, rec_id)]
        return {"deleted": rec_id}

    @app.get("/api/recordings/{rec_id}/media")
    def media(rec_id: str, user: str = Depends(user_of)):
        record = get_record(user, rec_id)
        path = media_root / user / rec_id / (record.get("media") or "-")
        if not path.exists():
            refresh()  # written by another container since this one loaded
        if not path.exists():
            raise HTTPException(404, "No media for this recording.")
        return FileResponse(path)

    return app


if __name__ == "__main__":
    import sys

    if sys.argv[1:] == ["hash-password"]:
        import getpass

        print(hash_password(getpass.getpass("Password: ")))
        sys.exit()

    import uvicorn
    from faster_whisper import WhisperModel

    model = WhisperModel(MODEL_ID, device="cpu", compute_type="int8")
    root = Path(os.environ.get("MILA_DATA", "mila-data"))
    store: dict = {}
    lock = threading.Lock()  # one CPU model: one transcription at a time

    def transcribe(relative, language):
        with lock:
            return run_whisper(model, str(root / relative), language)

    def start_job(user, rec_id):
        threading.Thread(target=process_recording, args=(user, rec_id), daemon=True,
                         kwargs={"store": store, "media_root": root, "transcribe": transcribe}).start()

    app = build_app(api_key=os.environ.get("MILA_API_KEY"),
                    users=json.loads(os.environ.get("MILA_WEB_USERS", "{}")),
                    store=store, media_root=root, transcribe=transcribe, start_job=start_job)
    uvicorn.run(app, host="127.0.0.1", port=8000)
