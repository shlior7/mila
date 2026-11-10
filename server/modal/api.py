"""OpenAI-compatible `POST /v1/audio/transcriptions` over faster-whisper.

Serves the subset Mila sends (`RemoteWhisperEngine.multipartBody`): a
multipart `file`, `model` (ignored: one model is loaded), `language` and
`response_format` (`json`, `verbose_json` or `text`).

`modal_app.py` deploys it on a GPU. Run it locally on the CPU, no auth:

    python server/modal/api.py
"""
import hmac
import os

from fastapi import FastAPI, File, Form, Header, HTTPException, UploadFile
from fastapi.responses import PlainTextResponse

MODEL_ID = "ivrit-ai/whisper-large-v3-turbo-ct2"


def build_app(model, api_key: str | None) -> FastAPI:
    """`api_key` None turns auth off; only the local run passes None."""
    app = FastAPI()

    @app.get("/health")
    def health():
        return {"status": "ok"}

    # Sync on purpose: FastAPI runs it on a worker thread, so a long
    # transcription doesn't block the event loop.
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
        # vad_filter: skip long silences, where whisper hallucinates.
        segments, info = model.transcribe(file.file, language=language or None, vad_filter=True)
        segs = [{"id": i, "start": s.start, "end": s.end, "text": s.text} for i, s in enumerate(segments)]
        text = "".join(s["text"] for s in segs).strip()
        if response_format == "text":
            return PlainTextResponse(text)
        if response_format == "verbose_json":
            return {"task": "transcribe", "language": info.language, "duration": info.duration,
                    "text": text, "segments": segs}
        return {"text": text}

    return app


if __name__ == "__main__":
    import uvicorn
    from faster_whisper import WhisperModel

    model = WhisperModel(MODEL_ID, device="cpu", compute_type="int8")
    uvicorn.run(build_app(model, os.environ.get("MILA_API_KEY")), host="127.0.0.1", port=8000)
