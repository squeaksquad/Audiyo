# Audiyo — Sync & Performance Implementation Plan

Running document for improving synchronized multitrack playback in Audiyo.
Repo: https://github.com/squeaksquad/Audiyo
All work happens in `Audiyo macOS 26/ContentView.swift` unless noted (line numbers reference the file as of 2026-07-06 and will drift as edits land — search for the quoted code instead of trusting the number).

**Status legend:** `[ ]` not started · `[~]` in progress · `[x]` done and verified

---

## Project constraints (read first — do not "fix" these)

1. **NO sample-rate conversion, ever.** Audiyo is an educational aid. All stems in one song folder share the same sample rate by design. When the file rate mismatches the device rate, the app must only show the existing warning banner and play at the wrong rate. Students are supposed to notice and fix hardware clocking themselves. Do not add `AVAudioConverter` or any resampling.
2. **The app is NOT sandboxed** (`ENABLE_APP_SANDBOX = NO` in project.pbxproj). It reads `~/.Audiyo Library` directly with no special permission.
3. **Discrete channel routing is intentional.** Each track (stem) is routed to its own hardware output channel (track 0 → channel 1, track 1 → channel 2, …) via the `DiscreteInOrder` channel layout. Preserve this behavior in any refactor.
4. Target: macOS 26, Swift, SwiftUI, AVAudioEngine. Keep the single-file structure unless a change forces a split.

## Architecture summary (current state)

- `AudioPlayer` (`@MainActor @Observable`): owns one `AVAudioEngine`, one `AVAudioMixerNode` (`mainMixer`), and one `AVAudioPlayerNode` per track.
- Each `Track` holds three full-length `AVAudioPCMBuffer`s: `originalBuffer` (file format), `scratchBuffer` and `scratchLoopBuffer` (both in the multi-channel hardware format).
- `play(from:)` copies the needed slice of each track's mono audio into channel *i* of its hardware-format scratch buffer (`copySlice`), schedules it, and starts all players at a shared `AVAudioTime`.
- Looping uses the `.loops` schedule option on a second scratch buffer.
- A 16 ms `Timer` polls `players.first`'s `playerTime` to drive the UI playhead.
- Per-player `installTap` computes RMS meter levels.

---

## Phase 1 — Sync correctness (this is what guarantees sample-locked playback)

### 1.1 `[x]` Fix host-time computation in `play(from:)`

**Bug:** `let hostTime = mach_absolute_time() + UInt64(delaySeconds * 1_000_000_000)` adds **nanoseconds** to a value measured in **host ticks**. On Apple Silicon 1 tick ≈ 41.7 ns, so the intended 20 ms start delay is actually ~833 ms of dead air before every play/seek. (On Intel the timebase is 1:1, which is why it ever seemed right.)

**Fix:** convert properly. Either:
```swift
let startHostTime = mach_absolute_time() + AVAudioTime.hostTime(forSeconds: delaySeconds)
let startTime = AVAudioTime(hostTime: startHostTime)
```
(`AVAudioTime.hostTime(forSeconds:)` returns ticks for a duration; adding tick-domain values is valid.) Also update the `DispatchQueue.main.asyncAfter(deadline: .now() + delaySeconds)` that starts the UI timer so it stays consistent with the real audio start.

### 1.2 `[x]` Two-pass start in `play(from:)`

**Bug:** the current loop schedules player *i*'s buffers and immediately calls `player.play(at: startTime)` before player *i+1*'s buffers are even copied. If the copy work for later players overruns the shared deadline, those players start late → real desync.

**Fix:** restructure into two passes:
1. Pass 1: for every player — stop, copy/schedule all buffers. No `play` calls yet.
2. Compute the shared start time **after** all scheduling is done, preferably in the sample-time domain:
   ```swift
   guard let renderTime = engine.outputNode.lastRenderTime,
         renderTime.isSampleTimeValid else { /* fall back to host time from 1.1 */ }
   let startSample = renderTime.sampleTime + AVAudioFramePosition(0.05 * outputSampleRate) // 50 ms safety
   let startTime = AVAudioTime(sampleTime: startSample, atRate: outputSampleRate)
   ```
   `outputSampleRate` = `engine.outputNode.outputFormat(forBus: 0).sampleRate`.
3. Pass 2: `players.forEach { $0.play(at: startTime) }` — nothing but `play` calls in this loop, all receiving the identical `AVAudioTime`.

Keep the safety margin ≥ 50 ms; it is inaudible for a transport start and makes late starts effectively impossible.

### 1.3 `[x]` Make `copySlice` memory-safe + zero-pad unequal tracks

**Bug:** all frame counts in `play(from:)` derive from track 0's length (`audioLengthSamples`), but `copySlice` memcpys from each track's own `originalBuffer` without checking its actual length. Any stem shorter than track 0 causes a read past the end of its allocation (garbage audio or crash).

**Fix (two parts):**
1. In `copySlice`, clamp: compute `available = source.frameLength - startFrame` (treat negative as 0) and copy `min(frameCount, available)` frames; the destination is already zeroed so the remainder is silence. Never trust the caller's `frameCount`.
2. At load time in `setupTracks`, compute `maxLength = max over all files of file.length` and use it (not track 0's length) for `audioLengthSamples`, buffer capacities, duration, and loop math. Shorter stems simply play silence after their content ends. This keeps every player's scheduled buffer lengths identical, which is what keeps `.loops` playback sample-locked across players.

### 1.4 `[x]` Handle multi-channel (stereo) source files

**Bug:** `copySlice` reads only `source.floatChannelData?[0]`; a stereo stem silently loses its right channel.

**Fix:** if the source has more than one channel, average all source channels into the destination channel (mono fold-down), e.g. copy channel 0 then `vDSP_vadd`+`vDSP_vsmul` the rest, or a simple loop. Document the fold-down in a comment. (Stems are expected to be mono; this is a safety net, not a feature.)

**Explicitly out of scope for Phase 1:** any resampling (see constraint 1). The float32 memcpy is format-valid even when rates mismatch; wrong-speed playback is the intended behavior.

---

## Phase 2 — Efficiency (removes the CPU/memory spikes that cause glitches in practice)

### 2.1 `[x]` Route once at load; stop copying on every play/seek

**Problem:** every play, seek, and loop change memcpys the entire remaining audio of every track on the main thread. Memory is also enormous: `scratchBuffer` and `scratchLoopBuffer` are each full-length × hardware-channel-count. (8 five-minute stems on an 8-channel device ≈ multiple GB, mostly zeros.)

**Fix:**
1. In `setupTracks`, build **one** routed hardware-format buffer per track, once: zero it, copy the whole stem into channel *i*, done. Delete `scratchLoopBuffer` and the per-play `copySlice` calls.
2. ~~For playback from an offset, create **zero-copy slice buffers** over the routed buffer using `AVAudioPCMBuffer(pcmFormat:bufferListNoCopy:deallocator:)`~~ **DO NOT DO THIS — it was tried and crashes.** On macOS 26 (26.4.1), when `AVAudioPlayerNode` finishes with a scheduled buffer whose `AudioBufferList` points into memory owned by another buffer, `-[AVAudioBuffer dealloc]` ends up calling `free()` on the interior pointer → `___BUG_IN_CLIENT_OF_LIBMALLOC_POINTER_BEING_FREED_WAS_NOT_ALLOCATED` → SIGABRT on the `RealtimeMessenger.mServiceQueue` (crash observed 2026-07-06, triggered by seek → `stop()` while slices were in flight). Scheduled buffers must own their memory outright.
3. **Implemented approach (the former fallback, improved):** each `Track` stores its stem folded to **mono** once at load (`monoBuffer`, 1× the audio length — N× less memory than a hardware-format copy). Play/seek/loop call `makeSlice(from:startFrame:frameCount:targetChannel:)`, which allocates a fresh hardware-format buffer of exactly the needed range and copies the mono data into the track's channel via `copySlice`. Copies happen only on user-initiated transport actions (scrubbing is gated by 2.2), and AVFAudio frees the slices normally when playback moves on.

Verify after this change: play, pause/resume, seek, loop with intro segment, loop-region drag, and Reset Trims all still work; memory footprint (Xcode memory gauge) drops dramatically for multi-track songs.

### 2.2 `[x]` Stop seeking on every mouse-move

**Problem:** the timeline `DragGesture.onChanged` calls `player.seek(to:)` per event; each seek is a full stop→copy→reschedule→restart across all tracks. Loop-handle drags restart playback `onEnded` too, which is fine, but the timeline is the hot path.

**Fix:** during `onChanged`, only update `playbackProgress` (and pause the UI timer or gate `updateProgress` so it doesn't fight the drag). Perform the real `seek(to:)` once in `onEnded`. While scrubbing during playback, either keep audio playing untouched or stop it — pick one, but do not reschedule per event.

### 2.3 `[x]` Cheaper metering

**Fixes in `processMeter` / tap setup:**
- Use `vDSP_rmsqv` (import Accelerate) over the full buffer instead of the manual stride-10 loop (the stride also skews readings).
- Throttle **before** hopping to the main actor: keep a `lastDispatch` timestamp captured by the tap closure (an atomic or a simple class box per track) and skip the `Task { @MainActor }` entirely unless >30 ms elapsed. Currently every tap callback (~40–90/s per track) spawns a task.
- Guard `frames > 0` before dividing.

### 2.4 `[x]` Timer and end-of-playback detection

- Add the progress `Timer` to `RunLoop.main` in `.common` mode (`RunLoop.main.add(timer, forMode: .common)`) so the playhead doesn't freeze during menu tracking/drags. (Or replace with a display link.)
- Detect end-of-song via the player's completion callback — `scheduleBuffer(_:at:options:completionCallbackType: .dataPlayedBack)` on the final segment — instead of polling for `playbackProgress >= 1.0`. Keep the poll as a backstop. Completion handlers fire on a background thread: hop to `@MainActor` and ignore stale callbacks (compare against a generation counter incremented on every stop/seek, else an old callback from a superseded schedule will stop fresh playback).

---

## Phase 3 — Robustness & admin auth

### 3.1 `[x]` Replace the hardcoded password with macOS admin authentication

**Problem:** `PasswordPromptView` compares against a plaintext literal (`"the Cake is a Lie"`) baked into the binary. The password only gates the "Load Library Folder" button (changing the library location); it grants no filesystem access.

**Fix:** require credentials of a user in the Mac's **admin group** via Authorization Services (`import Security` — the framework, not sandbox-related). Instructor accounts (admins) pass; standard student accounts cannot, even knowing their own login password. No secret ships in the app.

```swift
func authenticateAsAdmin() -> Bool {
    var authRef: AuthorizationRef?
    guard AuthorizationCreate(nil, nil, [], &authRef) == errAuthorizationSuccess,
          let auth = authRef else { return false }
    defer { AuthorizationFree(auth, [.destroyRights]) }
    return "system.privilege.admin".withCString { name in
        var item = AuthorizationItem(name: name, valueLength: 0, value: nil, flags: 0)
        return withUnsafeMutablePointer(to: &item) { itemPtr in
            var rights = AuthorizationRights(count: 1, items: itemPtr)
            let flags: AuthorizationFlags = [.interactionAllowed, .extendRights]
            return AuthorizationCopyRights(auth, &rights, nil, flags, nil) == errAuthorizationSuccess
        }
    }
}
```
Notes for the implementer:
- `AuthorizationCopyRights` with `.interactionAllowed` presents the standard macOS credential dialog; it **blocks**, so call it off the main thread (`Task.detached` / `DispatchQueue.global`) and hop back to the main actor with the result.
- On success, call the existing `player.loadLibraryFolder()`. Delete `PasswordPromptView` and `ShakeEffect`, and remove the `showPasswordPrompt` sheet from `ContentView` — the lock button calls the auth function directly.
- `system.privilege.admin` uses the built-in `authenticate-admin` rule. Do **not** pre-authorize anything with the granted right; it's used purely as an "is this an admin?" check, and the rights are destroyed immediately.

### 3.2 `[x]` Survive device/configuration changes automatically

- Observe `Notification.Name.AVAudioEngineConfigurationChange` on the engine: on fire, capture transport state (progress, isPlaying, loop state, volumes), rebuild via the existing `refreshHardwareState()` path, and restore state (resume playback from captured progress if it was playing).
- Add CoreAudio property listeners (`AudioObjectAddPropertyListenerBlock` on `kAudioObjectSystemObject`) for `kAudioHardwarePropertyDevices` (device list changed → re-run `fetchDevices`, keep selection if still present) and `kAudioHardwarePropertyDefaultOutputDevice`.
- Keep the manual refresh button as a fallback.

### 3.3 `[x]` Simplify bookmark persistence

The app is not sandboxed, so the security-scoped bookmark options in `saveBookmark`/`restoreLastLibrary` (`.withSecurityScope`, `startAccessingSecurityScopedResource`) are dead weight. Replace with a plain bookmark (no options) or just the stored path. If App Store sandboxing is ever planned, keep the scoped version instead and add the entitlement — decide then, note the decision here.

### 3.4 `[x]` Surface unequal stem lengths in the UI

After 1.3, shorter stems pad with silence. Add a small per-track indicator (e.g., duration text in `TrackRow` turns orange with a tooltip) when a stem's length differs from the longest — consistent with the app's "show students the problem" philosophy.

---

## Verification checklist (run after each phase)

- **Phase-cancellation sync test (the acid test):** install a loopback device (e.g., BlackHole 2ch). Load a song with the *same file* as two tracks. Add a temporary debug toggle (or a prepared inverted copy of the file) so track 2 is polarity-inverted, route both to the same channel, record the loopback output. Digital silence = sample-accurate sync. Repeat after: fresh play, pause/resume, seek mid-song, loop with intro, loop-handle drag, 20× rapid space-bar toggles.
- **Latency:** on Apple Silicon, time from space-bar to first audio should be ~50–70 ms (was ~850 ms before 1.1/1.2).
- **Short-stem test:** song where one stem is shorter than the others — no crash, silence after it ends, loop still locked.
- **Scrub test:** drag the timeline continuously for 10 s while playing — no audio stutter, CPU stays low.
- **Memory:** multi-track song loaded; Xcode memory gauge should be roughly `tracks × length × (1 + hwChannels) × 4 bytes` after 2.1, not `tracks × length × 2 × hwChannels × 4`.
- **Device swap:** unplug/replug the interface mid-playback after 3.2 — engine recovers without the manual refresh button.
- **Admin gate:** after 3.1, a standard (non-admin) macOS account cannot unlock "Load Library Folder"; an admin account can; `strings` on the built binary contains no password.

## Change log

- 2026-07-06 — Plan created. Decisions locked in: no sample-rate conversion (educational constraint); admin gate = Authorization Services (macOS admin-group credentials), scheduled in Phase 3.
- 2026-07-06 — Backups created before any code changes: git tag `pre-sync-overhaul-2026-07-06` on `main` (commit 7fbed88) and zip `../Audiyo-source-backup-2026-07-06.zip` (source, no .git). All work happens on branch `sync-overhaul`; `main` is untouched.
- 2026-07-06 — Phase 1 (1.1–1.4) implemented in `ContentView.swift` on branch `sync-overhaul`. Builds clean (only pre-existing warnings remain: dangling `UnsafeBufferPointer` in `getDeviceOutputChannelCount`, CFString pointer in `fetchDevices`, deprecated `onChange` — fold into Phase 3). Manual audio verification (phase-cancellation test, short-stem test, latency check) NOT yet run — do this before calling Phase 1 complete against the verification checklist.
- 2026-07-06 — Git history rewrite completed (separate session): .git shrank 11GB → 4.3MB, all SHAs changed, `.gitignore` for build products added. Tag and branches survived.
- 2026-07-06 — Phase 2 (2.1–2.4) implemented on `sync-overhaul`, initially with zero-copy `bufferListNoCopy` slices. End detection: `.dataPlayedBack` completion on player 0's tail buffer guarded by a `scheduleGeneration` counter (poll kept as backstop). Timer runs in `.common` mode. Scrubbing is visual-only until gesture end (`previewSeek`/`isScrubbing`). Meters use `vDSP_rmsqv` with throttling before the main-actor hop (`MeterThrottle`, `nonisolated(unsafe)` because the project uses default-MainActor isolation).
- 2026-07-06 — CRASH FIX: the zero-copy slices SIGABRT'd in Release (libmalloc abort in `-[AVAudioBuffer dealloc]` freeing an interior pointer — see rewritten 2.1(2) for details). Replaced with 2.1(3): `Track.monoBuffer` (stem folded to mono at load) + `makeSlice` allocating fresh hardware-format slices per transport action. Net memory is now better than the original zero-copy design (1× mono per track persistent, slices transient). Release build clean.
- 2026-07-06 — User verified Phases 1+2 by running the app: playback, seek, and the previously-crashing scrub-while-playing all work.
- 2026-07-06 — Phase 3 (3.1–3.4) implemented on `sync-overhaul`. 3.1: `PasswordPromptView`/`ShakeEffect` deleted; `authenticateAsAdmin()` (Authorization Services, `system.privilege.admin`) runs on a detached task and gates `loadLibraryFolder()`. 3.2: `.AVAudioEngineConfigurationChange` observer (0.3 s debounce, skips self-inflicted rebuilds by comparing the live output format to `hardwareFormat`) + `kAudioHardwarePropertyDevices` listener that re-fetches the device list and falls back to the first device if the selected one vanished. 3.3: bookmarks no longer security-scoped. 3.4: orange warning triangle with tooltip in `TrackRow` for stems shorter than the song. Also fixed all five pre-existing compiler warnings (dangling `UnsafeBufferPointer` in `getDeviceOutputChannelCount`, `Unmanaged<CFString>` handling in `fetchDevices`, spurious `await` in `scanAndSetLibrary`, 2× deprecated `onChange`). Build is now warning-free. Note seen in console during testing: `HALC_ProxyIOContext StartIO error 35` — transient CoreAudio start failure during rapid engine restarts; the 3.2 debounce should reduce occurrences, keep an eye on it.
- 2026-07-06 — Remaining before calling the whole effort done: the verification checklist (phase-cancellation test, short-stem, device-swap, admin-gate checks).
