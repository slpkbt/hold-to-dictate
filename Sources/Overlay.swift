import AppKit
import SwiftUI

@MainActor
final class DictationDisplay: ObservableObject {
    enum Phase { case listening, finishing, closing, error }

    @Published var phase = Phase.listening
    @Published var text = ""
    @Published var status = "Слушаю…"
    @Published var level: CGFloat = 0
}

private struct DictationView: View {
    @ObservedObject var display: DictationDisplay
    let width: CGFloat
    let height: CGFloat
    let reducedMotion: Bool
    let appearance: Settings.Appearance?

    private var transcriptColor: Color {
        Color(nsColor: appearance?.color ?? NSColor(srgbRed: 0.66, green: 0.85, blue: 1, alpha: 1))
    }

    private var opacity: Double { min(1, max(0.42, appearance?.backgroundOpacity ?? 0.86)) }
    private var textSize: CGFloat { min(24, max(12, appearance?.textSize ?? 16)) }

    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 10) {
                Group {
                    switch display.phase {
                    case .listening:
                        waveform
                    case .finishing:
                        ProgressView()
                            .controlSize(.small)
                            .frame(width: 28)
                    case .closing:
                        Image(systemName: "checkmark")
                            .frame(width: 28)
                    case .error:
                        Image(systemName: "exclamationmark.circle")
                            .frame(width: 28)
                    }
                }
                .foregroundStyle(transcriptColor)

                Text(display.status)
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(1)
                    .foregroundStyle(.white.opacity(0.92))
            }
            .padding(.horizontal, 16)
            .frame(height: 42)
            .background(.black.opacity(opacity), in: Capsule())
            .overlay { Capsule().strokeBorder(.white.opacity(0.18)) }

            if !display.text.isEmpty {
                VStack(alignment: .leading, spacing: 0) {
                    Text(display.text)
                        .font(.system(size: textSize, weight: .medium))
                        .foregroundStyle(transcriptColor)
                        .lineSpacing(4)
                        .contentTransition(.opacity)
                        .animation(reducedMotion ? nil : .easeOut(duration: 0.13), value: display.text)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 13)
                .frame(width: width, height: height, alignment: .bottomLeading)
                .clipped()
                .background(.black.opacity(opacity), in: RoundedRectangle(cornerRadius: 15))
                .overlay { RoundedRectangle(cornerRadius: 15).strokeBorder(.white.opacity(0.17)) }
                .clipped()
                .transition(.offset(y: 10).combined(with: .opacity))
            }
        }
        .animation(reducedMotion ? nil : .easeOut(duration: 0.16), value: display.phase)
        .animation(reducedMotion ? nil : .easeOut(duration: 0.18), value: display.text.isEmpty)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .padding(8)
        .accessibilityElement(children: .contain)
    }

    private var waveform: some View {
        HStack(spacing: 2) {
            ForEach(0..<7) { bar in
                let envelope: [CGFloat] = [0.26, 0.53, 0.78, 1, 0.67, 0.83, 0.36]
                Capsule()
                    .fill(transcriptColor.opacity(0.71 + envelope[bar] * 0.29))
                    .frame(width: 2, height: 3 + (reducedMotion ? 4 : 16 * display.level) * envelope[bar])
            }
        }
        .frame(width: 28, height: 20)
        .animation(reducedMotion ? nil : .linear(duration: 0.07), value: display.level)
        .accessibilityHidden(true)
    }
}

private final class DictationPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

@MainActor
final class Overlay {
    let display = DictationDisplay()
    var appearance: Settings.Appearance?
    private var panel: DictationPanel?
    private var host: NSHostingView<DictationView>?
    private var screenFrame = CGRect.zero
    private var hideWork: DispatchWorkItem?

    private var reducedMotion: Bool {
        appearance?.reduceMotion == true || NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    func show() {
        hideWork?.cancel()
        let mouse = NSEvent.mouseLocation
        screenFrame = (NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main)?.visibleFrame
            ?? CGRect(x: 0, y: 0, width: 1024, height: 768)
        display.phase = .listening
        display.status = "Слушаю…"
        display.text = ""
        display.level = 0
        if panel == nil {
            let panel = DictationPanel(
                contentRect: CGRect(x: 0, y: 0, width: 220, height: 58),
                styleMask: [.borderless, .nonactivatingPanel],
                backing: .buffered, defer: false
            )
            panel.backgroundColor = .clear
            panel.isOpaque = false
            panel.isReleasedWhenClosed = false
            panel.hasShadow = false
            panel.ignoresMouseEvents = true
            panel.hidesOnDeactivate = false
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
            panel.level = .floating
            let host = NSHostingView(rootView: view(width: 220, height: 0))
            host.sizingOptions = []
            panel.contentView = host
            self.panel = panel
            self.host = host
        }
        resize()
        panel?.alphaValue = reducedMotion ? 1 : 0
        panel?.orderFrontRegardless()
        animateOpacity(to: 1, duration: 0.16)
    }

    func update(text: String) {
        // The clipboard gets the full text. Showing the tail keeps layout work bounded.
        let visibleText = String(text.suffix(1_100))
        guard display.text != visibleText else { return }
        display.text = visibleText
        resize()
    }

    func finish() {
        display.phase = .finishing
        display.status = "Завершаю…"
    }

    func dismiss(copied: Bool = false) {
        guard panel?.isVisible == true else { return }
        display.phase = .closing
        display.status = copied ? "Скопировано" : "Готово"
        display.text = ""
        scheduleHide(after: copied ? 0.55 : 0.16)
    }

    func fail(_ message: String) {
        if panel?.isVisible != true { show() }
        display.phase = .error
        display.status = "Диктовка недоступна"
        update(text: message)
        scheduleHide(after: 3.4)
    }

    private func view(width: CGFloat, height: CGFloat) -> DictationView {
        DictationView(display: display, width: width, height: height, reducedMotion: reducedMotion,
                      appearance: appearance)
    }

    private func resize() {
        guard let panel, let host else { return }
        let width = min(max(240, appearance?.width ?? 490), screenFrame.width - 32)
        let size = min(24, max(12, appearance?.textSize ?? 16))
        let font = NSFont.systemFont(ofSize: size, weight: .medium)
        let measured = (display.text as NSString).boundingRect(
            with: CGSize(width: width - 32, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [
                .font: font,
                .paragraphStyle: {
                    let style = NSMutableParagraphStyle()
                    style.lineSpacing = 4
                    return style
                }()
            ]
        )
        let lines = min(14, max(2, appearance?.maxLines ?? 6))
        let cap = min(screenFrame.height / 2 - 36, (ceil(font.ascender - font.descender) + 4) * CGFloat(lines) + 25)
        let height = min(cap, max(46, ceil(measured.height) + 29))
        host.rootView = view(width: width, height: height)
        // Keep space beneath the capsule for the text to animate out on release.
        let panelHeight = display.text.isEmpty ? 58 : 66 + height
        let offset = min(screenFrame.height * 0.38, max(-screenFrame.height * 0.21, appearance?.verticalOffset ?? 68))
        let top = max(screenFrame.minY + panelHeight + 8, screenFrame.midY + offset)
        let centered = screenFrame.midX - (width + 16) / 2
        let x = min(screenFrame.maxX - width - 16, max(screenFrame.minX, centered + (appearance?.horizontalOffset ?? 0)))
        let frame = CGRect(x: x, y: top - panelHeight,
                           width: width + 16, height: panelHeight)
        panel.setFrame(frame, display: true)
    }

    private func animateOpacity(to alpha: CGFloat, duration: TimeInterval) {
        guard let panel else { return }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = reducedMotion ? 0 : duration
            panel.animator().alphaValue = alpha
        }
    }

    private func scheduleHide(after delay: TimeInterval) {
        hideWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, let panel = self.panel else { return }
            let duration = self.reducedMotion ? 0.0 : 0.16
            NSAnimationContext.runAnimationGroup { context in
                context.duration = duration
                panel.animator().alphaValue = 0
            } completionHandler: { [weak self] in
                guard self?.panel?.alphaValue == 0 else { return }
                self?.panel?.orderOut(nil)
            }
        }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }
}
