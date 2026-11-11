"""Mila's server on Modal. Deploy (see README.md):

    modal secret create mila-transcribe MILA_API_KEY=<a long random string>
    modal secret create mila-web-users MILA_WEB_USERS='{"name": "<hash>"}'
    modal deploy server/modal/modal_app.py

Three pieces, so the GPU runs only while it transcribes:
  * `web` (CPU): the HTTP API (`api.py`), for the apps and the web app.
  * `process` (CPU): one job per recording; downloads links with yt-dlp.
  * `Transcriber` (T4 GPU): faster-whisper with the ivrit.ai model.
Recordings are JSON in a Modal Dict; their media lives on a Modal Volume.
"""
from pathlib import Path

import modal

MODEL_ID = "ivrit-ai/whisper-large-v3-turbo-ct2"
DATA = Path("/data")

volume = modal.Volume.from_name("mila-data", create_if_missing=True)
store = modal.Dict.from_name("mila-recordings", create_if_missing=True)
secrets = [modal.Secret.from_name("mila-transcribe"), modal.Secret.from_name("mila-web-users")]


def download_model():
    from huggingface_hub import snapshot_download

    snapshot_download(MODEL_ID)


gpu_image = (
    # CUDA 12 + cuDNN 9: what ctranslate2 4.5 (faster-whisper 1.1.1) links.
    modal.Image.from_registry("nvidia/cuda:12.4.1-cudnn-runtime-ubuntu22.04", add_python="3.11")
    # huggingface_hub 1.x drops `requests`, which faster-whisper 1.1.1 imports.
    .pip_install("faster-whisper==1.1.1", "huggingface_hub<1.0", "fastapi[standard]==0.115.12")
    # Baked into the image, so a cold start doesn't download 1.6 GB.
    .run_function(download_model)
    .add_local_file(Path(__file__).with_name("api.py"), "/root/api.py")
)

cpu_image = (
    modal.Image.debian_slim(python_version="3.11")
    # ffmpeg: yt-dlp needs it to pull audio out of some sites' streams.
    .apt_install("ffmpeg")
    .pip_install("fastapi[standard]==0.115.12", "yt-dlp")
    .add_local_file(Path(__file__).with_name("api.py"), "/root/api.py")
)

app = modal.App("mila-transcribe")


@app.cls(
    image=gpu_image,
    gpu="T4",
    volumes={DATA: volume},
    # Billing runs while a container is up: shut down 2 minutes after the
    # last transcription rather than keeping a GPU warm.
    scaledown_window=120,
    timeout=60 * 60,
)
class Transcriber:
    @modal.enter()
    def load(self):
        from faster_whisper import BatchedInferencePipeline, WhisperModel

        self.model = BatchedInferencePipeline(WhisperModel(MODEL_ID, device="cuda", compute_type="float16"))

    @modal.method()
    def transcribe(self, relative: str, language: str | None) -> dict:
        from api import run_whisper

        volume.reload()  # see the file the web container just wrote
        return run_whisper(self.model, str(DATA / relative), language, batch_size=16)


def _transcribe(relative: str, language: str | None) -> dict:
    return Transcriber().transcribe.remote(relative, language)


# mila-youtube: YT_COOKIES, optional (empty is fine) — see README.md.
@app.function(image=cpu_image, volumes={DATA: volume}, timeout=2 * 60 * 60,
              secrets=[modal.Secret.from_name("mila-youtube")])
def process(user: str, rec_id: str):
    from api import process_recording

    process_recording(user, rec_id, store=store, media_root=DATA, transcribe=_transcribe,
                      refresh=volume.reload, persist=volume.commit)


@app.function(image=cpu_image, volumes={DATA: volume}, secrets=secrets, timeout=60 * 60,
              scaledown_window=300)
@modal.concurrent(max_inputs=20)
@modal.asgi_app()
def web():
    import json
    import os

    from api import build_app

    # KeyError, not an open server, if a secret lacks its key.
    return build_app(api_key=os.environ["MILA_API_KEY"], users=json.loads(os.environ["MILA_WEB_USERS"]),
                     store=store, media_root=DATA, transcribe=_transcribe,
                     start_job=lambda user, rec_id: process.spawn(user, rec_id),
                     refresh=volume.reload, persist=volume.commit)
