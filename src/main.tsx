import React from "react";
import ReactDOM from "react-dom/client";
import { BrowserRouter } from "react-router-dom";
import { getCurrentWindow } from "@tauri-apps/api/window";
import App from "./App";
import { MeetingPrompt } from "./MeetingPrompt";
import { RecordingIndicator } from "./RecordingIndicator";
import { ErrorBoundary } from "./components/ErrorBoundary";
// Self-hosted Hanken Grotesk (bundled via @fontsource) — one typeface for
// the whole UI, hierarchy from size + weight only. No external Google Fonts
// request, so the app renders offline and the CSP stays font-src 'self'.
// Weights mirror the prototype: 400/500/600/700.
import "@fontsource/hanken-grotesk/400.css";
import "@fontsource/hanken-grotesk/500.css";
import "@fontsource/hanken-grotesk/600.css";
import "@fontsource/hanken-grotesk/700.css";
import "./styles/globals.css";

// The borderless helper windows each render ONLY their own floating widget —
// none of the main app's router/boot. Everything else is the full app.
const label = getCurrentWindow().label;

function Root() {
  if (label === "meeting-prompt") return <MeetingPrompt />;
  if (label === "recording-indicator") return <RecordingIndicator />;
  return (
    <BrowserRouter>
      <App />
    </BrowserRouter>
  );
}

ReactDOM.createRoot(document.getElementById("root")!).render(
  <React.StrictMode>
    <ErrorBoundary>
      <Root />
    </ErrorBoundary>
  </React.StrictMode>
);
