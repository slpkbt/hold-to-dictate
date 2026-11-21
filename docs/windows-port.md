# Windows port

## Design

1. Keep the existing Swift source, settings and macOS publishing workflow unchanged.
2. Use a WPF overlay and settings window with a tray controller for the Windows lifecycle. Register a single OS hotkey and check only its state while recording; no global keyboard hook or recording of typed keys. Fail visibly on conflicts.
3. Keep capture and recognition per hold. Windows Speech provides local dictation with an installed desktop recognizer; optional Codex mode uses the existing file-backed sign-in and fixed first-party endpoint, with redirects disabled and bounded queues, messages and timeouts. Do not save audio or transcripts. Preview and package tests never access a microphone or a real account.
4. Copy the result; optional paste requires the same foreground window and an identifiable, unchanged non-password control. A clipboard change, uncertain focus or UIPI rejection yields clipboard/manual paste instead. Never press Enter. Windows defaults to local recognition and no auto-paste.
5. Produce a self-contained win-x64 archive and SHA-256, leaving macOS release assets untouched. Windows CI compiles, runs portable smoke checks and executes the extracted package's self-test.

## Manual acceptance (interactive Windows with microphone)

- Open app from the extracted ZIP as a regular user. Verify a tray icon, Settings and mic-free Preview; opening a second copy should not start another listener.
- In Notepad, hold default Ctrl+Shift+K, speak, and release the main key, then repeat releasing a modifier first. Check live waveform, text, clipboard and that the app does not press Enter.
- Cancel with Esc, test a denied microphone and a missing desktop speech recognizer, then recover via Settings. Test repeated holds, no speech, and timeout.
- Save a different shortcut, bad/conflicting shortcut, width, color, sound and launch at sign-in. Restart to confirm settings. Disable launch at sign-in before moving or deleting the extracted folder.
- With auto-paste enabled, test Notepad, a browser text field, change focus/window while recording, password field, modified clipboard, and elevated app. Unknown or changed destinations should not get synthetic input.
- To test Codex end to end, opt in and use a valid file-backed Codex sign-in. Check partial and final text, then repeat with unavailable network. No live account is required by CI; the service protocol is not public or guaranteed.
