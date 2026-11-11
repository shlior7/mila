import type { Recording } from "./api";

export function clock(seconds: number): string {
  const s = Math.max(0, Math.floor(seconds));
  const h = Math.floor(s / 3600), m = Math.floor(s / 60) % 60, r = s % 60;
  const pad = (n: number) => String(n).padStart(2, "0");
  return h ? `${h}:${pad(m)}:${pad(r)}` : `${m}:${pad(r)}`;
}

function srtStamp(t: number): string {
  const ms = Math.round(t * 1000);
  const pad = (n: number, w = 2) => String(n).padStart(w, "0");
  return `${pad(Math.floor(ms / 3600000))}:${pad(Math.floor(ms / 60000) % 60)}:${pad(Math.floor(ms / 1000) % 60)},${pad(ms % 1000, 3)}`;
}

export function toText(r: Recording): string {
  return (r.segments ?? []).map((s) => s.text.trim()).join("\n") || r.text || "";
}

export function toSRT(r: Recording): string {
  return (r.segments ?? [])
    .map((s, i) => `${i + 1}\n${srtStamp(s.start)} --> ${srtStamp(s.end)}\n${s.text.trim()}\n`)
    .join("\n");
}

export function toMarkdown(r: Recording): string {
  const parts = [`# ${r.title}`, ""];
  if (r.url) parts.push(`Source: ${r.url}`, "");
  if (r.analysis) parts.push(r.analysis.markdown, "");
  parts.push("## Transcript", "", ...(r.segments ?? []).map((s) => `**[${clock(s.start)}]** ${s.text.trim()}  `));
  return parts.join("\n");
}

export function download(name: string, text: string) {
  const link = document.createElement("a");
  link.href = URL.createObjectURL(new Blob([text], { type: "text/plain;charset=utf-8" }));
  link.download = name.replace(/[\\/:*?"<>|]/g, "_");
  link.click();
  setTimeout(() => URL.revokeObjectURL(link.href), 1000);
}

export function when(iso: string): string {
  return new Date(iso).toLocaleString(undefined, { dateStyle: "medium", timeStyle: "short" });
}
