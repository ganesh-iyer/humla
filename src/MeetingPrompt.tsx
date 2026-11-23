import { useEffect, useRef } from "react";
import { invoke } from "@tauri-apps/api/core";
import { listen } from "@tauri-apps/api/event";
import { ipc } from "./lib/ipc";

// The floating "meeting detected" prompt (problem 5). Rendered ALONE in the
// borderless, always-on-top `meeting-prompt` window — NOT a system notification
// — so it ignores macOS Focus/Do-Not-Disturb. No visible countdown: the user
// dismisses with the Ignore button, and an untouched card silently auto-clears
// after AUTO_DISMISS_SECS so false positives don't pile up.
const AUTO_DISMISS_SECS = 20;

export function MeetingPrompt() {
  const timerRef = useRef<number | null>(null);

  useEffect(() => {
    // Make the WINDOW itself see-through — the rounded card is the only opaque
    // thing. Without clearing all three the webview paints the canvas colour and
    // you get a black/near-black box behind the card.
    for (const el of [document.documentElement, document.body]) {
      el.style.background = "transparent";
      el.style.backgroundColor = "transparent";
    }
    const root = document.getElementById("root");
    if (root) root.style.background = "transparent";

    // Match the user's chosen theme (system → OS light/dark), same rule as the
    // main app (lib/theme.ts): data-theme on <html>, absent = system.
    void ipc
      .getSetting("theme")
      .then((t) => {
        if (t === "light" || t === "dark") {
          document.documentElement.setAttribute("data-theme", t);
        }
      })
      .catch(() => {});

    // (Re)arm the silent auto-dismiss on EACH show. This window is created
    // (hidden) at launch and reused, so a mount-time timer would fire once at
    // startup; Rust emits "meeting-prompt-show" every time it floats the card.
    const armAutoDismiss = () => {
      if (timerRef.current) window.clearTimeout(timerRef.current);
      timerRef.current = window.setTimeout(() => {
        void invoke("meeting_prompt_dismiss");
      }, AUTO_DISMISS_SECS * 1000);
    };
    const unlisten = listen("meeting-prompt-show", () => armAutoDismiss());
    return () => {
      void unlisten.then((f) => f());
      if (timerRef.current) window.clearTimeout(timerRef.current);
    };
  }, []);

  return (
    <div
      style={{
        position: "fixed",
        inset: 0,
        display: "flex",
        alignItems: "flex-start",
        justifyContent: "flex-end",
        padding: 8,
        boxSizing: "border-box",
        background: "transparent",
        fontFamily: "'Hanken Grotesk', system-ui, sans-serif",
      }}
    >
      <div
        style={{
          width: "100%",
          maxWidth: 336,
          background: "var(--color-surface)",
          color: "var(--color-text)",
          borderRadius: 14,
          boxShadow: "0 10px 34px rgba(0,0,0,0.28)",
          border: "1px solid var(--color-card-border)",
          overflow: "hidden",
          padding: "12px 14px 12px",
        }}
      >
        <div style={{ display: "flex", alignItems: "center", gap: 8 }}>
          <span
            style={{
              width: 7,
              height: 7,
              borderRadius: "50%",
              background: "var(--color-record)",
              flexShrink: 0,
            }}
          />
          <span style={{ fontWeight: 600, fontSize: 13.5 }}>Meeting detected</span>
        </div>
        <div style={{ fontSize: 12.5, color: "var(--color-text-muted)", marginTop: 4 }}>
          Take notes for this meeting?
        </div>
        <div style={{ display: "flex", gap: 8, marginTop: 12 }}>
          <button
            onClick={() => void invoke("meeting_prompt_accept")}
            style={{
              flex: 1,
              background: "var(--color-accent)",
              color: "var(--color-on-accent)",
              border: "none",
              borderRadius: 8,
              padding: "8px 10px",
              fontWeight: 600,
              fontSize: 12.5,
              cursor: "pointer",
            }}
          >
            Take notes
          </button>
          <button
            onClick={() => void invoke("meeting_prompt_dismiss")}
            style={{
              background: "var(--color-surface-raised)",
              color: "var(--color-text-muted)",
              border: "1px solid var(--color-card-border)",
              borderRadius: 8,
              padding: "8px 14px",
              fontWeight: 500,
              fontSize: 12.5,
              cursor: "pointer",
            }}
          >
            Ignore
          </button>
        </div>
      </div>
    </div>
  );
}
