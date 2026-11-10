# Mila transcription server on Modal

An OpenAI-compatible `POST /v1/audio/transcriptions` endpoint serving the
ivrit.ai Hebrew model (`ivrit-ai/whisper-large-v3-turbo-ct2`, faster-whisper)
on a [Modal](https://modal.com) T4 GPU. Mila on the Mac (Settings → Models →
Remote API) and on the iPad (Settings → Model → Remote server) can both use it.

**Cost.** Modal bills per second, only while a container is up: a T4 is
about $0.59/hour, and the free plan includes $30 of compute a month. One hour
of audio should take a few GPU minutes, so a few cents. The container shuts
down 2 minutes after the last request (`scaledown_window`), and the first
request after that waits for a cold start (about 30–60 s).

**Privacy.** Audio is uploaded to Modal. Requests need the API key; without
it the server answers 401.

## Deploy

```bash
pip install modal
modal setup                       # log in (opens the browser)
KEY=$(openssl rand -hex 24); echo "$KEY"   # keep it: Modal won't show it again
modal secret create mila-transcribe MILA_API_KEY="$KEY"
modal deploy server/modal/modal_app.py
```

`modal deploy` prints a URL like
`https://<you>--mila-transcribe-server-web.modal.run`. In Mila:

- **URL:** that URL plus `/v1`
- **API key:** `$KEY` from above.
- **Model:** `ivrit-ai/whisper-large-v3-turbo-ct2` (any value works; the
  server has one model).

## Run it locally

On the CPU, with no auth, at `http://127.0.0.1:8000/v1`:

```bash
pip install faster-whisper==1.1.1 "huggingface_hub<1.0" "fastapi[standard]"
python server/modal/api.py        # MILA_API_KEY=… to require a key
```

The repo's real-server E2E runs against it:

```bash
TEST_RUNNER_MILA_REMOTE_TEST_ENDPOINT=http://127.0.0.1:8000/v1 \
TEST_RUNNER_MILA_REMOTE_HEBREW=1 \
TEST_RUNNER_MILA_REMOTE_MODEL=ivrit-ai/whisper-large-v3-turbo-ct2 \
xcodebuild test -project Mila.xcodeproj -scheme Mila -destination 'platform=macOS' \
  -only-testing:MilaTests/RemoteTranscriptionE2ETests
```

## Not verified yet

- The Modal deploy itself (image build, CUDA, GPU inference) — only the
  local CPU server is tested.
- Long recordings: Modal web requests longer than 150 s are answered with a
  303 redirect to the result. URLSession follows it, but no recording that
  long has been sent through it yet.
