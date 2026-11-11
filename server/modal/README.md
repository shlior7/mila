# Mila server on Modal

The backend for Mila's remote transcription and for the web app (`web/`).
It serves the ivrit.ai Hebrew model (`ivrit-ai/whisper-large-v3-turbo-ct2`,
faster-whisper, batched) on a [Modal](https://modal.com) T4 GPU.

- **The apps:** `POST /v1/audio/transcriptions`, OpenAI-compatible, behind a
  bearer key. Mila on the Mac (Settings → Models → Remote API) and on the
  iPad (Settings → Model → Remote server) both use it.
- **The web app:** `/api/*` — sign in, a library per user, uploads,
  links (downloaded with yt-dlp), and background transcription jobs.

Three Modal functions, so the GPU runs only while it transcribes:
`web` (CPU, the HTTP API), `process` (CPU, one job per recording) and
`Transcriber` (GPU). Recordings are JSON in the `mila-recordings` Dict; media
lives on the `mila-data` Volume.

**Cost.** Modal bills per second, only while a container is up. A T4 is
about $0.59/hour and transcribes an hour of audio in a few minutes; the free
plan includes $30 of compute a month. Containers shut down after a couple of
idle minutes, and the first request after that waits for a cold start
(about 30–60 s).

**Privacy.** Audio is uploaded to Modal. The apps' route needs the bearer
key; the web API needs a signed-in user's token. There is no rate limit on
wrong passwords, so use long random ones.

## Deploy

```bash
pip install modal
modal setup                       # log in (opens the browser)
KEY=$(openssl rand -hex 24); echo "$KEY"   # keep it: Modal won't show it again
modal secret create mila-transcribe MILA_API_KEY="$KEY"
# Web app users, {"name": "<hash>"}; the hash comes from a password prompt:
HASH=$(python server/modal/api.py hash-password)
modal secret create mila-web-users MILA_WEB_USERS="{\"lior\": \"$HASH\"}"
modal secret create mila-youtube YT_COOKIES=""     # see "YouTube" below
modal deploy server/modal/modal_app.py
```

`modal deploy` prints the `web` URL, like
`https://<you>--mila-transcribe-web.modal.run`. In the Mila apps:

- **URL:** that URL plus `/v1`
- **API key:** `$KEY` from above.
- **Model:** `ivrit-ai/whisper-large-v3-turbo-ct2` (any value works; the
  server has one model).

For the web app, build `web/` with `VITE_API_URL` set to that URL (see
`web/README.md`).

To add or change a user, recreate the secret with every user in it
(`modal secret create --force mila-web-users …`) and deploy again. Changing
`MILA_API_KEY` also signs every web user out.

## YouTube

YouTube refuses downloads from datacenter IPs like Modal's ("Sign in to
confirm you're not a bot"). Other sites and direct file links work. To get
YouTube links working, export a signed-in browser's youtube.com cookies in
Netscape format (a "cookies.txt" browser extension does this) and store them:

```bash
modal secret create --force mila-youtube YT_COOKIES="$(cat cookies.txt)"
modal deploy server/modal/modal_app.py
```

Use a spare Google account: the cookies sign in as it, and automated
downloads break YouTube's terms of service.

## Run it locally

On the CPU, at `http://127.0.0.1:8000`; the library lives in memory and
media in `./mila-data`:

```bash
pip install faster-whisper==1.1.1 "huggingface_hub<1.0" "fastapi[standard]" yt-dlp
MILA_WEB_USERS='{"me": "<hash>"}' python server/modal/api.py   # MILA_API_KEY=… to require a key on /v1
```

The repo's real-server E2E runs against it:

```bash
TEST_RUNNER_MILA_REMOTE_TEST_ENDPOINT=http://127.0.0.1:8000/v1 \
TEST_RUNNER_MILA_REMOTE_HEBREW=1 \
TEST_RUNNER_MILA_REMOTE_MODEL=ivrit-ai/whisper-large-v3-turbo-ct2 \
xcodebuild test -project Mila.xcodeproj -scheme Mila -destination 'platform=macOS' \
  -only-testing:MilaTests/RemoteTranscriptionE2ETests
```

Long requests: Modal answers web requests that run past 150 s with a 303
redirect to the result. URLSession and `curl -L` follow it; a 1-hour
recording has been sent through `/v1` this way. The web app never waits that
long, since it polls its jobs instead.
