import { useCallback, useEffect, useState } from "react";
import { api, session, SignedOut, working, type Recording } from "./api";
import { when } from "./format";
import NewRecording from "./NewRecording";
import RecordingView from "./RecordingView";

export default function App() {
  const [signedIn, setSignedIn] = useState(!!session.token);
  return signedIn ? <Library onSignOut={() => { session.set(null); setSignedIn(false); }} />
    : <Login onSignedIn={() => setSignedIn(true)} />;
}

function Login({ onSignedIn }: { onSignedIn: () => void }) {
  const [username, setUsername] = useState("");
  const [password, setPassword] = useState("");
  const [error, setError] = useState("");
  const [busy, setBusy] = useState(false);
  return (
    <main className="login">
      <form
        className="card"
        onSubmit={async (e) => {
          e.preventDefault();
          setBusy(true);
          setError("");
          try {
            session.set((await api.login(username, password)).token);
            onSignedIn();
          } catch (err) {
            setError((err as Error).message);
          } finally {
            setBusy(false);
          }
        }}
      >
        <h1>Mila</h1>
        <p className="muted">Transcribe recordings, videos and links, then ask about them.</p>
        <label>Username<input autoComplete="username" value={username} onChange={(e) => setUsername(e.target.value)} required /></label>
        <label>Password<input type="password" autoComplete="current-password" value={password} onChange={(e) => setPassword(e.target.value)} required /></label>
        {error && <p className="error">{error}</p>}
        <button className="primary" disabled={busy}>{busy ? "Signing in…" : "Sign in"}</button>
      </form>
    </main>
  );
}

function Library({ onSignOut }: { onSignOut: () => void }) {
  const [items, setItems] = useState<Recording[]>([]);
  const [selected, setSelected] = useState<string | null>(() => new URLSearchParams(location.search).get("r"));
  const [adding, setAdding] = useState(false);
  const [filter, setFilter] = useState("");
  const [error, setError] = useState("");

  const guard = useCallback((err: unknown) => {
    if (err instanceof SignedOut) onSignOut();
    else setError((err as Error).message);
  }, [onSignOut]);

  const refresh = useCallback(() => api.list().then(setItems, guard), [guard]);
  useEffect(() => { refresh(); }, [refresh]);
  // Keep the list's statuses moving while anything is still being worked on.
  useEffect(() => {
    if (!items.some(working)) return;
    const timer = setInterval(refresh, 4000);
    return () => clearInterval(timer);
  }, [items, refresh]);

  const select = (id: string | null) => {
    setSelected(id);
    setAdding(false);
    history.replaceState(null, "", id ? `?r=${id}` : location.pathname);
  };

  const shown = items.filter((r) => r.title.toLowerCase().includes(filter.toLowerCase()));
  return (
    <div className={`app ${selected || adding ? "has-detail" : ""}`}>
      <aside className="sidebar">
        <header>
          <h1>Mila</h1>
          <button className="primary" onClick={() => { select(null); setAdding(true); }}>+ New</button>
        </header>
        <input className="search" placeholder="Search titles" value={filter} onChange={(e) => setFilter(e.target.value)} />
        <ul>
          {shown.map((r) => (
            <li key={r.id}>
              <button className={r.id === selected ? "item active" : "item"} onClick={() => select(r.id)}>
                <span className="title" dir="auto">{r.title || r.url || "Untitled"}</span>
                <span className="meta">
                  {when(r.createdAt)}
                  {working(r) && <span className="badge">{r.status}…</span>}
                  {r.status === "error" && <span className="badge bad">failed</span>}
                </span>
              </button>
            </li>
          ))}
          {!items.length && <li className="muted empty">Nothing yet. Press + New.</li>}
        </ul>
        <footer><button className="link" onClick={onSignOut}>Sign out</button></footer>
      </aside>
      <section className="detail">
        {error && <p className="error banner" onClick={() => setError("")}>{error}</p>}
        {adding ? (
          <NewRecording
            onBack={() => setAdding(false)}
            onCreated={(r) => { setItems((xs) => [r, ...xs]); select(r.id); }}
            onError={guard}
          />
        ) : selected ? (
          <RecordingView
            key={selected}
            id={selected}
            onBack={() => select(null)}
            onChanged={(r) => setItems((xs) => xs.map((x) => (x.id === r.id ? { ...x, ...r } : x)))}
            onDeleted={() => { setItems((xs) => xs.filter((x) => x.id !== selected)); select(null); }}
            onError={guard}
          />
        ) : (
          <div className="placeholder muted">Pick a recording, or press + New.</div>
        )}
      </section>
    </div>
  );
}
