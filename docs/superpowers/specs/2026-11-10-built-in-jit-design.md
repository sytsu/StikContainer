# Built-in JIT for LiveContainer+SideStore — Design

Date: 2026-11-10 · Base: LiveContainer `main` @ `9d6ea09` (nightly 3.8.13, 2026-11-08) · Branch: `builtin-jit`

## Intent

The user runs JIT apps (MeloNX, Henge, and similar) inside LiveContainer+SideStore on an iPhone 16 running iOS 27.0. Today JIT works through StikDebug, but StikDebug is a separate home-screen app, which they do not want. The existing in-LiveContainer workaround ("StikDebug (Another LiveContainer/Multitask)") needs either a second LiveContainer install (another icon) or multitask mode, and the user finds it janky.

They want LiveContainer itself to enable JIT: tap an app that is set to need JIT, and it opens with JIT working, with no other app involved and no app-switching.

## Goals

1. Add a new JIT enabler, **Built-in (StikJIT)**, to the global JIT Enabler picker. This is the only switch that turns the feature on.
2. Use it on these launch paths:
   - **Per-app setting:** the existing "Launch with JIT" toggle (`isJITNeeded`) in each app's settings.
   - **Long-press, new:** a "Launch with JIT" item in the app's long-press menu (`LCAppBannerViewController.swift`) for a one-off JIT launch (`runApp(forceJIT: true)`), whether or not the app's toggle is on. Show it only when the selected enabler is Built-in.
3. Choose the script per app:
   - If the app has no custom script, use StikJIT's bundled `universal.js`, which MeloNX and Henge use.
   - If the app has a custom script (`jitLaunchScriptJs`, already base64), pass it as `.customBase64`.
4. Run StikJIT in a helper process, LiveContainer's own `LiveProcess.appex` started in a new "JIT helper" mode. The helper calls `StikJIT.enableJIT(targetPID:)` against the guest app's process. No external app takes part.
5. Ship a single unsigned IPA, `LiveContainer+SideStore.ipa`, with exactly the same bundle identifiers, app groups, URL schemes and entitlements as the official nightly. Re-sideloading it over the user's current install (`com.kdt.livecontainer.3BWTF5V8GA`) must update in place and keep all apps, containers, settings and data.

## Non-goals

- A GitHub fork, CI, or keeping up with future nightlies. The deliverable is one working IPA built on this Mac.
- **JIT for multitask-mode launches in v1.** *(Builder's call to include it if cheap. If it's left out, a Built-in JIT launch that would open as multitask opens normally instead (Claude's call).)* LiveContainer's main process stays alive there and already receives the LiveProcess PID through `jitLaunch(withPID:)`, so it may be easy.
- Making apps work that don't already work with StikDebug. If an app's JIT engine doesn't follow the iOS 26 script protocol, this won't fix it.
- Changing guest apps (MeloNX etc.).
- Removing or changing the existing JIT enablers.

## Anti-goals (failure even if JIT works)

- The install doesn't update in place, so the user loses LiveContainer data or apps. This includes any change to bundle IDs, app groups, keychain groups, or the main app's entitlements and Info.plist identity keys.
- Any extra app on the home screen, or StikDebug required to be installed anywhere.
- App-switching or bouncing during a normal JIT launch.
- When built-in JIT fails, silently falling back to another enabler. Show the error instead.
- Breaking non-JIT launches or the existing enablers.

## Constraints and facts the builder can rely on

**Device**
- iPhone16,? / iPhone17,3 (iPhone 16), iOS 27.0 (24A435), Developer Mode on.
- TXM is expected to be present, so the script protocol is required.
- LocalDevVPN is required, the same as with StikDebug today. StikJIT connects to `10.7.0.1` and discovers the RSD port.

**StikJIT**
- Use the prebuilt `StikJIT.xcframework.zip` from release `2.0.1` (github.com/StikDebug/StikJIT). Build from source (xcodegen) only if the prebuilt one fails with Xcode 27.2.
- The API is Swift-only, blocking and synchronous; requires iOS 17.4+; links IOKit, JavaScriptCore, Network and others.
- Call it on one dedicated serial background queue in the helper.

**LiveProcess**
- ObjC only, deployment target 15.0. StikJIT needs 17.4, so the helper must only load it when available (weak-link or `dlopen`) and reach it through a small Swift shim.
- Embed the framework in the main app's Frameworks, the same way `OpenSSL.xcframework` is.

**Launching the helper**
- Use the nightly's helper-process primitives (`NSExtension+GuestHooks.m`):
  - `+[NSExtension extensionWithIdentifier:]` for the LiveProcess bundle ID
  - a request whose userInfo carries a new key (e.g. `LCJITHelper`) plus an `NSXPCListenerEndpoint`
  - `pidForRequestIdentifier:` for the helper's PID
  - `_kill:` for cleanup
- `LiveProcess/main.m` dispatches on that new key into the helper code.
- Model the endpoint, interruption handler and timeout handling on `SideStoreSupport/SideStore.swift:91-153`.
- Put new shared IPC code in `LiveContainerShared`, not `SideStoreSupport`.

**Where it starts**
- Start the helper from the guest process, inside `invokeAppMain` in `LiveContainer/LCBootstrap.m`, after hooks and before `appMain`. Target PID = `getpid()`, which is the guest app's process.
- This uses the attach model: JIT arrives shortly after bootstrap, not before.
- MeloNX-style apps wait for `CS_DEBUGGED` themselves and then run the JIT26 breakpoint protocol, which the attached script services.
- Don't block the main thread for long before `UIApplicationMain`, because of the launch watchdog. The first run may download the DDI.
- *(Claude's call.)* If starting an extension before `UIApplicationMain` turns out to be unreliable, start the helper at the first point after it where that works, such as a `didFinishLaunching` hook.
- *(Claude's call.)* While Built-in is selected, LiveContainer also catches `stikjit://enable-jit` and `stikdebug://enable-jit` URLs opened by the guest app and handles them with the built-in helper. That request's `script-name` or `script-data` sets the script. Apps that ask StikDebug for JIT themselves then work too.

**Lifetime**
- The helper must stay alive until `enableJIT` returns (script detached), then exit.
- The guest process keeps the NSExtension and connection objects in statics so they aren't deallocated.

**Pairing file**
- StikJIT reads RPPairing format (`rp_pairing_file_read`: `public_key`, `private_key`, `identifier`). A classic lockdown record will fail.
- Sources, in order:
  1. an imported file at `$LC_HOME_PATH/Documents/StikJIT/pairingFile.plist`
  2. SideStore's `$LC_HOME_PATH/Documents/SideStore/Documents/ALTPairingFile.mobiledevicepairing`, only if it parses as RPPairing
- The helper cannot read LiveContainer's container, so the guest process sends the bytes over XPC. The helper writes a temp file and deletes it right after use.
- The user already has an RPPairing file, because StikDebug only reads that format.
  - The settings help text tells them to import StikDebug's `pairingFile.plist` before removing StikDebug.
  - Generating a pairing file on the device is out of scope.

**DDI cache**
- Keep it in the helper's own Library (`DDIPaths.default(in: Library/StikJIT)`).
- *(Builder to confirm.)* LiveProcess instances share one extension container, so the cache persists.

**Building**
- Mirror `.github/workflows/build.yml` and `.github/build_github.sh`:
  - xcodebuild archive, Release, unsigned
  - dylibify + ldid on SideStore
  - the same `SideStore.ipa` nightly download
- Local tools may need installing: wget or curl, ldid, xcpretty optional, and dylibify, whose architecture must be checked.
- Use Xcode 27.2, which matches CI.

## Settings UI (decided)

In LiveContainer Settings, the JIT section gains a **Built-in (StikJIT)** choice. When it is selected, a small subsection appears with:
- **Pairing file status:** "Using SideStore's pairing file", "Imported", or "Missing / wrong format".
- **Import Pairing File:** a document picker that stores the file at the path above.
- **Prepare JIT:** runs `prepareDevice` in a helper, shows the result (Ready, Unreachable or Not Ready, with the reason), and pre-mounts the DDI before the first game launch.
- **TXM:** Present, Not Present or Unknown.
- **Reset Developer Disk Image.**
- One line of setup help: LocalDevVPN must be connected, and so on.

## Launch-time feedback (decided)

While JIT is being acquired inside the guest app, show a minimal non-blocking status: a small overlay or banner reading "Enabling JIT…" with the current stage. On success it disappears. On failure the app shows an alert with StikJIT's error text.

Write a plain-text helper log to `$LC_HOME_PATH/Documents/StikJIT/last-jit.log`, so it can be pulled off the device with `xcrun devicectl device copy from` for debugging.

## Version and identity

- Keep `CFBundleIdentifier`, every extension ID, app groups, URL schemes and the version strings (3.8.13) the same as the nightly.
- Identify the build visibly with a "Built-in JIT build" note in Settings rather than a version change.
- *(Builder's call.)*

## Left to the builder

- The XPC protocol shape (progress, log lines, result).
- The exact insertion line in `invokeAppMain`, and any short wait for `CS_DEBUGGED` before `appMain`.
- How the overlay is implemented.
- Weak-link vs `dlopen` for StikJIT.
- Whether multitask JIT fits in v1.
- Localization (English-only strings are fine).

## Testing

The user installs each build with their normal sideloading tool (same Apple ID, so the team suffix `3BWTF5V8GA` is unchanged). Keep the official nightly IPA (`LiveContainer+SideStore.ipa`, 3.8.13) as a rollback that also installs in place.

The iPhone (`iPhone17,3`) is paired with this Mac and visible to `xcrun devicectl`. Use that to pull `last-jit.log` and other files from LiveContainer's data container where signing allows it. Installs still go through the user's sideloader.

*(Claude's call.)* The first build is a diagnostic build: the Built-in enabler, the helper launch and heavy logging, with the minimum UI. It proves the risky parts before any polish:
- the helper starts from the guest process
- RSD/tunnel reachability from inside the extension
- TXM detection inside the extension sandbox
- the DDI cache survives between launches

Test on device:

1. Install over the existing app and confirm the apps, data and settings are intact.
2. Select Built-in, then check the pairing status and Prepare JIT.
3. Launch MeloNX with JIT via its toggle, and confirm a game runs with JIT.
4. Run a one-off JIT launch from the long-press menu.
5. Launch a non-JIT app normally to check for regressions.
6. Switch back to the StikDebug enabler and confirm it still works.

## First build (2026-11-10): where it differs from this document

Built without answers to the three open questions, so it assumes apps detach once their JIT memory is set up.

- **Helper code location:** the StikJIT calls live in `LiveContainerSwiftUI` (`Utilities/LCBuiltInJIT.swift`), which links StikJIT weakly. The LiveProcess helper loads that framework with `dlopen`. No new target was added.
- **Result channel:** the helper reports through the extension request (complete or cancel with an error), not a separate XPC connection. Progress goes to the log file only.
- **Shared files:** the Developer Disk Image cache and `last-jit.log` are in the app group (`LiveContainer/StikJIT`), so Prepare JIT in Settings and the helper share one download. Prepare JIT runs in LiveContainer's own process.
- **Launch-time feedback:** no overlay. The helper starts before `UIApplicationMain`, and LiveContainer waits up to 10 seconds for the debugger to attach.
  - A failure inside that wait returns to LiveContainer's own screen with the error.
  - A failure after it shows an alert over the app.
- **Trigger:** bootstrap enables JIT when Built-in is selected and the app has "Launch with JIT" on, or when the long-press item set a one-off request.
- **Multitask:** included, by targeting the LiveProcess pid from LiveContainer's UI. The app starts before JIT arrives.
- **Not built:** catching `stikjit://` and `stikdebug://` URLs opened by a guest app.
- **IPA:** `scripts/package_ipa.sh` copies the built-in SideStore pieces from the official nightly IPA instead of running dylibify and ldid.
- **Not tested on a device.** The IPA builds, and its contents match the official nightly apart from the added `StikJIT.framework` and the changed binaries.
