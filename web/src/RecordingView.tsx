import { useEffect, useMemo, useRef, useState } from "react";
import { api, working, type Recording } from "./api";
import { clock, download, toMarkdown, toSRT, toText, when } from "./format";
import AIPanel from "./AIPanel";

type Props = {
  id: string;
  onBack: () => void;
  onChanged: (r: Recording) => void;
  onDeleted: () => void;
  onError: (e: unknown) => void;
};

const STATUS: Record<string, string> = {
  queued: "Waiting for a transcriber…",
  downloading: "Downloading the link…",
  transcribing: "Transcribing… (about 1 minute per 5 minutes of audio, plus up to a minute to start)",
};

export default function RecordingView({ id, onBack, onChanged, onDeleted, onError }: Props) {
  const [recording, setRecording] = useState<Recording | null>(null);
  const [title, setTitle] = useState("");
  const [query, setQuery] = useState("");
  const [now, setNow] = useState(0);
  const player = useRef<HTMLMediaElement | null>(null);

  const update = (r: Recording) => { setRecording(r); onChanged(r); };

  useEffect(() => {
    let alive = true;
    let timer: ReturnType<typeof setTimeout>;
    const load = async () => {
      try {
        const r = await api.get(id);
        if (!alive) return;
        setRecording((prev) => { if (!prev) setTitle(r.title); return r; });
        onChanged(r);
        if (working(r)) timer = setTimeout(load, 3000);
      } catch (err) { onError(err); }
    };
    load();
    return () => { alive = false; clearTimeout(timer); };
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [id]);

  const segments = recording?.segments ?? [];
  const shown = useMemo(() => {
    const q = query.trim().toLowerCase();
    return q ? segments.filter((s) => s.text.toLowerCase().includes(q)) : segments;
  }, [segments, query]);
  const current = segments.findLast((s) => s.start <= now)?.id;

  if (!recording) return <div className="placeholder muted">Loading…</div>;

  const saveTitle = async () => {
    const trimmed = title.trim();
    if (!trimmed || trimmed === recording.title) return;
    try { update(await api.patch(id, { title: trimmed })); } catch (err) { onError(err); }
  };
  const seek = (t: number) => {
    if (!player.current) return;
    player.current.currentTime = t;
    player.current.play();
  };
  const name = recording.title || "transcript";
  const done = recording.status === "done";

  return (
    <div className="recording">
      <div className="main">
        <button className="link back" onClick={onBack}>← Library</button>
        <input className="title-edit" dir="auto" value={title} onChange={(e) => setTitle(e.target.value)}
          onBlur={saveTitle} onKeyDown={(e) => e.key === "Enter" && (e.target as HTMLInputElement).blur()} />
        <p className="muted small">
          {when(recording.createdAt)}
          {recording.duration ? ` · ${clock(recording.duration)}` : ""}
          {recording.url && <> · <a href={recording.url} target="_blank" rel="noreferrer">source</a></>}
        </p>

        {recording.media && (recording.mediaType === "video" ? (
          <video ref={(el) => { player.current = el; }} className="player" controls preload="metadata"
            src={api.mediaURL(id)} onTimeUpdate={(e) => setNow(e.currentTarget.currentTime)} />
        ) : (
          <audio ref={(el) => { player.current = el; }} className="player" controls preload="metadata"
            src={api.mediaURL(id)} onTimeUpdate={(e) => setNow(e.currentTarget.currentTime)} />
        ))}

        {working(recording) && <p className="status"><span className="spinner" /> {STATUS[recording.status]}</p>}
        {recording.status === "error" && (
          <div className="error banner">
            Failed: {recording.error}
            <button onClick={async () => { try { update(await api.retry(id)); } catch (err) { onError(err); } }}>Try again</button>
          </div>
        )}

        {done && (
          <>
            <div className="toolbar">
              <input className="search" placeholder="Search the transcript" value={query} onChange={(e) => setQuery(e.target.value)} />
              <button onClick={() => navigator.clipboard.writeText(toText(recording))}>Copy</button>
              <button onClick={() => download(`${name}.txt`, toText(recording))}>.txt</button>
              <button onClick={() => download(`${name}.srt`, toSRT(recording))}>.srt</button>
              <button onClick={() => download(`${name}.md`, toMarkdown(recording))}>.md</button>
            </div>
            <ol className="transcript" dir="auto">
              {shown.map((s) => (
                <li key={s.id} className={s.id === current ? "now" : ""}>
                  <button className="stamp" onClick={() => seek(s.start)}>{clock(s.start)}</button>
                  <span>{s.text.trim()}</span>
                </li>
              ))}
              {!segments.length && <li className="muted">Nothing was said.</li>}
              {segments.length > 0 && !shown.length && <li className="muted">No line matches “{query}”.</li>}
            </ol>
          </>
        )}
        <button className="link danger" onClick={async () => {
          if (!confirm(`Delete “${name}”? This can't be undone.`)) return;
          try { await api.remove(id); onDeleted(); } catch (err) { onError(err); }
        }}>Delete recording</button>
      </div>
      {done && <AIPanel recording={recording} onSaved={update} onError={onError} onSeek={seek} />}
    </div>
  );
}
