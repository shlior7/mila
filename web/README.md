# Mila web

Mila in the browser: record (works in Safari on an iPad), upload audio or
video, or paste a link; read and search the transcript next to the player;
export it; and analyze it or chat about it with Claude or OpenAI on your own
API key. The key stays in the browser and goes straight to Anthropic or
OpenAI — the Mila server never sees it.

The backend is `server/modal/`; this is a static Vite + React site.

```bash
npm install
echo "VITE_API_URL=http://127.0.0.1:8000" > .env.local   # a local server/modal/api.py
npm run dev
```

## Deploy (Vercel)

```bash
vercel deploy --prod --build-env VITE_API_URL=https://<you>--mila-transcribe-web.modal.run
```

The app has its own sign-in, so turn off Vercel's Deployment Protection
(Project → Settings → Deployment Protection) or visitors hit Vercel's
login first.

`.npmrc` keeps registry URLs out of `package-lock.json`, so the lockfile
installs from whichever registry the machine uses (Vercel uses npmjs.org).
