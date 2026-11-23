//! macOS TCC permission commands (microphone + screen recording). Query
//! / request via the audio-capture sidecar, plus a deep-link into System
//! Settings. Surfaced to the frontend via `commands::permissions_*`
//! (re-exported from the parent module). `run_sidecar_cmd` reaches the
//! sidecar binary path via `super::sidecar_path`, which stays in the
//! parent module alongside the recording lifecycle.

use std::process::Stdio;
use tauri::AppHandle;

#[derive(serde::Serialize, serde::Deserialize, Default)]
pub struct PermissionsStatus {
    pub microphone: String,
    pub screen: String,
}

async fn run_sidecar_cmd(app: &AppHandle, mode: &str) -> Result<String, String> {
    let path = super::sidecar_path(app)?;
    let mut cmd = tokio::process::Command::new(&path);
    cmd.arg(mode)
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .kill_on_drop(true);
    // Detach into a new session so macOS TCC attributes the mic / screen
    // authorization to the SIDECAR's own binary identity — the SAME identity
    // `recording_start` records under (it also setsid's the sidecar). Without
    // this, status and request ran under humla's identity while recording ran
    // under the sidecar's, so a granted permission was never seen by the
    // recorder — the "Microphone permission required" dead end.
    #[cfg(unix)]
    unsafe {
        cmd.pre_exec(|| {
            let _ = libc::setsid();
            Ok(())
        });
    }
    let mut child = cmd.spawn().map_err(|e| format!("spawn: {e}"))?;
    // A `request-*` prompt blocks on the user's click — give it room. `status`
    // is instant.
    let secs = if mode.starts_with("request") { 120 } else { 3 };
    let fut = child.wait_with_output();
    match tokio::time::timeout(std::time::Duration::from_secs(secs), fut).await {
        Ok(Ok(out)) => Ok(String::from_utf8_lossy(&out.stdout).to_string()),
        Ok(Err(e)) => Err(format!("read: {e}")),
        Err(_) => Err("sidecar timed out".into()),
    }
}

#[tauri::command]
pub async fn permissions_status(app: AppHandle) -> Result<PermissionsStatus, String> {
    let stdout = run_sidecar_cmd(&app, "status").await?;
    let line = stdout.lines().last().unwrap_or("");
    serde_json::from_str(line).map_err(|e| format!("parse: {e}: {line}"))
}

#[tauri::command]
pub async fn permissions_request(app: AppHandle, kind: String) -> Result<PermissionsStatus, String> {
    let mode = match kind.as_str() {
        "microphone" => "request-microphone",
        "screen" => "request-screen",
        _ => return Err("unknown kind".into()),
    };
    let _ = run_sidecar_cmd(&app, mode).await; // result ignored; we re-query
    permissions_status(app).await
}

#[tauri::command]
pub async fn permissions_open_settings(kind: String) -> Result<(), String> {
    let url = match kind.as_str() {
        "microphone" => "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone",
        "screen" => "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture",
        _ => return Err("unknown kind".into()),
    };
    tokio::process::Command::new("open")
        .arg(url)
        .spawn()
        .map_err(|e| format!("open: {e}"))?
        .wait()
        .await
        .map_err(|e| e.to_string())?;
    Ok(())
}
