import { useEffect } from "react";
import { useNavigate } from "react-router-dom";
import { listen } from "@tauri-apps/api/event";
import { useNotesStore } from "./store";

// rashek:// trigger (problem 5). The create-note + start/stop-recording work is
// now driven entirely from Rust (lib.rs `trigger_record` / `trigger_stop`),
// because a menu-bar / accessory app often has no live webview to receive an
// emitted event — so the recording must NOT depend on this frontend running.
//
// The frontend's only remaining job is presentational: when Rust starts a
// recording it emits "rashek-open-note" with the new note id, and here we
// refresh the list and navigate to it so an open window follows along. The
// recording UI itself is driven by the backend recording-status events
// (bindBackendListeners), independent of this handler.
export function useDeepLinkTrigger() {
  const navigate = useNavigate();
  useEffect(() => {
    const unlisten = listen<string>("rashek-open-note", (event) => {
      const noteId = event.payload;
      if (!noteId) return;
      // Pull the just-created note into the store, then show it.
      void useNotesStore.getState().refresh();
      navigate(`/note/${noteId}`);
    });
    return () => {
      unlisten.then((u) => u());
    };
  }, [navigate]);
}
