import AppKit
import ApplicationServices
import AVFoundation
import Carbon
import ServiceManagement
import Speech

private struct PasteTarget {
    let pid: pid_t
    let field: AXUIElement?

    init?() {
        guard let application = NSWorkspace.shared.frontmostApplication,
              application.processIdentifier != getpid() else { return nil }
        pid = application.processIdentifier
        field = Self.focusedField(pid)
    }

    private static func focusedField(_ pid: pid_t) -> AXUIElement? {
        guard AXIsProcessTrusted() else { return nil }
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.15)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXFocusedUIElementAttribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }

    func paste() -> Bool {
        guard AXIsProcessTrusted(), NSWorkspace.shared.frontmostApplication?.processIdentifier == pid else {
            return false
        }
        if let field {
            guard let current = Self.focusedField(pid), CFEqual(field, current) else { return false }
        }
        let source = CGEventSource(stateID: .privateState)
        guard let down = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_ANSI_V), keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_ANSI_V), keyDown: false) else {
            return false
        }
        down.flags = .maskCommand
        up.flags = .maskCommand
        down.postToPid(pid)
        up.postToPid(pid)
        return true
    }
}

@MainActor
final class DictationApp: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var menuItem: NSStatusItem?
    private var hotkey: Hotkey?
    private var actionHotkey: Hotkey?
    private var actionID: UUID?
    private var actionPayload: ClipboardPayload?
    private var actionGesture: ClipboardGesture?
    private var actionClipboardCount = 0
    private var actionEdit = false
    private var actionReleased = false
    private var actionEarlyResult: String?
    private var settings: Settings?
    private let overlay = Overlay()
    private var microphone: Microphone?
    private var transcription: Transcription?
    private var activeID: UUID?
    private var pasteTarget: PasteTarget?
    private var limit: Task<Void, Never>?
    private var released = false
    private var earlyResult: String?
    private var previewTask: Task<Void, Never>?
    private var startSound: NSSound?

    func applicationDidFinishLaunching(_ notification: Notification) {
        if let index = CommandLine.arguments.firstIndex(of: "--preview-clipboard"),
           CommandLine.arguments.indices.contains(index + 1),
           let image = NSImage(contentsOfFile: CommandLine.arguments[index + 1]) {
            try? loadSettings()
            showClipboardPreview(image)
            return
        }
        if CommandLine.arguments.contains("--preview") {
            try? loadSettings()
            showPreview(standalone: true)
            return
        }
        menuItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        menuItem?.button?.image = NSImage(systemSymbolName: "waveform", accessibilityDescription: "Hold to Dictate")
        menuItem?.button?.toolTip = "Hold to Dictate"
        let menu = NSMenu()
        menu.delegate = self
        menuItem?.menu = menu
        reload()
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let shortcut = settings?.shortcut.uppercased().replacingOccurrences(of: "+", with: " + ") ?? "CMD + SHIFT + K"
        let title = NSMenuItem(title: "Диктовка · \(shortcut)", action: nil, keyEquivalent: "")
        title.isEnabled = false
        menu.addItem(title)
        if let action = settings?.clipboardAction {
            let keys = action.shortcut.uppercased().replacingOccurrences(of: "+", with: " + ")
            let item = NSMenuItem(title: "Буфер обмена · " + keys, action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
        }
        menu.addItem(.separator())
        add("Открыть настройки", #selector(openSettings), to: menu)
        add("Применить настройки", #selector(reload), to: menu)
        add("Показать превью", #selector(preview), to: menu)
        add("Разрешения macOS", #selector(requestPermissions), to: menu)
        let login = add("Запускать при входе", #selector(toggleLogin), to: menu)
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(.separator())
        add("Выйти", #selector(quit), to: menu)
    }

    @discardableResult
    private func add(_ title: String, _ action: Selector, to menu: NSMenu) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        menu.addItem(item)
        return item
    }

    private func loadSettings() throws {
        let newSettings = try Settings.load()
        _ = try Shortcut(newSettings.shortcut)
        _ = try Shortcut(newSettings.clipboardAction.shortcut)
        settings = newSettings
        overlay.appearance = newSettings.appearance
    }

    @objc private func openSettings() {
        do { try Settings.openFile() } catch { overlay.fail("Не удалось открыть settings.json.") }
    }

    @objc private func reload() {
        guard activeID == nil, actionID == nil else { return }
        do {
            let previous = settings
            try loadSettings()
            guard let settings else { return }
            let changed = hotkey == nil || actionHotkey == nil || previous?.shortcut.lowercased() != settings.shortcut.lowercased() || previous?.clipboardAction.shortcut.lowercased() != settings.clipboardAction.shortcut.lowercased()
            guard changed else { return }
            hotkey?.invalidate()
            actionHotkey?.invalidate()
            hotkey = nil
            actionHotkey = nil
            do {
                hotkey = try register(settings.shortcut)
                actionHotkey = try registerAction(settings.clipboardAction.shortcut)
            } catch {
                hotkey?.invalidate()
                actionHotkey?.invalidate()
                hotkey = nil
                actionHotkey = nil
                if let previous {
                    hotkey = try? register(previous.shortcut)
                    actionHotkey = try? registerAction(previous.clipboardAction.shortcut)
                    self.settings = previous
                    overlay.appearance = previous.appearance
                } else {
                    hotkey = try? register(settings.shortcut)
                }
                throw error
            }
        } catch {
            overlay.fail(error is DictationError ? error.localizedDescription : "Проверьте формат settings.json.")
        }
    }

    private func register(_ string: String) throws -> Hotkey {
        try Hotkey(Shortcut(string)) { [weak self] pressed in
            guard let self else { return }
            if pressed { self.start() } else { self.finish() }
        }
    }

    private func registerAction(_ string: String) throws -> Hotkey {
        try Hotkey(Shortcut(string)) { [weak self] pressed in self?.actionKey(pressed) }
    }

    @objc private func requestPermissions() {
        if AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined {
            AVCaptureDevice.requestAccess(for: .audio) { [weak self] _ in
                Task { @MainActor in self?.requestPermissions() }
            }
            return
        }
        if AVCaptureDevice.authorizationStatus(for: .audio) != .authorized {
            openPrivacy("Privacy_Microphone")
            return
        }
        if settings?.engine == .onDevice && SFSpeechRecognizer.authorizationStatus() == .notDetermined {
            SFSpeechRecognizer.requestAuthorization { [weak self] _ in
                Task { @MainActor in self?.requestPermissions() }
            }
            return
        }
        if settings?.engine == .onDevice && SFSpeechRecognizer.authorizationStatus() != .authorized {
            openPrivacy("Privacy_SpeechRecognition")
            return
        }
        if settings?.pasteAutomatically == true && !AXIsProcessTrusted() {
            _ = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
            openPrivacy("Privacy_Accessibility")
        }
    }

    private func openPrivacy(_ anchor: String) {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)") else { return }
        NSWorkspace.shared.open(url)
    }

    @objc private func toggleLogin() {
        do {
            let service = SMAppService.mainApp
            if service.status == .enabled { try service.unregister() } else { try service.register() }
            if service.status == .requiresApproval { SMAppService.openSystemSettingsLoginItems() }
        } catch {
            overlay.fail("Не удалось изменить автозапуск.")
        }
    }

    @objc private func quit() { NSApp.terminate(nil) }

    @objc private func preview() { showPreview(standalone: false) }

    private func showPreview(standalone: Bool) {
        guard activeID == nil, actionID == nil else { return }
        previewTask?.cancel()
        overlay.show()
        previewTask = Task { [weak self] in
            guard let self else { return }
            let phrases = [
                "Раз, два, три.",
                "Раз, два, три. Текст появляется прямо во время записи.",
                "Раз, два, три. Текст появляется прямо во время записи. После отпускания клавиш он останется в буфере обмена и вставится в поле ввода."
            ]
            for step in 0..<100 {
                guard !Task.isCancelled else { return }
                self.overlay.display.level = 0.3 + 0.55 * abs(sin(Double(step) * 0.41))
                self.overlay.update(text: phrases[min(2, step / 13)])
                try? await Task.sleep(for: .milliseconds(65))
            }
            guard !Task.isCancelled else { return }
            self.overlay.dismiss()
            if standalone {
                try? await Task.sleep(for: .milliseconds(450))
                NSApp.terminate(nil)
            }
        }
    }

    private func showClipboardPreview(_ image: NSImage) {
        overlay.show(image: image, clipboard: true)
        overlay.status("Инструкция · Слушаю…", text: "Опиши, что изображено на фотографии.")
        previewTask = Task { [weak self] in
            for step in 0..<100 {
                guard !Task.isCancelled else { return }
                self?.overlay.display.level = 0.25 + 0.55 * abs(sin(Double(step) * 0.41))
                try? await Task.sleep(for: .milliseconds(65))
            }
            NSApp.terminate(nil)
        }
    }

    private func start() {
        guard activeID == nil, actionID == nil, let settings else { return }
        previewTask?.cancel()
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { [weak self] allowed in
                Task { @MainActor in
                    self?.overlay.fail(allowed ? "Микрофон разрешён. Удержите сочетание ещё раз." : "Разрешите доступ к микрофону в настройках macOS.")
                }
            }
            return
        case .authorized: break
        default:
            overlay.fail("Разрешите доступ к микрофону в настройках macOS.")
            return
        }

        if settings.engine == .onDevice && SFSpeechRecognizer.authorizationStatus() != .authorized {
            if SFSpeechRecognizer.authorizationStatus() == .notDetermined {
                SFSpeechRecognizer.requestAuthorization { [weak self] status in
                    Task { @MainActor in
                        self?.overlay.fail(status == .authorized
                            ? "Распознавание разрешено. Удержите сочетание ещё раз."
                            : "Разрешите распознавание речи в настройках macOS.")
                    }
                }
            } else {
                overlay.fail("Разрешите распознавание речи в настройках macOS.")
            }
            return
        }

        let id = UUID()
        activeID = id
        pasteTarget = PasteTarget()
        released = false
        earlyResult = nil
        do {
            let update: (String) -> Void = { [weak self] text in
                guard let self, self.activeID == id else { return }
                self.overlay.update(text: text)
            }
            let complete: (Result<String, Error>) -> Void = { [weak self] result in
                guard let self, self.activeID == id else { return }
                self.completed(result)
            }
            let capture = Microphone()
            let provider: Transcription
            switch settings.engine {
            case .codex:
                provider = try CodexTranscription(update: update, complete: complete)
            case .onDevice:
                provider = try DeviceTranscription(language: settings.language ?? Locale.current.identifier,
                                                   update: update, complete: complete)
            }
            transcription = provider
            microphone = capture
            try capture.start(consume: provider.consume) { [weak self] level in
                Task { @MainActor in
                    guard let self, self.activeID == id, !self.released else { return }
                    self.overlay.display.level = CGFloat(level)
                }
            }
            overlay.show()
            if settings.playSound { playSound(named: settings.startSound ?? "Tink") }
            limit = Task { [weak self] in
                try? await Task.sleep(for: .seconds(240))
                if !Task.isCancelled, self?.activeID == id {
                    self?.completed(.failure(DictationError("Достигнут лимит в четыре минуты.")))
                }
            }
        } catch {
            completed(.failure(error))
        }
    }

    private func actionKey(_ pressed: Bool) {
        let now = ProcessInfo.processInfo.systemUptime
        if actionID == nil {
            guard pressed, activeID == nil, settings != nil else { return }
            let count = NSPasteboard.general.changeCount
            guard let payload = ClipboardPayload.capture(.general), NSPasteboard.general.changeCount == count else { return }
            guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else {
                if AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined {
                    AVCaptureDevice.requestAccess(for: .audio) { [weak self] allowed in
                        Task { @MainActor in self?.overlay.fail(allowed ? "Микрофон разрешён. Нажмите сочетание ещё раз." : "Разрешите доступ к микрофону в настройках macOS.") }
                    }
                } else { overlay.fail("Разрешите доступ к микрофону в настройках macOS.") }
                return
            }
            actionPayload = payload
            actionClipboardCount = count
            if case .image = payload { actionGesture = ClipboardGesture(image: true) }
            else { actionGesture = ClipboardGesture(image: false) }
            _ = actionGesture?.press(now)
            startAction()
            return
        }
        guard !actionReleased else { return }
        let action = pressed ? actionGesture?.press(now) : actionGesture?.release(now)
        switch action {
        case .edit:
            actionEdit = true
            overlay.status("Опишите правку изображения")
        case .finish: finishAction()
        case .some(.none):
            if !pressed, case .image = actionPayload {
                overlay.status(actionEdit ? "Правка · Нажмите ещё раз для завершения" : "Вопрос · Нажмите ещё раз для завершения")
            }
        default: break
        }
    }

    private func startAction() {
        let id = UUID()
        actionID = id
        actionReleased = false
        actionEdit = false
        actionEarlyResult = nil
        previewTask?.cancel()
        do {
            let provider = try CodexTranscription(update: { [weak self] text in
                guard let self, self.actionID == id else { return }
                self.overlay.update(text: text)
            }, complete: { [weak self] result in
                guard let self, self.actionID == id else { return }
                self.actionTranscribed(result)
            })
            transcription = provider
            let capture = Microphone()
            microphone = capture
            try capture.start(consume: provider.consume) { [weak self] level in
                Task { @MainActor in
                    guard let self, self.actionID == id, !self.actionReleased else { return }
                    self.overlay.display.level = CGFloat(level)
                }
            }
            if case .image(let bytes) = actionPayload {
                overlay.show(image: NSImage(data: bytes), clipboard: true)
                overlay.status("Задайте вопрос об изображении")
            } else {
                overlay.show(clipboard: true)
                overlay.status("Что сделать с текстом?")
            }
            if settings?.playSound == true { playSound(named: settings?.startSound ?? "Tink") }
            limit = Task { [weak self] in
                try? await Task.sleep(for: .seconds(240))
                if !Task.isCancelled, self?.actionID == id { self?.actionTranscribed(.failure(DictationError("Достигнут лимит в четыре минуты."))) }
            }
        } catch { actionTranscribed(.failure(error)) }
    }

    private func finishAction() {
        guard actionID != nil, !actionReleased else { return }
        actionReleased = true
        microphone?.stop()
        overlay.status("Распознаю инструкцию…", processing: true)
        if let actionEarlyResult { actionTranscribed(.success(actionEarlyResult)) }
        else { transcription?.finish() }
    }

    private func actionTranscribed(_ result: Result<String, Error>) {
        if case .success(let text) = result, !actionReleased { actionEarlyResult = text; return }
        microphone?.stop()
        transcription?.cancel()
        limit?.cancel()
        microphone = nil
        transcription = nil
        switch result {
        case .failure(let error):
            actionID = nil
            actionPayload = nil
            actionGesture = nil
            overlay.fail(error.localizedDescription)
        case .success(let text):
            let instruction = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !instruction.isEmpty, let payload = actionPayload, let settings, let id = actionID else {
                actionID = nil
                actionPayload = nil
                actionGesture = nil
                overlay.fail("Речь не распознана.")
                return
            }
            let edit = actionEdit
            let count = actionClipboardCount
            overlay.status(edit ? "Редактирую изображение…" : "Готовлю ответ…", text: instruction, processing: true)
            Task { [weak self] in
                let result = await Task.detached {
                    Result { try ClipboardAgent.run(payload: payload, instruction: instruction, edit: edit, settings: settings.clipboardAction) }
                }.value
                guard let self, self.actionID == id else { return }
                self.actionID = nil
                self.actionPayload = nil
                self.actionGesture = nil
                switch result {
                case .failure(let error): self.overlay.fail(error.localizedDescription)
                case .success(let output):
                    let board = NSPasteboard.general
                    guard board.changeCount == count else {
                        switch output {
                        case .text(let text): self.overlay.result(text, copied: false)
                        case .image(let data):
                            self.overlay.image(NSImage(data: data))
                            self.overlay.result("Изображение готово", copied: false)
                        }
                        return
                    }
                    board.clearContents()
                    let written: Bool
                    let preview: String
                    switch output {
                    case .text(let text): written = board.setString(text, forType: .string); preview = text
                    case .image(let data): written = board.setData(data, forType: .png); preview = "Изображение готово"
                    }
                    if written {
                        if case .image(let data) = output { self.overlay.image(NSImage(data: data)) }
                        self.overlay.result(preview)
                    } else {
                        self.overlay.fail("Не удалось записать результат в буфер обмена.")
                    }
                }
            }
        }
    }

    private func playSound(named value: String) {
        if value.hasPrefix("/") || value.hasPrefix("~/") {
            let file = (value as NSString).expandingTildeInPath
            startSound = NSSound(contentsOfFile: file, byReference: true)
        } else {
            startSound = NSSound(named: NSSound.Name(value))
        }
        startSound?.play()
    }

    private func finish() {
        guard activeID != nil, !released else { return }
        released = true
        microphone?.stop()
        overlay.finish()
        if let earlyResult {
            completed(.success(earlyResult))
        } else {
            transcription?.finish()
        }
    }

    private func completed(_ result: Result<String, Error>) {
        microphone?.stop()
        if case let .success(text) = result, !released {
            earlyResult = text
            return
        }

        let target = pasteTarget
        cleanUp()
        switch result {
        case let .success(text):
            let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else {
                overlay.fail("Речь не распознана.")
                return
            }
            let clipboard = NSPasteboard.general
            clipboard.clearContents()
            guard clipboard.setString(text, forType: .string) else {
                overlay.fail("Не удалось записать текст в буфер обмена.")
                return
            }
            let pasted = settings?.pasteAutomatically == true && target?.paste() == true
            overlay.dismiss(copied: !pasted)
        case let .failure(error):
            overlay.fail(error.localizedDescription)
        }
    }

    private func cleanUp() {
        activeID = nil
        microphone?.stop()
        transcription?.cancel()
        limit?.cancel()
        microphone = nil
        transcription = nil
        pasteTarget = nil
        earlyResult = nil
    }

    func applicationWillTerminate(_ notification: Notification) {
        ClipboardAgent.cancelAll()
        cleanUp()
        hotkey?.invalidate()
        actionHotkey?.invalidate()
    }
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = DictationApp()
    app.setActivationPolicy(.accessory)
    app.delegate = delegate
    withExtendedLifetime(delegate) { app.run() }
}
