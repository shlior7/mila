"""Mila's transcription server on a Modal GPU. Deploy (see README.md):

    modal secret create mila-transcribe MILA_API_KEY=<a long random string>
    modal deploy server/modal/modal_app.py
"""
from pathlib import Path

import modal

MODEL_ID = "ivrit-ai/whisper-large-v3-turbo-ct2"


def download_model():
    from huggingface_hub import snapshot_download

    snapshot_download(MODEL_ID)


image = (
    # CUDA 12 + cuDNN 9: what ctranslate2 4.5 (faster-whisper 1.1.1) links.
    modal.Image.from_registry("nvidia/cuda:12.4.1-cudnn-runtime-ubuntu22.04", add_python="3.11")
    # huggingface_hub 1.x drops `requests`, which faster-whisper 1.1.1 imports.
    .pip_install("faster-whisper==1.1.1", "huggingface_hub<1.0", "fastapi[standard]==0.115.12")
    # Baked into the image, so a cold start doesn't download 1.6 GB.
    .run_function(download_model)
    .add_local_file(Path(__file__).with_name("api.py"), "/root/api.py")
)

app = modal.App("mila-transcribe", image=image)


@app.cls(
    gpu="T4",
    # Billing runs while a container is up: shut down 2 minutes after the
    # last request rather than keeping a GPU warm.
    scaledown_window=120,
    timeout=60 * 60,
    secrets=[modal.Secret.from_name("mila-transcribe")],
)
class Server:
    @modal.enter()
    def load(self):
        from faster_whisper import WhisperModel

        self.model = WhisperModel(MODEL_ID, device="cuda", compute_type="float16")

    @modal.asgi_app()
    def web(self):
        import os

        from api import build_app

        # KeyError, not an open server, if the secret lacks the key.
        return build_app(self.model, os.environ["MILA_API_KEY"])
