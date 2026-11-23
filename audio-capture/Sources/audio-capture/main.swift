import Foundation
import AppKit
import AVFoundation
import CoreAudio
import CoreMedia
import CoreGraphics

// Hide the sidecar from the Dock and menu bar. ScreenCaptureKit and
// AVAudioEngine pull in AppKit transitively, which by default registers the
// process as a regular foreground app (Dock icon, menu bar). `.prohibited`
// makes it a true background helper. Must run before any AppKit API touches
// process activation state, so it goes at the top of main.
NSApplication.shared.setActivationPolicy(.prohibited)

// MARK: - Mode dispatch

let allArgs = CommandLine.arguments

func micStatusString() -> String {
    switch AVCaptureDevice.authorizationStatus(for: .audio) {
    case .authorized: return "granted"
    case .denied: return "denied"
    case .restricted: return "restricted"
    case .notDetermined: return "not_determined"
    @unknown default: return "unknown"
    }
}

func screenStatusString() -> String {
    // Screen Recording is no longer used: system audio is captured via a Core
    // Audio process tap (see SystemAudioTap), which macOS gates behind the
    // narrower "System Audio Recording Only" grant and auto-prompts for on
    // first tap use. Report "granted" so the app never surfaces a Screen
    // Recording request or "mic only" warning — the screen permission is
    // vestigial in this fork.
    return "granted"
}

func printJSON(_ obj: [String: Any]) {
    if let data = try? JSONSerialization.data(withJSONObject: obj),
       let s = String(data: data, encoding: .utf8) {
        print(s)
        fflush(stdout)
    }
}

// MARK: - Mic-in-use detection (watch-mic mode, problem 5)
//
// `kAudioDevicePropertyDeviceIsRunningSomewhere` tells us whether ANY process is
// currently capturing the default input — i.e. a meeting app grabbed the mic.
// Reading it needs NO microphone permission (it's a device-state query, not
// capture), so the watcher is a permission-free background poll.
func defaultInputDevice() -> AudioDeviceID? {
    var id = AudioDeviceID(0)
    var sz = UInt32(MemoryLayout<AudioDeviceID>.size)
    var addr = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDefaultInputDevice,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain)
    let st = AudioObjectGetPropertyData(
        AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &sz, &id)
    return st == noErr ? id : nil
}

func micInUse(_ dev: AudioDeviceID) -> Bool {
    var running = UInt32(0)
    var sz = UInt32(MemoryLayout<UInt32>.size)
    var addr = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyDeviceIsRunningSomewhere,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain)
    let st = AudioObjectGetPropertyData(dev, &addr, 0, nil, &sz, &running)
    return st == noErr && running != 0
}

// Per-process audio state (macOS 14.4+). The device-level "is running" flag
// can't tell a meeting from dictation (the default output reads "running" even
// when nothing's playing). But a single PROCESS running BOTH input and output is
// a two-way call — a meeting. Mic-only (dictation: Willow, Voice Memos) is not,
// and audio-only playback (a browser tab) is not. This is the meeting signal.
func procRunning(_ obj: AudioObjectID, _ sel: AudioObjectPropertySelector) -> Bool {
    var a = AudioObjectPropertyAddress(
        mSelector: sel, mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain)
    var v = UInt32(0)
    var sz = UInt32(MemoryLayout<UInt32>.size)
    return AudioObjectGetPropertyData(obj, &a, 0, nil, &sz, &v) == noErr && v != 0
}

func procBundleID(_ obj: AudioObjectID) -> String? {
    var a = AudioObjectPropertyAddress(
        mSelector: kAudioProcessPropertyBundleID,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain)
    var s: CFString? = nil
    var sz = UInt32(MemoryLayout<CFString?>.size)
    let st = withUnsafeMutablePointer(to: &s) {
        AudioObjectGetPropertyData(obj, &a, 0, nil, &sz, $0)
    }
    guard st == noErr, let s else { return nil }
    let id = s as String
    return id.isEmpty ? nil : id
}

// Apps that legitimately hold input AND output at once without being a meeting.
// A DAW monitors its input through its output the whole time it's open, so the
// two-way-call signal above fires on launch and never clears — a permanent
// false positive rather than a transient one. Excluded by bundle ID; add a line
// here for any other app that trips the detector.
let meetingIgnoredBundleIDs: Set<String> = [
    "com.apple.logic10",      // Logic Pro
    "com.apple.garageband10", // GarageBand
    "com.apple.mainstage3",   // MainStage
]

func meetingInProgress() -> Bool {
    var addr = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyProcessObjectList,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain)
    var dataSize = UInt32(0)
    guard AudioObjectGetPropertyDataSize(
        AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &dataSize) == noErr,
        dataSize > 0 else { return false }
    let count = Int(dataSize) / MemoryLayout<AudioObjectID>.size
    var procs = [AudioObjectID](repeating: 0, count: count)
    guard AudioObjectGetPropertyData(
        AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &dataSize, &procs) == noErr
    else { return false }
    for p in procs where p != 0 {
        if procRunning(p, kAudioProcessPropertyIsRunningInput)
            && procRunning(p, kAudioProcessPropertyIsRunningOutput) {
            if let id = procBundleID(p), meetingIgnoredBundleIDs.contains(id) { continue }
            return true
        }
    }
    return false
}

if allArgs.count >= 2 {
    switch allArgs[1] {
    case "status":
        printJSON([
            "microphone": micStatusString(),
            "screen": screenStatusString(),
        ])
        exit(0)
    case "request-microphone":
        AVCaptureDevice.requestAccess(for: .audio) { granted in
            printJSON(["microphone": granted ? "granted" : "denied"])
            exit(granted ? 0 : 1)
        }
        RunLoop.main.run()
        exit(1) // unreachable
    case "request-screen":
        // CGRequestScreenCaptureAccess returns true if already granted; otherwise it adds
        // the app to the privacy pane and returns false. The user must enable it manually
        // and the app must be relaunched for the new permission to take effect.
        let ok = CGRequestScreenCaptureAccess()
        printJSON(["screen": ok ? "granted" : "denied"])
        exit(ok ? 0 : 1)
    case "watch-mic":
        // Emit one JSON line on each debounced idle↔active transition of the
        // mic, forever (until the parent kills us). The Rust side floats the
        // "meeting detected" card on "active" when rashek isn't recording.
        //
        // Debounce: only report "active" once the mic has been CONTINUOUSLY in
        // use for ACTIVE_POLLS samples (~4.5 s). A real meeting holds the mic;
        // a transient blip (a background app, a permission check, a launch-time
        // touch) does not — this kills the false-positive floats. "idle" is
        // reported immediately on release so the next meeting re-arms.
        let pollInterval = 1.5
        let activePolls = 3 // ~4.5 s of sustained use before we call it a meeting
        var reported = false // last state we told Rust about
        var activeStreak = 0
        while true {
            // A meeting = some process capturing mic AND playing audio (a
            // two-way call). Mic-only (dictation like Willow) is NOT a meeting.
            let inUse = meetingInProgress()
            if inUse {
                activeStreak += 1
                if !reported && activeStreak >= activePolls {
                    printJSON(["event": "mic", "state": "active"])
                    reported = true
                }
            } else {
                activeStreak = 0
                if reported {
                    printJSON(["event": "mic", "state": "idle"])
                    reported = false
                }
            }
            Thread.sleep(forTimeInterval: pollInterval)
        }
    default:
        break
    }
}

// MARK: - Args (recording mode)

var outDir = FileManager.default.temporaryDirectory
let args = CommandLine.arguments
if let i = args.firstIndex(of: "--out"), i + 1 < args.count {
    outDir = URL(fileURLWithPath: args[i + 1])
}
try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true, attributes: nil)

// Import mode: `--import <file>`. Instead of live-capturing mic + system audio,
// decode an existing file, resample it to the target format, and replay it
// through the SAME VAD ChunkWriter + FullRecordingWriter used for the mic
// stream — emitting the identical `chunk` / `full_recording` / `stopped`
// events. The Rust side then reuses its whole recording pipeline unchanged
// (transcribe fan-out → mic-only diarize). A one-shot replay: no AVAudioEngine,
// no ScreenCaptureKit, no heartbeat / pause / watchdog / signal handlers.
let importPath: String? = {
    guard let i = args.firstIndex(of: "--import"), i + 1 < args.count else { return nil }
    return args[i + 1]
}()
let isImport = importPath != nil

// The real PID of the humla process that spawned us, passed explicitly by the
// Rust side via `--parent-pid`. The watchdog below monitors THIS pid's liveness
// (kill(pid, 0)) rather than our PPID: setsid() detaches us, and under a
// LaunchServices-launched (menu-bar) parent macOS reparents us to launchd
// (PID 1) almost immediately while humla is still alive — so a PPID==1 test
// would wrongly kill an active recording. When absent (hand-launched), the
// watchdog falls back to the old PPID heuristic.
let parentPid: pid_t? = {
    guard let i = args.firstIndex(of: "--parent-pid"), i + 1 < args.count else { return nil }
    return pid_t(args[i + 1])
}()

// MARK: - JSON event emitter (stdout)

let stdoutLock = NSLock()
func emit(_ obj: [String: Any]) {
    guard let data = try? JSONSerialization.data(withJSONObject: obj),
          let line = String(data: data, encoding: .utf8) else { return }
    stdoutLock.lock()
    print(line)
    fflush(stdout)
    stdoutLock.unlock()
}

func emitError(_ msg: String) { emit(["event": "error", "message": msg]) }

// MARK: - Target format: 16 kHz mono Float32 (in memory) → Int16 WAV on disk

let targetSampleRate: Double = 16_000
let targetFormat = AVAudioFormat(
    commonFormat: .pcmFormatFloat32,
    sampleRate: targetSampleRate,
    channels: 1,
    interleaved: false
)!
let writeSettings: [String: Any] = [
    AVFormatIDKey: kAudioFormatLinearPCM,
    AVSampleRateKey: targetSampleRate,
    AVNumberOfChannelsKey: 1,
    AVLinearPCMBitDepthKey: 16,
    AVLinearPCMIsFloatKey: false,
    AVLinearPCMIsBigEndianKey: false,
]

// MARK: - Chunk writer (per source)

// One ChunkWriter per source (mic / sys). Each writes its own VAD-bounded
// chunk WAVs and tags every emitted event with the `source` so the Rust side
// can route transcribes and label the final transcript ("You" for mic, the
// diarized speaker IDs for system). Filenames are prefixed by source so the
// two writers can share the same temp dir without colliding.
final class ChunkWriter {
    private let source: String
    private let dir: URL
    private let minFrames: AVAudioFrameCount
    private let maxFrames: AVAudioFrameCount
    private let vadSilenceFrames: AVAudioFrameCount
    private let silenceThreshold: Float = 0.005   // chunk-level: below this we drop the chunk
    private let vadFrameThreshold: Float = 0.008  // per-buffer peak: above this counts as voice
    private var index: Int = 0
    private var file: AVAudioFile?
    private var url: URL?
    private var written: AVAudioFrameCount = 0
    private var chunkPeak: Float = 0
    private var silentRun: AVAudioFrameCount = 0
    // Decaying estimate of the recent SPEECH level, so "silence" is judged
    // relative to how loud you're actually talking rather than a fixed floor —
    // otherwise a noisy room never reads as a pause and every chunk runs to the
    // hard cap. A pause = the buffer drops well below this recent level.
    private var recentPeak: Float = 0
    // Total frames written across ALL chunks since the writer opened. Used
    // to compute each chunk's start_ms relative to this stream's t=0 (the
    // first frame this writer ever received). Each stream has its own
    // timeline; the offline diarize pass aligns chunks within their own
    // full.wav, so per-stream-relative is the right anchor.
    private var totalFramesWritten: AVAudioFrameCount = 0
    private var chunkStartFrames: AVAudioFrameCount = 0
    private let queue: DispatchQueue

    init(source: String, dir: URL, minSeconds: Double, maxSeconds: Double, vadSilenceMs: Double) {
        self.source = source
        self.dir = dir
        self.minFrames = AVAudioFrameCount(minSeconds * targetSampleRate)
        self.maxFrames = AVAudioFrameCount(maxSeconds * targetSampleRate)
        self.vadSilenceFrames = AVAudioFrameCount((vadSilenceMs / 1000.0) * targetSampleRate)
        self.queue = DispatchQueue(label: "chunk.writer.\(source)")
    }

    func write(_ buffer: AVAudioPCMBuffer) {
        queue.sync {
            do {
                if file == nil { try openNext() }
                try file!.write(from: buffer)
                written += buffer.frameLength
                totalFramesWritten += buffer.frameLength

                // Per-buffer peak feeds both the chunk-level peak (used for the
                // silence-drop on close) and the silent-run counter (used by
                // the VAD rotation trigger).
                var bufPeak: Float = 0
                if let chans = buffer.floatChannelData {
                    let n = Int(buffer.frameLength)
                    for i in 0..<n {
                        let v = abs(chans[0][i])
                        if v > bufPeak { bufPeak = v }
                    }
                }
                if bufPeak > chunkPeak { chunkPeak = bufPeak }
                // Adaptive pause detection. Track the recent speech level (fast
                // to rise, slow to decay) and treat a buffer as "silence" when it
                // falls well below it. The fixed vadFrameThreshold is only a
                // floor, so true quiet still counts even before any speech.
                recentPeak = max(bufPeak, recentPeak * 0.997)
                let silenceBar = max(vadFrameThreshold, recentPeak * 0.15)
                if bufPeak < silenceBar {
                    silentRun += buffer.frameLength
                } else {
                    silentRun = 0
                }

                // Rotate on whichever fires first:
                //  - hard cap (maxFrames) so a continuous monologue still gets
                //    transcribed periodically and the trailing-context prompt
                //    stays fresh on the consuming side.
                //  - VAD pause detected, but only after the chunk reached
                //    minFrames so we don't emit micro-chunks that lose context.
                let vadRotate = written >= minFrames && silentRun >= vadSilenceFrames
                if written >= maxFrames || vadRotate {
                    try rotate()
                }
            } catch {
                emitError("\(source) write: \(error.localizedDescription)")
            }
        }
    }

    func close() {
        queue.sync {
            if let u = url, written > 0 {
                file = nil
                if chunkPeak >= silenceThreshold {
                    let startMs = Int(Double(chunkStartFrames) / targetSampleRate * 1000.0)
                    emit([
                        "event": "chunk",
                        "source": source,
                        "path": u.path,
                        "start_ms": startMs,
                    ])
                    stats.lock.lock(); stats.chunks += 1; stats.lock.unlock()
                } else {
                    try? FileManager.default.removeItem(at: u)
                }
            }
            file = nil
            url = nil
            written = 0
            chunkPeak = 0
            silentRun = 0
        }
    }

    private func openNext() throws {
        index += 1
        let u = dir.appendingPathComponent(String(format: "%@-chunk-%04d.wav", source, index))
        url = u
        file = try AVAudioFile(forWriting: u, settings: writeSettings)
        written = 0
        chunkStartFrames = totalFramesWritten
    }

    private func rotate() throws {
        guard let u = url else { return }
        file = nil
        if chunkPeak >= silenceThreshold {
            let startMs = Int(Double(chunkStartFrames) / targetSampleRate * 1000.0)
            emit([
                "event": "chunk",
                "source": source,
                "path": u.path,
                "start_ms": startMs,
            ])
            stats.lock.lock(); stats.chunks += 1; stats.lock.unlock()
        } else {
            try? FileManager.default.removeItem(at: u)
        }
        chunkPeak = 0
        silentRun = 0
        try openNext()
    }
}

// Tuned to keep VAD as the primary boundary picker, with the max only as
// a safety net:
//   - minSeconds 1.0 lets short utterances flush quickly.
//   - maxSeconds 15.0 — high enough that an 8 s monologue doesn't cap
//     mid-word ("mistenkte" → "mistred"). Whisper actually transcribes
//     longer chunks more accurately because it sees more context, so we
//     prefer letting VAD pick the boundary even if that's a bit slower.
//   - vadSilenceMs 500 catches sentence-end pauses without triggering on
//     normal between-word stops (which are typically 100–300 ms).
// maxSeconds 4.0 (was 15): this hard cap is the RELIABLE bound on live-caption
// latency — a continuous talker gets a chunk flushed to Whisper every 4 s no
// matter what the pause-detector does. The adaptive VAD flushes sooner on real
// pauses; the cap guarantees the worst case. Shorter chunks cost a little
// Whisper context, but the cross-chunk trail carries prior text forward.
let micWriter = ChunkWriter(source: "mic", dir: outDir, minSeconds: 1.0, maxSeconds: 4.0, vadSilenceMs: 500.0)
let sysWriter = ChunkWriter(source: "sys", dir: outDir, minSeconds: 1.0, maxSeconds: 4.0, vadSilenceMs: 500.0)

// MARK: - Full-recording writer (per source)

// Parallel writer that captures every received frame into a single WAV for
// the duration of the recording. Each source gets its own full.wav (so the
// post-stop diarizer can treat them as independent streams: in-person calls
// produce only mic_full.wav and run multi-speaker diarize there; remote
// calls produce both files and run "mic = You, sys = diarize speakers").
// ~58 MB per 30-min meeting at 16 kHz mono 16-bit per source.
final class FullRecordingWriter {
    private let source: String
    private let dir: URL
    private var file: AVAudioFile?
    private var url: URL?
    private var written: AVAudioFrameCount = 0
    private let queue: DispatchQueue

    init(source: String, dir: URL) {
        self.source = source
        self.dir = dir
        self.queue = DispatchQueue(label: "full.writer.\(source)")
    }

    func write(_ buffer: AVAudioPCMBuffer) {
        queue.sync {
            do {
                if file == nil {
                    let u = dir.appendingPathComponent("\(source)-full.wav")
                    url = u
                    file = try AVAudioFile(forWriting: u, settings: writeSettings)
                }
                try file!.write(from: buffer)
                written += buffer.frameLength
            } catch {
                emitError("\(source) full write: \(error.localizedDescription)")
            }
        }
    }

    func close() {
        queue.sync {
            file = nil
            if let u = url, written > 0 {
                let durationMs = Int(Double(written) / targetSampleRate * 1000.0)
                emit([
                    "event": "full_recording",
                    "source": source,
                    "path": u.path,
                    "duration_ms": durationMs,
                ])
            }
            url = nil
            written = 0
        }
    }
}

let micFullWriter = FullRecordingWriter(source: "mic", dir: outDir)
let sysFullWriter = FullRecordingWriter(source: "sys", dir: outDir)

// MARK: - Stats (diagnostics)

final class Stats {
    let lock = NSLock()
    var micFrames: Int = 0
    var sysFrames: Int = 0
    var chunks: Int = 0
    var micPeak: Float = 0
    var sysPeak: Float = 0
    // Separate accumulator for the ~10Hz live-waveform level (max of mic + sys
    // since the last `level` emit). Kept apart from micPeak/sysPeak so the 2s
    // heartbeat's peak window isn't disturbed by the faster reset.
    var levelPeak: Float = 0
}
let stats = Stats()

func recordMicStats(samples: [Float]) {
    let peak = samples.reduce(0 as Float) { max($0, abs($1)) }
    stats.lock.lock()
    stats.micFrames += samples.count
    if peak > stats.micPeak { stats.micPeak = peak }
    if peak > stats.levelPeak { stats.levelPeak = peak }
    stats.lock.unlock()
}

func recordSysStats(samples: [Float]) {
    let peak = samples.reduce(0 as Float) { max($0, abs($1)) }
    stats.lock.lock()
    stats.sysFrames += samples.count
    if peak > stats.sysPeak { stats.sysPeak = peak }
    if peak > stats.levelPeak { stats.levelPeak = peak }
    stats.lock.unlock()
}

// Wrap a Float32 sample array into an AVAudioPCMBuffer for the writers. The
// writers expect mono Float32 at the target sample rate.
func makeBuffer(_ samples: [Float]) -> AVAudioPCMBuffer? {
    guard !samples.isEmpty,
          let buf = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: AVAudioFrameCount(samples.count)) else {
        return nil
    }
    buf.frameLength = AVAudioFrameCount(samples.count)
    if let chans = buf.floatChannelData {
        samples.withUnsafeBufferPointer { src in
            chans[0].update(from: src.baseAddress!, count: samples.count)
        }
    }
    return buf
}

// MARK: - Mic via AVAudioEngine

let engine = AVAudioEngine()
var micConverter: AVAudioConverter?

// Build the mic converter for `inFormat` and install the capture tap. Factored
// out so both initial setup and post-device-change recovery install an
// identical tap against whatever the current input format happens to be.
func installMicTap(_ input: AVAudioInputNode, format inFormat: AVAudioFormat) {
    micConverter = AVAudioConverter(from: inFormat, to: targetFormat)
    input.installTap(onBus: 0, bufferSize: 4096, format: inFormat) { buffer, _ in
        guard let conv = micConverter else { return }
        let ratio = targetSampleRate / inFormat.sampleRate
        let cap = AVAudioFrameCount(Double(buffer.frameLength) * ratio + 1024)
        guard let out = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: cap) else { return }
        var error: NSError?
        var supplied = false
        let status = conv.convert(to: out, error: &error) { _, status in
            if supplied {
                status.pointee = .noDataNow
                return nil
            }
            supplied = true
            status.pointee = .haveData
            return buffer
        }
        if status != .error, out.frameLength > 0,
           let chans = out.floatChannelData {
            let n = Int(out.frameLength)
            let arr = Array(UnsafeBufferPointer(start: chans[0], count: n))
            recordMicStats(samples: arr)
            if let buf = makeBuffer(arr) {
                micWriter.write(buf)
                micFullWriter.write(buf)
            }
        }
    }
}

if !isImport {
do {
    let input = engine.inputNode
    // NOTE: do NOT call `input.setVoiceProcessingEnabled(true)`. It enables
    // hardware AEC, but the voice-processing IO unit takes over the audio
    // device for *both* directions, which ducks the system output (you
    // can't hear the other person on a call). Echo-cancel the mic in a
    // post-stop dedup pass instead — see commands.rs.
    let inFormat = input.inputFormat(forBus: 0)
    if inFormat.sampleRate == 0 || inFormat.channelCount == 0 {
        emitError("Microphone input format invalid (sampleRate=\(inFormat.sampleRate), channels=\(inFormat.channelCount)). Dev binaries without an Info.plist may be silently denied audio. Try running 'pnpm tauri build --debug' and launching the .app instead of 'pnpm tauri dev'.")
        throw NSError(domain: "audio-capture", code: 1, userInfo: [NSLocalizedDescriptionKey: "invalid input format"])
    }
    installMicTap(input, format: inFormat)
    engine.prepare()
    try engine.start()
} catch {
    emitError("mic engine: \(error.localizedDescription)")
}
} // if !isImport

// MARK: - System audio via Core Audio process tap (macOS 14.4+)
//
// Replaces the old ScreenCaptureKit path. A Core Audio process tap captures
// system audio output WITHOUT the Screen Recording permission — macOS gates it
// behind the narrower "System Audio Recording Only" grant instead. We build a
// private aggregate device wrapping a global tap, install an IOProc, and feed
// the tapped frames (converted to 16 kHz mono Float32) into the SAME
// sysWriter / sysFullWriter as before, so the rest of the pipeline is unchanged.

final class SystemAudioTap {
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggID = AudioObjectID(kAudioObjectUnknown)
    private var ioProcID: AudioDeviceIOProcID?
    private var converter: AVAudioConverter?
    private var inFormat: AVAudioFormat?
    private var started = false
    private var bufferCount = 0
    private let ioQueue = DispatchQueue(label: "coreaudio.tap.io")

    func start() {
        guard !started else { return }

        // 1. Global tap of all process output (exclude none). Private to us,
        //    unmuted so the user still hears the call.
        let tapDesc = CATapDescription(stereoGlobalTapButExcludeProcesses: [])
        tapDesc.isPrivate = true
        tapDesc.muteBehavior = .unmuted
        tapDesc.name = "rashek.humla system tap"

        var tap = AudioObjectID(kAudioObjectUnknown)
        let tErr = AudioHardwareCreateProcessTap(tapDesc, &tap)
        guard tErr == noErr, tap != kAudioObjectUnknown else {
            emitError("process tap create failed: OSStatus \(tErr)")
            return
        }
        tapID = tap

        // 2. Query the tap's native stream format.
        var asbd = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        var fmtAddr = AudioObjectPropertyAddress(
            mSelector: kAudioTapPropertyFormat,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        let fErr = AudioObjectGetPropertyData(tapID, &fmtAddr, 0, nil, &size, &asbd)
        guard fErr == noErr, let inF = AVAudioFormat(streamDescription: &asbd) else {
            emitError("tap format query failed: OSStatus \(fErr)")
            return
        }
        inFormat = inF
        converter = AVAudioConverter(from: inF, to: targetFormat)
        FileHandle.standardError.write(Data("tap: format \(inF)\n".utf8))

        // 3. Private aggregate device wrapping the tap.
        let aggUID = "no.humla.rashek.agg.\(UUID().uuidString)"
        let aggDesc: [String: Any] = [
            kAudioAggregateDeviceNameKey: "rashek-tap",
            kAudioAggregateDeviceUIDKey: aggUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [[String: Any]](),
            kAudioAggregateDeviceTapListKey: [
                [
                    kAudioSubTapUIDKey: tapDesc.uuid.uuidString,
                    kAudioSubTapDriftCompensationKey: true,
                ]
            ],
        ]
        var agg = AudioObjectID(kAudioObjectUnknown)
        let aErr = AudioHardwareCreateAggregateDevice(aggDesc as CFDictionary, &agg)
        guard aErr == noErr, agg != kAudioObjectUnknown else {
            emitError("aggregate device create failed: OSStatus \(aErr)")
            return
        }
        aggID = agg

        // 4. IOProc: receive tapped frames, convert, feed the sys writers.
        let ioErr = AudioDeviceCreateIOProcIDWithBlock(&ioProcID, aggID, ioQueue) {
            [weak self] (_, inInputData, _, _, _) in
            self?.handle(inInputData)
        }
        guard ioErr == noErr, ioProcID != nil else {
            emitError("IOProc create failed: OSStatus \(ioErr)")
            return
        }

        // 5. Start.
        let sErr = AudioDeviceStart(aggID, ioProcID)
        guard sErr == noErr else {
            emitError("tap device start failed: OSStatus \(sErr)")
            return
        }
        started = true
        FileHandle.standardError.write(Data("tap: started\n".utf8))
    }

    private func handle(_ inInputData: UnsafePointer<AudioBufferList>) {
        guard let inFormat = inFormat, let conv = converter else { return }
        let srcAbl = UnsafeMutableAudioBufferListPointer(
            UnsafeMutablePointer(mutating: inInputData))
        guard srcAbl.count > 0 else { return }

        let bytesPerFrame = max(1, Int(inFormat.streamDescription.pointee.mBytesPerFrame))
        let frameCount = Int(srcAbl[0].mDataByteSize) / bytesPerFrame
        guard frameCount > 0,
              let inBuffer = AVAudioPCMBuffer(
                pcmFormat: inFormat, frameCapacity: AVAudioFrameCount(frameCount)) else { return }
        inBuffer.frameLength = AVAudioFrameCount(frameCount)

        // Copy each channel from the tap's buffer list into inBuffer.
        let dstAbl = UnsafeMutableAudioBufferListPointer(inBuffer.mutableAudioBufferList)
        let copyChannels = min(dstAbl.count, srcAbl.count)
        for i in 0..<copyChannels {
            if let dst = dstAbl[i].mData, let src = srcAbl[i].mData {
                let n = Int(min(dstAbl[i].mDataByteSize, srcAbl[i].mDataByteSize))
                memcpy(dst, src, n)
            }
        }

        bufferCount += 1
        if bufferCount == 1 {
            FileHandle.standardError.write(Data("tap: first buffer (\(frameCount) frames)\n".utf8))
        }

        let ratio = targetSampleRate / inFormat.sampleRate
        let cap = AVAudioFrameCount(Double(frameCount) * ratio + 1024)
        guard let out = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: cap) else { return }
        var error: NSError?
        var supplied = false
        let status = conv.convert(to: out, error: &error) { _, s in
            if supplied { s.pointee = .noDataNow; return nil }
            supplied = true
            s.pointee = .haveData
            return inBuffer
        }
        guard status != .error, out.frameLength > 0, let chans = out.floatChannelData else { return }
        let n = Int(out.frameLength)
        let arr = Array(UnsafeBufferPointer(start: chans[0], count: n))
        recordSysStats(samples: arr)
        if let buf = makeBuffer(arr) {
            sysWriter.write(buf)
            sysFullWriter.write(buf)
        }
    }

    func stop() {
        if started, aggID != kAudioObjectUnknown, let p = ioProcID {
            AudioDeviceStop(aggID, p)
        }
        started = false
        if aggID != kAudioObjectUnknown, let p = ioProcID {
            AudioDeviceDestroyIOProcID(aggID, p)
        }
        ioProcID = nil
        if aggID != kAudioObjectUnknown {
            AudioHardwareDestroyAggregateDevice(aggID)
            aggID = AudioObjectID(kAudioObjectUnknown)
        }
        if tapID != kAudioObjectUnknown {
            AudioHardwareDestroyProcessTap(tapID)
            tapID = AudioObjectID(kAudioObjectUnknown)
        }
    }
}

let sysTap = SystemAudioTap()

if !isImport {
    sysTap.start()
}

// MARK: - Heartbeat (every 2s) for live diagnostics

let hbQueue = DispatchQueue(label: "heartbeat")
let hbTimer = DispatchSource.makeTimerSource(queue: hbQueue)
hbTimer.schedule(deadline: .now() + 2, repeating: 2)
hbTimer.setEventHandler {
    stats.lock.lock()
    let mF = stats.micFrames
    let sF = stats.sysFrames
    let ch = stats.chunks
    let mp = stats.micPeak
    let sp = stats.sysPeak
    stats.micPeak = 0
    stats.sysPeak = 0
    stats.lock.unlock()
    emit([
        "event": "heartbeat",
        "mic_frames": mF,
        "sys_frames": sF,
        "chunks": ch,
        "mic_peak": mp,
        "sys_peak": sp,
    ])
}
if !isImport {
    hbTimer.resume()
}

// MARK: - Live waveform level (~10Hz) for the recording indicator
//
// A fast, lightweight emit of the current audio level (max of mic + system
// since the last tick) so the indicator pill's waveform reflects REAL audio and
// falls flat in silence, instead of a canned animation. Separate from the 2s
// heartbeat, which stays for diagnostics.
let lvlQueue = DispatchQueue(label: "level")
let lvlTimer = DispatchSource.makeTimerSource(queue: lvlQueue)
lvlTimer.schedule(deadline: .now() + 0.1, repeating: 0.1)
lvlTimer.setEventHandler {
    stats.lock.lock()
    let lp = stats.levelPeak
    stats.levelPeak = 0
    stats.lock.unlock()
    emit(["event": "level", "level": lp])
}
if !isImport {
    lvlTimer.resume()
}

// MARK: - Pause / Resume via SIGUSR1 / SIGUSR2

var paused: Bool = false

func pauseCapture() {
    if paused { return }
    paused = true
    engine.pause()
    sysTap.stop()
    emit(["event": "paused"])
}

func resumeCapture() {
    if !paused { return }
    paused = false
    do {
        try engine.start()
    } catch {
        emitError("resume mic: \(error.localizedDescription)")
    }
    sysTap.start()
    emit(["event": "resumed"])
}

let pauseSrc = DispatchSource.makeSignalSource(signal: SIGUSR1, queue: .main)
let resumeSrc = DispatchSource.makeSignalSource(signal: SIGUSR2, queue: .main)
signal(SIGUSR1, SIG_IGN)
signal(SIGUSR2, SIG_IGN)
pauseSrc.setEventHandler { pauseCapture() }
resumeSrc.setEventHandler { resumeCapture() }
if !isImport {
    pauseSrc.resume()
    resumeSrc.resume()
}

// MARK: - Audio device / configuration change recovery
//
// Re-establish mic capture after an audio device or format change mid-recording
// (e.g. plugging in HDMI, a USB interface, or AirPods). On a configuration
// change AVAudioEngine stops itself and the input format can change out from
// under the existing tap; without re-reading the format, re-tapping, and
// restarting, the mic tap silently stops firing for the rest of the session
// while ScreenCaptureKit (system audio) keeps running — the failure that
// produced a 3-minute mic stream alongside an 85-minute system stream. The
// notification's object is our engine; `.main` delivery serialises recovery
// with pause/resume/shutdown.
func reconfigureMicAfterDeviceChange() {
    let input = engine.inputNode
    input.removeTap(onBus: 0)
    let newFormat = input.inputFormat(forBus: 0)
    guard newFormat.sampleRate > 0, newFormat.channelCount > 0 else {
        emitError("Audio device changed but the new microphone format is unavailable; mic capture did not resume.")
        return
    }
    installMicTap(input, format: newFormat)
    // While paused the engine is intentionally stopped — resumeCapture() starts
    // it later, now against the freshly-installed tap. Only restart here if we
    // were actively recording when the device changed.
    if !paused {
        do {
            engine.prepare()
            try engine.start()
        } catch {
            emitError("Failed to restart microphone after device change: \(error.localizedDescription)")
            return
        }
    }
    emit(["event": "diagnostic", "message": "Audio input device changed; microphone capture resumed on the new device."])
}

if !isImport {
    NotificationCenter.default.addObserver(
        forName: .AVAudioEngineConfigurationChange,
        object: engine,
        queue: .main
    ) { _ in
        reconfigureMicAfterDeviceChange()
    }
}

// MARK: - Parent-death watchdog
//
// We `setsid()` from the Rust side so this sidecar gets its own session
// (necessary for TCC permissions to bind to the *sidecar's* binary identity
// rather than the parent's). A side effect of detached sessions is that the
// process survives parent death — the launching app crashing, a `pnpm tauri
// dev` reload, or a force-quit leaves an orphan running indefinitely. macOS
// will reparent it to launchd (PID 1) in those cases.
//
// Poll PPID every 2 s. If we see PID 1 as our parent, the launcher is gone
// and we should exit so the next launch starts cleanly without a zombie
// sidecar holding onto the mic.
let originalParentPid = getppid()
let parentWatchdog = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "parent.watchdog"))
parentWatchdog.schedule(deadline: .now() + 2, repeating: 2)
parentWatchdog.setEventHandler {
    if let pid = parentPid {
        // Explicit parent PID: exit only when that exact process is gone.
        // kill(pid, 0) returns 0 while it lives, -1 (ESRCH) once it dies.
        if kill(pid, 0) != 0 {
            exit(0)
        }
    } else {
        // Fallback for hand-launches with no --parent-pid: the old PPID test.
        let current = getppid()
        if current == 1 || (originalParentPid != 1 && current != originalParentPid) {
            exit(0)
        }
    }
}
if !isImport {
    parentWatchdog.resume()
}

// MARK: - Signal handling: SIGTERM / SIGINT → finalize

let sigSource = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
let sigSource2 = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
signal(SIGTERM, SIG_IGN)
signal(SIGINT, SIG_IGN)

let shutdown: () -> Void = {
    Task {
        // Close all writers FIRST, before any async cleanup that
        // might block. ScreenCaptureKit's `stopCapture()` has been
        // observed to take multiple seconds — if we await it before
        // closing the writers, the parent's SIGTERM grace window can
        // expire and SIGKILL truncates this process before any
        // `chunk` / `full_recording` / `stopped` events reach
        // stdout. That manifests on the user's side as "the last
        // 20–30 s of audio never gets transcribed" because the
        // chunks for that tail were ready to emit but never did.
        // engine.stop() is synchronous and returns immediately;
        // ChunkWriter.close() is also synchronous (queue.sync).
        engine.stop()
        micFullWriter.close()
        sysFullWriter.close()
        micWriter.close()
        sysWriter.close()
        emit(["event": "stopped"])
        // Tear down the tap + aggregate device after emitting everything
        // the parent needs. Synchronous and quick.
        sysTap.stop()
        exit(0)
    }
}

sigSource.setEventHandler(handler: shutdown)
sigSource2.setEventHandler(handler: shutdown)
if !isImport {
    sigSource.resume()
    sigSource2.resume()
}

// MARK: - Import replay
//
// Decode the source file to PCM, resample each block to the target 16 kHz
// mono format via AVAudioConverter, and feed the SAME mic writers as live
// capture. Runs at full speed (no realtime pacing) — the OS/disk buffers the
// per-chunk WAVs and the Rust reader applies a bounded-backlog semaphore so a
// fast replay can't swamp the transcribe queue. On completion it closes the
// writers (emitting the final chunk + `full_recording`), emits `stopped`, and
// exits. Only the mic writers are touched, so the Rust side sees a mic-only
// session and runs the mic-only diarize branch — exactly what we want.
func runImport(_ path: String) {
    let url = URL(fileURLWithPath: path)
    let file: AVAudioFile
    do {
        file = try AVAudioFile(forReading: url)
    } catch {
        emitError("import open \(url.lastPathComponent): \(error.localizedDescription)")
        emit(["event": "stopped"])
        exit(1)
    }

    let inFormat = file.processingFormat
    guard let converter = AVAudioConverter(from: inFormat, to: targetFormat) else {
        emitError("import: could not build converter from \(inFormat)")
        emit(["event": "stopped"])
        exit(1)
    }

    // Read/convert in ~1 s blocks. Block size is at the source rate; the
    // converter downmixes to mono and resamples to 16 kHz in one pass.
    let blockFrames = AVAudioFrameCount(max(inFormat.sampleRate, 16_000))
    // Track whether we've read any audio yet. AVAudioFile.read(into:) is known
    // to throw `_GenericObjCError error 0` at/near the end of some compressed
    // files (m4a/mp4/aac) instead of cleanly returning frameLength == 0. Once
    // we've already read at least one block, treat that throw as end-of-stream
    // rather than surfacing a scary error toast for an import that succeeded.
    var readAnyFrames = false
    while true {
        guard let inBuf = AVAudioPCMBuffer(pcmFormat: inFormat, frameCapacity: blockFrames) else { break }
        do {
            try file.read(into: inBuf)
        } catch {
            // Distinguish the benign AVAudioFile tail quirk from genuine
            // mid-file decode corruption by read position. `read(into:)` is
            // known to throw at/near the end of some compressed files instead
            // of cleanly returning frameLength == 0 — that throw lands within
            // ~one block of file.length. A throw well *before* the end means
            // the file failed to decode mid-stream, so treating it as clean
            // EOF would silently import a truncated file (exit 0, "stopped",
            // no error) while the user believes the whole file came in.
            // Surface those as a real error; keep the tail quirk silent.
            let atTail = file.framePosition >= file.length - Int64(blockFrames)
            if readAnyFrames && atTail { break } // tail-read quirk → EOF
            emitError("import read: \(error.localizedDescription)")
            break
        }
        if inBuf.frameLength == 0 { break } // EOF
        readAnyFrames = true

        let ratio = targetSampleRate / inFormat.sampleRate
        let cap = AVAudioFrameCount(Double(inBuf.frameLength) * ratio + 1024)
        guard let out = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: cap) else { break }
        var convErr: NSError?
        var supplied = false
        let status = converter.convert(to: out, error: &convErr) { _, s in
            if supplied { s.pointee = .noDataNow; return nil }
            supplied = true
            s.pointee = .haveData
            return inBuf
        }
        if status == .error {
            emitError("import convert: \(convErr?.localizedDescription ?? "unknown")")
            break
        }
        if out.frameLength > 0, let chans = out.floatChannelData {
            let n = Int(out.frameLength)
            let arr = Array(UnsafeBufferPointer(start: chans[0], count: n))
            if let buf = makeBuffer(arr) {
                micWriter.write(buf)
                micFullWriter.write(buf)
            }
        }
    }

    micWriter.close()
    micFullWriter.close()
    emit(["event": "stopped"])
    exit(0)
}

if let importPath = importPath {
    runImport(importPath)
} else {
    RunLoop.main.run()
}
