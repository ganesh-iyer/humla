mod db;
mod html_text;
mod openai;
mod local_whisper;
mod diarize;
mod languages;
mod presets;
mod wav;
mod recording;
mod sessions;
mod commands;
mod stt;
pub mod sync;

use std::sync::Arc;
use parking_lot::Mutex;
use tauri::menu::{Menu, MenuItem, PredefinedMenuItem, Submenu};
use tauri::{Emitter, Manager};

pub struct AppState {
    pub db: Arc<Mutex<rusqlite::Connection>>,
    pub recording: Arc<Mutex<recording::LiveCapture>>,
    pub whisper: local_whisper::SharedContext,
    // Held for the duration of one chunk's transcription so back-to-back
    // chunks don't both read a stale trail snapshot. Sequential transcribes
    // mean each chunk's initial_prompt sees the *committed* output of every
    // prior chunk in this session.
    pub transcribe_gate: Arc<tokio::sync::Mutex<()>>,
    // Per-provider Keychain cache, keyed by provider_id ("openai",
    // "deepgram", "groq"). Each provider's first read triggers exactly
    // one OS-level Keychain prompt; subsequent reads return from this
    // map. Populated lazily by `read_provider_api_key` and updated by
    // `set_provider_api_key` so settings UI writes take effect
    // immediately.
    pub api_key_cache: stt::ApiKeyCache,
    /// Notified after each successful local write. `NoopSync` in the
    /// open-source build; a commercial build installs an observer that
    /// enqueues the change for upload.
    pub sync: Arc<dyn sync::SyncObserver>,
    /// Serializes every read-modify-write of any note's `sessions.json`.
    /// The post-stop chain (`migrate_flat_if_needed` + `append_session`) and
    /// the cloud pull worker (`reconcile_manifest` + `write_manifest`) both
    /// rewrite the manifest with no other coordination; without this a
    /// concurrent pull + finalize would lose a session (last-write-wins over a
    /// stale in-memory copy). A `tokio::sync::Mutex` (not `parking_lot`) so the
    /// guard is `Send` and may be held across the `spawn_blocking` / network
    /// `.await`s inside those critical sections. One global lock (not per-note):
    /// manifest writes are rare and sub-millisecond, so the contention cost is
    /// nil and a single lock is impossible to mis-key.
    pub manifest_lock: Arc<tokio::sync::Mutex<()>>,
    /// Per-note re-entrancy guard for cross-session speaker unification
    /// (`unify_note_speakers`). Auto-unify in the post-stop chain can race a
    /// user-triggered `rediarize_note` (or two rapid Re-diarize clicks) for the
    /// *same* note; without serialization both passes clobber each other's
    /// scratch WAVs and session timelines. Each note gets its own
    /// `tokio::sync::Mutex` so a second unify for that note waits for the first,
    /// while different notes stay fully concurrent. Held only inside
    /// `unify_note_speakers` (a leaf — never across another unify), so it can't
    /// deadlock the post-stop chain.
    pub unify_locks: Arc<Mutex<std::collections::HashMap<String, Arc<tokio::sync::Mutex<()>>>>>,
}

/// Start a recording from the rashek:// trigger (URL scheme or tray "New
/// Recording"), driven entirely from Rust. The frontend deliberately does NOT
/// create the note or start recording anymore: as a menu-bar / accessory app,
/// rashek often has no live webview to receive an emitted event, so the
/// create-note+record flow can't depend on one. We create the note, kick off
/// `recording_start`, and — for the case where a window IS open — show it and
/// emit "rashek-open-note" so the UI navigates to the new note.
pub(crate) fn trigger_record(app: &tauri::AppHandle) {
    // Ignore a re-fire while a recording is already live. macOS can deliver the
    // same deep-link twice, and the tray item can be double-clicked; without
    // this guard a second trigger creates a fresh note and `recording_start`'s
    // self-heal SIGTERMs the first sidecar — silently killing the recording the
    // user just started. If a window exists, surface it instead.
    if app.state::<AppState>().recording.lock().note_id.is_some() {
        eprintln!("rashek trigger: already recording — ignoring re-fire");
        if let Some(w) = app.get_webview_window("main") {
            let _ = w.show();
            let _ = w.set_focus();
        }
        return;
    }
    let note = match commands::notes_create(app.state::<AppState>()) {
        Ok(n) => n,
        Err(e) => {
            eprintln!("rashek trigger: notes_create failed: {}", e);
            return;
        }
    };
    let note_id = note.id.clone();
    // Reflect in a live UI if one exists (harmless no-op when headless).
    if let Some(w) = app.get_webview_window("main") {
        let _ = w.show();
        let _ = w.set_focus();
    }
    let _ = app.emit("rashek-open-note", note_id.clone());
    let app2 = app.clone();
    tauri::async_runtime::spawn(async move {
        let state = app2.state::<AppState>();
        if let Err(e) = commands::recording_start(app2.clone(), state, note_id).await {
            eprintln!("rashek trigger: recording_start failed: {}", e);
        }
    });
}

/// Stop the active recording from the rashek://stop trigger, driven from Rust
/// for the same reason as [`trigger_record`]. `recording_stop` is the authority
/// on whether anything is actually recording.
fn trigger_stop(app: &tauri::AppHandle) {
    let app2 = app.clone();
    tauri::async_runtime::spawn(async move {
        let state = app2.state::<AppState>();
        if let Err(e) = commands::recording_stop(app2.clone(), state).await {
            eprintln!("rashek trigger: recording_stop failed: {}", e);
        }
    });
}

/// Watch the default mic for use (a meeting app grabbing it) via the sidecar's
/// permission-free `watch-mic` mode, and float the meeting prompt on the
/// idle→active edge when rashek isn't already recording. Restarts the watcher if
/// it ever dies. This is the problem-5 detector.
fn start_mic_watch(app: &tauri::AppHandle) {
    use tauri::Manager;
    let app = app.clone();
    tauri::async_runtime::spawn(async move {
        use tokio::io::AsyncBufReadExt;
        let path = match commands::sidecar_path(&app) {
            Ok(p) => p,
            Err(e) => {
                eprintln!("mic-watch: sidecar path: {e}");
                return;
            }
        };
        loop {
            let mut child = match tokio::process::Command::new(&path)
                .arg("watch-mic")
                .stdout(std::process::Stdio::piped())
                .stderr(std::process::Stdio::null())
                .kill_on_drop(true)
                .spawn()
            {
                Ok(c) => c,
                Err(e) => {
                    eprintln!("mic-watch: spawn: {e}");
                    return;
                }
            };
            let stdout = match child.stdout.take() {
                Some(s) => s,
                None => return,
            };
            let mut lines = tokio::io::BufReader::new(stdout).lines();
            while let Ok(Some(line)) = lines.next_line().await {
                eprintln!("mic-watch: read {line}");
                if line.contains("\"state\":\"active\"") {
                    let already_recording = {
                        let st = app.state::<AppState>();
                        let r = st.recording.lock().note_id.is_some();
                        r
                    };
                    eprintln!("mic-watch: active — recording={already_recording} → {}", if already_recording { "skip" } else { "FIRE" });
                    if !already_recording {
                        let a = app.clone();
                        let _ = app.run_on_main_thread(move || show_meeting_prompt(&a));
                    }
                }
            }
            eprintln!("mic-watch: watcher exited; restarting in 2s");
            tokio::time::sleep(std::time::Duration::from_secs(2)).await;
        }
    });
}

/// Show the floating meeting prompt, positioned top-right of the primary
/// display. Must be called on the main thread (window ops).
pub(crate) fn show_meeting_prompt(app: &tauri::AppHandle) {
    use tauri::{Manager, PhysicalPosition};
    if let Some(w) = app.get_webview_window("meeting-prompt") {
        if let Ok(Some(mon)) = w.primary_monitor() {
            let sz = mon.size();
            let scale = mon.scale_factor();
            let win_w = (380.0 * scale) as i32;
            let margin = (8.0 * scale) as i32;
            let top = (36.0 * scale) as i32; // clear the menu bar
            let x = sz.width as i32 - win_w - margin;
            let _ = w.set_position(PhysicalPosition::new(x, top));
        }
        let _ = w.set_visible_on_all_workspaces(true);
        let _ = w.show();
        let _ = w.set_always_on_top(true);
        // Tell the card to (re)arm its silent auto-dismiss for THIS show.
        use tauri::Emitter;
        let _ = w.emit("meeting-prompt-show", ());
    }
}

/// "Take notes" tapped on the floating prompt → hide it and start recording.
#[tauri::command]
fn meeting_prompt_accept(app: tauri::AppHandle) {
    use tauri::Manager;
    if let Some(w) = app.get_webview_window("meeting-prompt") {
        let _ = w.hide();
    }
    trigger_record(&app);
}

/// Prompt ignored or timed out → just hide it.
#[tauri::command]
fn meeting_prompt_dismiss(app: tauri::AppHandle) {
    use tauri::Manager;
    if let Some(w) = app.get_webview_window("meeting-prompt") {
        let _ = w.hide();
    }
}

/// Position the recording indicator top-right of the primary display with an
/// initial size. The frontend measures the pill and calls `indicator_resize` to
/// fit it exactly, so this size is just a starting point (avoids a first-frame
/// clip before the measure lands).
fn place_indicator(w: &tauri::WebviewWindow) {
    use tauri::{LogicalSize, PhysicalPosition};
    let (lw, lh) = (210.0, 54.0);
    let _ = w.set_size(LogicalSize::new(lw, lh));
    if let Ok(Some(mon)) = w.primary_monitor() {
        let sz = mon.size();
        let scale = mon.scale_factor();
        let pw = (lw * scale) as i32;
        let margin = (10.0 * scale) as i32;
        let top = (36.0 * scale) as i32; // clear the menu bar
        let x = sz.width as i32 - pw - margin;
        let _ = w.set_position(PhysicalPosition::new(x, top));
    }
}

/// Show or hide the recording indicator. Safe to call from any thread — window
/// work is dispatched to the main thread.
pub(crate) fn set_recording_indicator(app: &tauri::AppHandle, show: bool) {
    let app = app.clone();
    let _ = app.clone().run_on_main_thread(move || {
        use tauri::{Emitter, Manager};
        if let Some(w) = app.get_webview_window("recording-indicator") {
            if show {
                place_indicator(&w);
                // Follow the user across Spaces / full-screen apps (three-finger
                // swipe), like Granola — the pill stays put instead of vanishing.
                let _ = w.set_visible_on_all_workspaces(true);
                let _ = w.show();
                let _ = w.set_always_on_top(true);
                let _ = w.emit("recording-indicator-show", ());
            } else {
                let _ = w.hide();
            }
        }
    });
}

/// Resize the indicator window to exactly fit the pill the frontend measured
/// (width/height in logical px). Keeps the RIGHT edge fixed at the window's
/// CURRENT position, so it never clips AND survives the user dragging the pill.
#[tauri::command]
fn indicator_resize(app: tauri::AppHandle, w: f64, h: f64) {
    use tauri::{LogicalSize, Manager, PhysicalPosition};
    if let Some(win) = app.get_webview_window("recording-indicator") {
        let scale = win.scale_factor().unwrap_or(2.0);
        let old_pos = win.outer_position().ok();
        let old_size = win.outer_size().ok();
        let _ = win.set_size(LogicalSize::new(w.max(60.0), h.max(30.0)));
        if let (Some(pos), Some(osz)) = (old_pos, old_size) {
            let new_w_px = (w * scale).round() as i32;
            let right = pos.x + osz.width as i32;
            let _ = win.set_position(PhysicalPosition::new(right - new_w_px, pos.y));
        }
    }
}

#[cfg_attr(mobile, tauri::mobile_entry_point)]
pub fn run() {
    // With the `cloud` feature (default), install the live cloud-sync observer:
    // it starts the worker once configured + signed in and restarts it on
    // login / workspace switch. Without the feature, sync is a no-op and the
    // app never touches the network for sync.
    #[cfg(feature = "cloud")]
    run_with_sync(commands::cloud_worker::install);

    #[cfg(not(feature = "cloud"))]
    run_with_sync(|_ctx| Arc::new(sync::NoopSync));
}

/// Entry point that lets a caller inject a sync implementation. `make_sync`
/// receives a [`sync::SyncContext`] (database handle + `AppHandle`) the moment
/// those exist during setup, and returns the observer to install on
/// [`AppState`]. The open-source [`run`] passes a factory that yields
/// [`sync::NoopSync`].
pub fn run_with_sync<F>(make_sync: F)
where
    F: FnOnce(sync::SyncContext) -> Arc<dyn sync::SyncObserver> + Send + 'static,
{
    tauri::Builder::default()
        .plugin(tauri_plugin_process::init())
        .plugin(tauri_plugin_shell::init())
        .plugin(tauri_plugin_dialog::init())
        .plugin(tauri_plugin_deep_link::init())
        .setup(move |app| {
            // rashek:// URL-scheme trigger (problem 5). `rashek://record` and
            // `rashek://stop` arrive here; forward each to the frontend, which
            // runs the create-note+record / stop flow. At runtime also register
            // the scheme so `open rashek://...` reaches a running instance.
            {
                use tauri_plugin_deep_link::DeepLinkExt;
                let handle = app.handle().clone();
                let _ = app.deep_link().register("rashek");
                app.deep_link().on_open_url(move |event| {
                    for url in event.urls() {
                        let s = url.to_string();
                        eprintln!("rashek deep-link: {}", s);
                        let lower = s.to_lowercase();
                        // Drive record/stop from RUST (see trigger_record): a
                        // menu-bar app may have no live webview to handle an
                        // emitted event, so we must not route the actual work
                        // through the frontend.
                        if lower.contains("record") {
                            trigger_record(&handle);
                        } else if lower.contains("stop") {
                            trigger_stop(&handle);
                        }
                    }
                });
            }
            // Problem 6: run as a menu-bar / background app. Accessory policy
            // removes the Dock icon; a tray icon provides access. The window
            // hides instead of quitting (RunEvent below), so rashek stays
            // resident — which is exactly the stable, always-running condition
            // the rashek:// trigger needs to fire reliably.
            #[cfg(target_os = "macos")]
            let _ = app.set_activation_policy(tauri::ActivationPolicy::Accessory);
            {
                use tauri::menu::{MenuBuilder, MenuItemBuilder};
                use tauri::tray::TrayIconBuilder;
                use tauri::{Emitter, Manager};
                let show = MenuItemBuilder::with_id("show", "Open rashek.humla").build(app)?;
                let record = MenuItemBuilder::with_id("record", "New Recording").build(app)?;
                let quit = MenuItemBuilder::with_id("quit", "Quit").build(app)?;
                let menu = MenuBuilder::new(app).items(&[&show, &record, &quit]).build()?;
                // Menu-bar glyph: the Lucide Lab bee (Humla = Norwegian for
                // bumblebee), rendered as a monochrome template so macOS inverts
                // it for the light/dark menu bar.
                let bee = tauri::image::Image::from_bytes(include_bytes!("../icons/tray-bee.png"))?;
                let _tray = TrayIconBuilder::with_id("rashek-tray")
                    .icon(bee)
                    .icon_as_template(true)
                    .tooltip("rashek.humla")
                    .menu(&menu)
                    .on_menu_event(move |app, event| match event.id().as_ref() {
                        "show" => {
                            if let Some(w) = app.get_webview_window("main") {
                                let _ = w.show();
                                let _ = w.set_focus();
                            }
                        }
                        "record" => {
                            trigger_record(app);
                        }
                        "quit" => app.exit(0),
                        _ => {}
                    })
                    .build(app)?;
            }
            // Floating meeting-prompt window (problem 5): a borderless,
            // transparent, always-on-top, non-activating panel the mic-watch
            // detector shows to offer recording. Built hidden so a later show is
            // instant. It's a plain window — NOT a system notification — so it
            // ignores Focus/Do-Not-Disturb and draws its own countdown, the way
            // Granola does. The frontend renders only the prompt card in the
            // window labelled "meeting-prompt" (see main.tsx).
            {
                use tauri::{WebviewUrl, WebviewWindowBuilder};
                let _prompt = WebviewWindowBuilder::new(
                    app,
                    "meeting-prompt",
                    WebviewUrl::App("index.html".into()),
                )
                .title("rashek meeting prompt")
                .inner_size(380.0, 150.0)
                .decorations(false)
                .transparent(true)
                .shadow(false) // kill the macOS window shadow — the card draws its own
                .always_on_top(true)
                .resizable(false)
                .skip_taskbar(true)
                .focused(false)
                .visible(false)
                .build()?;

                // Mic-watch detector (problem 5): float the prompt when a
                // meeting grabs the mic and rashek isn't already recording.
                start_mic_watch(&app.handle().clone());
            }
            // Floating recording indicator (problem 5 / OI-236): a borderless,
            // always-on-top pill shown WHILE recording, so the capture is
            // visible without opening the main window. Built hidden; shown on
            // record-start, hidden on idle (see commands.rs recording lifecycle).
            {
                use tauri::{WebviewUrl, WebviewWindowBuilder};
                let _ind = WebviewWindowBuilder::new(
                    app,
                    "recording-indicator",
                    WebviewUrl::App("index.html".into()),
                )
                .title("rashek recording")
                .inner_size(210.0, 54.0)
                .decorations(false)
                .transparent(true)
                .shadow(false)
                .always_on_top(true)
                .resizable(false)
                .skip_taskbar(true)
                .focused(false)
                .visible(false)
                .build()?;
            }
            // Point GGML at our prebuilt default.metallib BEFORE any
            // whisper.cpp init runs. whisper-rs 0.13 ships a vendored
            // ggml whose runtime Metal-source compile path silently
            // breaks on some macOS setups (whisper.cpp#3009 — sed-
            // based ggml-common.h embed misfires under cmake), causing
            // shader compile to fail with `undeclared identifier
            // 'block_q5_1'` and falling back to BLAS (CPU). With
            // GGML_METAL_PATH_RESOURCES set to a directory containing
            // a precompiled `default.metallib`, GGML's loader uses
            // that instead and skips the broken source path entirely
            // — restoring full Metal GPU acceleration.
            //
            // Tauri's bundle config maps `resources/default.metallib`
            // to <Resources>/default.metallib in production, but in
            // dev mode the path layout is different — try a couple
            // of plausible locations and log whichever wins so a
            // missing metallib is visible in stderr instead of just
            // silently degrading to BLAS.
            if let Ok(resource_dir) = app.path().resource_dir() {
                let candidates = [
                    resource_dir.clone(),
                    resource_dir.join("resources"),
                    resource_dir.join("Resources"),
                ];
                let found = candidates
                    .iter()
                    .find(|p| p.join("default.metallib").exists())
                    .cloned();
                match found {
                    Some(dir) => {
                        eprintln!(
                            "ggml metal: GGML_METAL_PATH_RESOURCES={}",
                            dir.display()
                        );
                        std::env::set_var("GGML_METAL_PATH_RESOURCES", &dir);
                    }
                    None => {
                        eprintln!(
                            "ggml metal: default.metallib not found near {} — Metal will try runtime shader compile and likely fall back to BLAS (CPU). Tried: {}",
                            resource_dir.display(),
                            candidates.iter().map(|p| p.display().to_string()).collect::<Vec<_>>().join(", "),
                        );
                    }
                }
            }

            let app_dir = app
                .path()
                .app_data_dir()
                .expect("app data dir");
            std::fs::create_dir_all(&app_dir).ok();
            let db_path = app_dir.join("notes.sqlite");
            let conn = db::open(&db_path).expect("open db");
            let db = Arc::new(Mutex::new(conn));
            // Build the sync observer now that the db handle and AppHandle
            // exist. In the open-source build this is `NoopSync` and the
            // factory ignores the context.
            let sync = make_sync(sync::SyncContext {
                db: db.clone(),
                app: app.handle().clone(),
            });
            app.manage(AppState {
                db,
                recording: Arc::new(Mutex::new(recording::LiveCapture::default())),
                whisper: local_whisper::new_shared(),
                transcribe_gate: Arc::new(tokio::sync::Mutex::new(())),
                api_key_cache: stt::new_cache(),
                sync,
                manifest_lock: Arc::new(tokio::sync::Mutex::new(())),
                unify_locks: Arc::new(Mutex::new(std::collections::HashMap::new())),
            });

            let menu = build_menu(app.handle())?;
            app.set_menu(menu)?;
            app.on_menu_event(|app, event| {
                if event.id().as_ref() == "check-for-updates" {
                    let _ = app.emit("menu://check-for-updates", ());
                }
            });

            // One-shot cleanup of pre-v0.8.0 streaming diarizer files
            // (pyannote_segmentation.mlmodelc + wespeaker_v2.mlmodelc).
            // Replaced by the community-1 offline set in v0.8.0 — same dir,
            // different filenames, so the old files would otherwise sit
            // there forever as dead weight. Gated on a settings flag so
            // this only runs once per install, never re-deleting files
            // upstream might legitimately reintroduce later.
            {
                let state: tauri::State<AppState> = app.state();
                let conn = state.db.lock();
                diarize::cleanup_legacy_streaming_models(app.handle(), &conn);
            }

            // One-shot migration of the legacy single-custom-prompt setting
            // into the summary_prompts table. Same flag-guarded shape as the
            // diarize cleanup above.
            {
                let state: tauri::State<AppState> = app.state();
                let conn = state.db.lock();
                if let Err(e) = db::migrate_summary_prompts(&conn) {
                    eprintln!("migrate_summary_prompts: {e}");
                }
            }

            // v0.23 — collapse the legacy flat transcription settings keys
            // into the typed `transcribe_config` JSON and delete the orphan
            // rows. Same flag-guarded shape as the migrations above. Safe to
            // ship indefinitely; the flag check makes it a no-op after
            // first run.
            {
                let state: tauri::State<AppState> = app.state();
                let conn = state.db.lock();
                if let Err(e) = db::migrate_transcribe_config(&conn) {
                    eprintln!("migrate_transcribe_config: {e}");
                }
            }

            // v0.24 — wrap the v0.23 bare-ProviderConfig transcribe_config row
            // into the new TranscribeConfig { default, per_language } shape.
            // Idempotent via parse check; runs after migrate_transcribe_config
            // so v0.21 → v0.24 users get both legacy collapse AND wrap in one
            // launch.
            {
                let state: tauri::State<AppState> = app.state();
                let conn = state.db.lock();
                if let Err(e) = db::migrate_per_language_v4(&conn) {
                    eprintln!("migrate_per_language_v4: {e}");
                }
            }

            // v0.31 — grandfather existing installs past the new first-run
            // onboarding wizard. Marks `onboarding_completed=true` when the DB
            // has notes or a local Whisper model is present on disk, so nobody
            // already using Humla ever sees the wizard. Deliberately does NOT
            // read the Keychain (a startup Keychain read can trigger a macOS
            // prompt). Idempotent via the presence of the setting.
            {
                let state: tauri::State<AppState> = app.state();
                let conn = state.db.lock();
                if let Err(e) =
                    db::migrate_grandfather_onboarding(&conn, &app_dir.join("models"))
                {
                    eprintln!("migrate_grandfather_onboarding: {e}");
                }
            }

            Ok(())
        })
        .invoke_handler(tauri::generate_handler![
            meeting_prompt_accept,
            meeting_prompt_dismiss,
            indicator_resize,
            commands::notes_list,
            commands::notes_get,
            commands::notes_create,
            commands::notes_update,
            commands::notes_delete,
            commands::notes_move,
            commands::notes_set_workspace,
            commands::notes_list_trash,
            commands::notes_restore,
            commands::notes_purge,
            commands::notes_revisions,
            commands::notes_restore_revision,
            commands::folders_list,
            commands::folders_create,
            commands::folders_rename,
            commands::folders_delete,
            commands::settings_get,
            commands::settings_set,
            commands::cloud_status,
            commands::cloud_configure,
            commands::cloud_login,
            commands::cloud_signup,
            commands::cloud_resend_verification,
            commands::cloud_request_password_reset,
            commands::cloud_logout,
            commands::cloud_create_workspace,
            commands::cloud_select_workspace,
            commands::cloud_rename_workspace,
            commands::cloud_delete_workspace,
            commands::cloud_leave_workspace,
            commands::cloud_transfer_workspace,
            commands::cloud_workspace_members,
            commands::cloud_pending_note_ids,
            commands::cloud_upload_note_audio,
            commands::cloud_download_note_audio,
            commands::cloud_upload_note_sessions,
            commands::cloud_download_note_sessions,
            commands::cloud_note_recording_status,
            commands::cloud_add_member,
            commands::cloud_invite_member,
            commands::cloud_remove_member,
            commands::cloud_set_member_role,
            commands::cloud_billing_checkout,
            commands::cloud_billing_portal,
            commands::app_data_dir,
            commands::system_arch,
            commands::note_diagnostics_dir,
            commands::note_audio_dir,
            commands::note_audio_files,
            commands::note_diagnostics_files,
            commands::note_playback_path,
            commands::note_sessions,
            commands::note_session_playback_path,
            commands::note_timeline,
            commands::note_timeline_rename,
            commands::note_timeline_set_chunk_label,
            commands::note_timeline_delete_chunk,
            commands::open_in_finder,
            commands::export_note,
            commands::rediarize_note,
            commands::summary_prompts_list,
            commands::summary_prompts_create,
            commands::summary_prompts_update,
            commands::summary_prompts_delete,
            commands::get_transcribe_config,
            commands::set_transcribe_config,
            commands::provider_key_get,
            commands::provider_key_set,
            commands::provider_key_test,
            commands::local_whisper_models,
            commands::local_whisper_download,
            commands::local_whisper_delete,
            commands::local_llm_list_models,
            commands::diarize_status,
            commands::diarize_download,
            commands::diarize_delete,
            commands::recording_start,
            commands::recording_stop,
            commands::import_audio,
            commands::recording_pause,
            commands::recording_resume,
            commands::recording_state,
            commands::summarize_note,
            commands::permissions_status,
            commands::permissions_request,
            commands::permissions_open_settings,
        ])
        .build(tauri::generate_context!())
        .expect("error while building tauri app")
        .run(|app_handle, event| {
            use tauri::Manager;
            // Window close hides instead of quitting, so rashek stays resident
            // in the menu bar (problem 6). Quit is via the tray's Quit item.
            if let tauri::RunEvent::WindowEvent {
                label,
                event: tauri::WindowEvent::CloseRequested { api, .. },
                ..
            } = &event
            {
                api.prevent_close();
                if let Some(w) = app_handle.get_webview_window(label) {
                    let _ = w.hide();
                }
            }
            // Bypass C++ static destructors on quit. whisper.cpp's GGML
            // Metal backend dispatches a background block during init that
            // polls via usleep; on app exit, the unique_ptr<ggml_metal_device>
            // destructor (called from atexit via __cxa_finalize_ranges)
            // runs ggml_metal_rsets_free, which aborts when those rsets are
            // still owned by the in-flight init block. Result: every
            // Cmd+Q after a recording reliably crashes inside ggml_abort
            // and produces a SIGABRT crash dialog. We don't actually need
            // C++ destructors to run at exit — the OS reclaims Metal
            // resources, file descriptors, and process memory anyway, and
            // our DB writes are synced before this point. _exit(0) skips
            // atexit entirely and lets the process terminate cleanly.
            if let tauri::RunEvent::Exit = event {
                unsafe { libc::_exit(0) };
            }
        });
}

fn build_menu(app: &tauri::AppHandle) -> tauri::Result<Menu<tauri::Wry>> {
    let app_name = app
        .config()
        .product_name
        .clone()
        .unwrap_or_else(|| "Humla".to_string());

    let about = PredefinedMenuItem::about(app, None, None)?;
    let check_for_updates = MenuItem::with_id(
        app,
        "check-for-updates",
        "Check for Updates…",
        true,
        None::<&str>,
    )?;
    let services = PredefinedMenuItem::services(app, None)?;
    let hide = PredefinedMenuItem::hide(app, None)?;
    let hide_others = PredefinedMenuItem::hide_others(app, None)?;
    let show_all = PredefinedMenuItem::show_all(app, None)?;
    let quit = PredefinedMenuItem::quit(app, None)?;
    let sep = || PredefinedMenuItem::separator(app);

    let app_submenu = Submenu::with_items(
        app,
        &app_name,
        true,
        &[
            &about,
            &sep()?,
            &check_for_updates,
            &sep()?,
            &services,
            &sep()?,
            &hide,
            &hide_others,
            &show_all,
            &sep()?,
            &quit,
        ],
    )?;

    let edit_submenu = Submenu::with_items(
        app,
        "Edit",
        true,
        &[
            &PredefinedMenuItem::undo(app, None)?,
            &PredefinedMenuItem::redo(app, None)?,
            &sep()?,
            &PredefinedMenuItem::cut(app, None)?,
            &PredefinedMenuItem::copy(app, None)?,
            &PredefinedMenuItem::paste(app, None)?,
            &PredefinedMenuItem::select_all(app, None)?,
        ],
    )?;

    let window_submenu = Submenu::with_items(
        app,
        "Window",
        true,
        &[
            &PredefinedMenuItem::minimize(app, None)?,
            &PredefinedMenuItem::close_window(app, None)?,
        ],
    )?;

    Menu::with_items(app, &[&app_submenu, &edit_submenu, &window_submenu])
}
