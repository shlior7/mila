import { useEffect, useRef, useState } from "react";
import { api, type Recording } from "./api";
import { clock } from "./format";

type Props = { onBack: () => void; onCreated: (r: Recording) => void; onError: (e: unknown) => void };

export default function NewRecording({ onBack, onCreated, onError }: Props) {
  const [language, setLanguage] = useState(() => localStorage.getItem("mila.language") ?? "he");
  const [url, setUrl] = useState("");
  const [busy, setBusy] = useState("");
  useEffect(() => { try { localStorage.setItem("mila.language", language); } catch { /* private mode */ } }, [language]);

  const send = async (work: () => Promise<Recording>, label: string) => {
    setBusy(label);
    try { onCreated(await work()); } catch (err) { onError(err); } finally { setBusy(""); }
  };

  return (
    <div className="new">
      <button className="link back" onClick={onBack}>← Back</button>
      <h2>New recording</h2>
      <label className="inline">
        Language
        <select value={language} onChange={(e) => setLanguage(e.target.value)}>
          <option value="he">Hebrew</option>
          <option value="en">English</option>
          <option value="auto">Detect</option>
        </select>
      </label>

      <div className="card">
        <h3>Record</h3>
        <Recorder disabled={!!busy} onDone={(file) => send(() => api.upload(file, language, "recording"), "Uploading recording…")} />
      </div>

      <div className="card">
        <h3>Upload a file</h3>
        <p className="muted">Audio or video, any length.</p>
        <input type="file" accept="audio/*,video/*" disabled={!!busy}
          onChange={(e) => { const f = e.target.files?.[0]; if (f) send(() => api.upload(f, language, "upload"), `Uploading ${f.name}…`); }} />
      </div>

      <form className="card" onSubmit={(e) => { e.preventDefault(); send(() => api.link(url, language), "Adding link…"); }}>
        <h3>Paste a link</h3>
        <p className="muted">A video or audio page (YouTube, Vimeo, a podcast…) or a direct file link.</p>
        <div className="row">
          <input type="url" placeholder="https://…" value={url} onChange={(e) => setUrl(e.target.value)} required disabled={!!busy} />
          <button className="primary" disabled={!!busy}>Transcribe</button>
        </div>
      </form>
      {busy && <p className="muted">{busy}</p>}
    </div>
  );
}

function Recorder({ disabled, onDone }: { disabled: boolean; onDone: (file: File) => void }) {
  const [recorder, setRecorder] = useState<MediaRecorder | null>(null);
  const [elapsed, setElapsed] = useState(0);
  const [error, setError] = useState("");
  const lock = useRef<WakeLockSentinel | null>(null);

  useEffect(() => {
    if (!recorder) return;
    const started = Date.now();
    const timer = setInterval(() => setElapsed((Date.now() - started) / 1000), 500);
    return () => clearInterval(timer);
  }, [recorder]);

  const start = async () => {
    setError("");
    let stream: MediaStream;
    try { stream = await navigator.mediaDevices.getUserMedia({ audio: true }); } catch (err) {
      setError(`No microphone: ${(err as Error).message}`);
      return;
    }
    // A locked screen stops recording in Safari: keep it awake meanwhile.
    try { lock.current = await navigator.wakeLock?.request("screen"); } catch { /* unsupported */ }
    const chunks: Blob[] = [];
    const next = new MediaRecorder(stream);
    next.ondataavailable = (e) => chunks.push(e.data);
    next.onstop = () => {
      stream.getTracks().forEach((t) => t.stop());
      lock.current?.release();
      const type = next.mimeType || "audio/mp4";
      const ext = type.includes("webm") ? "webm" : type.includes("ogg") ? "ogg" : "m4a";
      const name = `Recording ${new Date().toLocaleString()}.${ext}`;
      onDone(new File(chunks, name, { type }));
    };
    next.start(1000);
    setElapsed(0);
    setRecorder(next);
  };

  return (
    <div className="row">
      {recorder ? (
        <button className="primary" onClick={() => { recorder.stop(); setRecorder(null); }}>■ Stop · {clock(elapsed)}</button>
      ) : (
        <button className="primary" disabled={disabled} onClick={start}>● Record</button>
      )}
      {recorder && <span className="muted">Keep this tab open while recording.</span>}
      {error && <span className="error">{error}</span>}
    </div>
  );
}
