import { useEffect, useRef, useState } from "react";
import { invoke } from "@tauri-apps/api/core";
import { listen } from "@tauri-apps/api/event";
import { ipc } from "./lib/ipc";

// The floating recording indicator (problem 5 / OI-236). Rendered ALONE in the
// borderless, always-on-top, all-Spaces `recording-indicator` window while a
// recording is live. No timer (per user). Waveform driven by the REAL mic+system
// level so it falls flat in silence. Hover expands to show the live transcript.
//
// The window SIZES ITSELF to the pill: after every layout change we measure the
// pill and ask Rust to resize the window to fit (+ shadow margin), so it never
// clips no matter how wide the content renders.
const BARS = 7;
const MARGIN = 16; // px of window around the pill, for the shadow

export function RecordingIndicator() {
  const [paused, setPaused] = useState(false);
  const [expanded, setExpanded] = useState(false);
  const [latest, setLatest] = useState("");
  const [levels, setLevels] = useState<number[]>(() => Array(BARS).fill(0));
  const pausedRef = useRef(false);
  const pillRef = useRef<HTMLDivElement>(null);

  // Resize the window to exactly fit the pill. Measured after layout via rAF.
  const fit = () => {
    requestAnimationFrame(() => {
      const el = pillRef.current;
      if (!el) return;
      const r = el.getBoundingClientRect();
      void invoke("indicator_resize", {
        w: Math.ceil(r.width) + MARGIN * 2,
        h: Math.ceil(r.height) + MARGIN * 2,
      });
    });
  };

  useEffect(() => {
    for (const el of [document.documentElement, document.body]) {
      el.style.background = "transparent";
      el.style.backgroundColor = "transparent";
    }
    const root = document.getElementById("root");
    if (root) root.style.background = "transparent";
    void ipc
      .getSetting("theme")
      .then((t) => {
        if (t === "light" || t === "dark") document.documentElement.setAttribute("data-theme", t);
      })
      .catch(() => {});

    const unShow = listen("recording-indicator-show", () => {
      setLatest("");
      setLevels(Array(BARS).fill(0));
      setPaused(false);
      pausedRef.current = false;
      setExpanded(false);
      fit();
    });
    const unStatus = listen<{ phase: string }>("recording_status", (e) => {
      const p = (e.payload as { phase?: string })?.phase === "paused";
      pausedRef.current = p;
      setPaused(p);
    });
    // Rust re-emits the FULL transcript on each change under "transcript_replaced"
    // (there is no incremental "appended" event). Show the tail — the most recent
    // words — so the pill reads like a live caption.
    const unTx = listen<{ text: string }>("transcript_replaced", (e) => {
      const t = (e.payload as { text?: string })?.text;
      if (typeof t === "string") setLatest(t.trim().slice(-240));
    });
    const unLevel = listen<number>("recording_level", (e) => {
      const l = typeof e.payload === "number" ? e.payload : 0;
      setLevels((prev) => [...prev.slice(1), l]);
    });
    fit();
    return () => {
      void unShow.then((f) => f());
      void unStatus.then((f) => f());
      void unTx.then((f) => f());
      void unLevel.then((f) => f());
    };
  }, []);

  // Refit whenever the pill's size could change.
  useEffect(() => {
    fit();
  }, [expanded, latest]);

  const barHeight = (lvl: number) => 2 + Math.min(1, (paused ? 0 : lvl) * 7) * 12;

  return (
    <div
      style={{
        position: "fixed",
        inset: 0,
        display: "flex",
        // Anchor the pill to the TOP-RIGHT of the window. The window's right edge
        // stays fixed as it grows on hover (see indicator_resize), so the pill —
        // and the Stop button pinned to its right — never slide out from under
        // the cursor. Padding gives the shadow room on the anchored side.
        alignItems: "flex-start",
        justifyContent: "flex-end",
        padding: 16,
        boxSizing: "border-box",
        background: "transparent",
        fontFamily: "'Hanken Grotesk', system-ui, sans-serif",
      }}
    >
      <style>{`@keyframes rec-pulse { 0%,100%{opacity:1;transform:scale(1)} 50%{opacity:.35;transform:scale(.82)} }`}</style>
      <div
        ref={pillRef}
        data-tauri-drag-region
        onMouseEnter={() => setExpanded(true)}
        onMouseLeave={() => setExpanded(false)}
        style={{
          flexShrink: 0,
          background: "var(--color-surface)",
          color: "var(--color-text)",
          border: "1px solid var(--color-card-border)",
          borderRadius: 16,
          boxShadow: "0 6px 16px rgba(0,0,0,0.28)",
          padding: "7px 12px",
          cursor: "grab",
        }}
      >
        <div data-tauri-drag-region style={{ display: "flex", alignItems: "center", gap: 10 }}>
          <span
            data-tauri-drag-region
            style={{
              width: 8,
              height: 8,
              borderRadius: "50%",
              background: "var(--color-record)",
              flexShrink: 0,
              animation: paused ? "none" : "rec-pulse 1.3s ease-in-out infinite",
              opacity: paused ? 0.5 : 1,
            }}
          />
          <div data-tauri-drag-region style={{ display: "flex", alignItems: "center", gap: 2, height: 14, flexShrink: 0 }}>
            {levels.map((lvl, i) => (
              <span
                key={i}
                style={{
                  width: 2.5,
                  height: barHeight(lvl),
                  borderRadius: 2,
                  background: "var(--color-record)",
                  opacity: paused ? 0.4 : 0.92,
                  transition: "height 90ms ease-out",
                }}
              />
            ))}
          </div>
          <button
            onClick={() => void invoke("recording_stop")}
            title="Stop recording"
            style={{
              display: "flex",
              alignItems: "center",
              gap: 5,
              marginLeft: "auto", // pin to the right edge as the pill widens
              background: "var(--color-surface-raised)",
              color: "var(--color-text)",
              border: "1px solid var(--color-card-border)",
              borderRadius: 999,
              padding: "4px 11px",
              fontWeight: 600,
              fontSize: 12,
              cursor: "pointer",
              flexShrink: 0,
            }}
          >
            <span style={{ width: 8, height: 8, borderRadius: 2, background: "var(--color-record)", display: "inline-block" }} />
            Stop
          </button>
        </div>
        {expanded && (
          <div
            style={{
              marginTop: 8,
              width: 256,
              fontSize: 11.5,
              lineHeight: 1.4,
              color: "var(--color-text-muted)",
              maxHeight: 46,
              overflow: "hidden",
            }}
          >
            {latest || "Listening…"}
          </div>
        )}
      </div>
    </div>
  );
}
