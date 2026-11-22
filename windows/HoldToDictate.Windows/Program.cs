using System.Windows;
using System.Windows.Interop;
using System.Windows.Threading;
using Forms = System.Windows.Forms;

namespace HoldToDictate.WindowsApp;

internal static class Program
{
    [STAThread]
    public static int Main(string[] args)
    {
        if (args.SequenceEqual(new[] { "--self-test" }))
        {
            try
            {
                var overlay = new Overlay(new());
                overlay.SetLevel(20);
                overlay.Close();
                var centered = new Overlay(new(), centered: true);
                centered.Render("PREVIEW", "Preview", 0);
                centered.HideAnimated();
                centered.Close();
                return Hotkey.Parse("Ctrl+Shift+K").Key == 'K' && Native.HasExpectedInputLayout
                    && new[] { "text", "analyze", "edit" }.All(name => File.Exists(Path.Combine(AppContext.BaseDirectory, "clipboard-agent", name + ".txt"))) ? 0 : 1;
            }
            catch { return 1; }
        }
        bool preview = args.SequenceEqual(new[] { "--preview" });
        using var mutex = new Mutex(true, @"Local\HoldToDictate.Windows", out bool unique);
        if (!unique && !preview)
        {
            MessageBox.Show("Hold to Dictate is already in the notification area.", "Hold to Dictate");
            return 0;
        }

        var app = new Application { ShutdownMode = ShutdownMode.OnExplicitShutdown };
        if (preview)
        {
            var overlay = new Overlay(new());
            overlay.Render("PREVIEW", "Hold the shortcut, speak naturally, and release to type.", 72);
            var timer = new DispatcherTimer { Interval = TimeSpan.FromSeconds(5) };
            timer.Tick += (_, _) => { timer.Stop(); overlay.Close(); app.Shutdown(); };
            timer.Start();
            return app.Run();
        }

        using var tray = new TrayController(app);
        return app.Run();
    }
}

internal sealed class TrayController : IDisposable
{
    private const int HotkeyId = 100;
    private readonly Application app;
    private readonly HwndSource messageWindow;
    private readonly Forms.NotifyIcon tray;
    private readonly DispatcherTimer timer;
    private Settings settings;
    private Hotkey shortcut;
    private bool registered;
    private bool disposed;
    private Overlay overlay;
    private IRecognition? recognition;
    private nint originalForeground;
    private Task<Native.Target?>? originalTarget;
    private DateTime listenUntil;
    private DateTime finishUntil;
    private bool listening, finishing, focusUnchanged;
    private int generation;
    private readonly ClipboardActions clipboardActions;
    private readonly Forms.ContextMenuStrip menu = new();
    private readonly Forms.ToolStripMenuItem status = new() { Enabled = false };

    public TrayController(Application app)
    {
        this.app = app;
        string? warning = null;
        try { settings = Settings.Load(); }
        catch { settings = new(); warning = "Settings could not be read. Using defaults; open Settings to repair them."; }

        messageWindow = new HwndSource(new HwndSourceParameters("Hold to Dictate | Hotkey")
        {
            ParentWindow = new nint(-3), WindowStyle = 0, Width = 0, Height = 0
        });
        messageWindow.AddHook(WindowMessage);
        clipboardActions = new ClipboardActions(app, messageWindow.Handle, settings, () => listening || finishing);
        overlay = new Overlay(settings);
        timer = new DispatcherTimer(DispatcherPriority.Input, app.Dispatcher)
        {
            Interval = TimeSpan.FromMilliseconds(24)
        };
        timer.Tick += (_, _) => Poll();
        timer.Start();

        menu.Items.Add(status);
        menu.Items.Add("Settings…", null, (_, _) => OpenSettings());
        menu.Items.Add("Preview overlay", null, (_, _) => Preview());
        menu.Items.Add(new Forms.ToolStripSeparator());
        menu.Items.Add("Exit", null, (_, _) => app.Shutdown());
        tray = new Forms.NotifyIcon
        {
            Icon = System.Drawing.SystemIcons.Application, Text = "Hold to Dictate",
            ContextMenuStrip = menu, Visible = true
        };
        tray.DoubleClick += (_, _) => OpenSettings();
        try { InstallHotkey(Hotkey.Parse(settings.Shortcut)); }
        catch (InvalidOperationException) { warning = "Shortcut is unavailable. Choose another one in Settings."; }
        RefreshStatus();
        if (!clipboardActions.Registered) warning = "Ctrl+Shift+L is unavailable. Clipboard actions are disabled.";
        if (warning is not null) Notice(warning);
    }

    private nint WindowMessage(nint hwnd, int message, nint wParam, nint lParam, ref bool handled)
    {
        if (message == 0x0312 && wParam == ClipboardActions.HotkeyId)
        {
            handled = true;
            clipboardActions.Press();
        }
        if (message == 0x0312 && wParam == HotkeyId)
        {
            handled = true;
            if (!listening && !finishing && !clipboardActions.Busy && shortcut.IsHeld(Native.Down)) Start();
        }
        return 0;
    }

    private void InstallHotkey(Hotkey value)
    {
        if (!Native.RegisterHotKey(messageWindow.Handle, HotkeyId, value.Mods | Hotkey.NoRepeat, value.Key))
            throw new InvalidOperationException("That shortcut is already in use or reserved by Windows.");
        shortcut = value;
        registered = true;
    }

    private void RemoveHotkey()
    {
        if (registered) _ = Native.UnregisterHotKey(messageWindow.Handle, HotkeyId);
        registered = false;
    }

    private void RefreshStatus() => status.Text = registered
        ? ((settings.Engine == "codex" ? "Codex" : "On-device") + " · " + settings.Shortcut.ToUpperInvariant())
        : "No shortcut registered";

    private void Start()
    {
        int id = ++generation;
        originalForeground = Native.Foreground;
        nint window = originalForeground;
        originalTarget = settings.PasteAutomatically ? Task.Run(() => Native.Target.Capture(window)) : null;
        focusUnchanged = originalForeground != 0;
        listening = true;
        listenUntil = DateTime.UtcNow.AddSeconds(60);
        overlay.Render("LISTENING", "Speak now. Release to finish.", 0);
        if (settings.PlaySound) System.Media.SystemSounds.Asterisk.Play();

        void Update(string text) => app.Dispatcher.BeginInvoke(() =>
        {
            if (generation == id && (listening || finishing) && !string.IsNullOrWhiteSpace(text))
                overlay.Render(finishing ? "FINISHING" : "LISTENING", text, null);
        });
        void Level(int n) => app.Dispatcher.BeginInvoke(() =>
        {
            if (generation == id && listening) overlay.SetLevel(n);
        });
        void Complete(string? text, string? error) =>
            app.Dispatcher.BeginInvoke(() => { if (generation == id) _ = CompleteAsync(id, text, error); });

        try
        {
            recognition = settings.Engine == "codex" ? new CodexRecognition(Update, Level, Complete)
                : new LocalRecognition(settings.Language, Update, Level, Complete);
        }
        catch (Exception e)
        {
            var message = e is InvalidOperationException ? e.Message : "Could not start dictation. Check microphone access and Settings.";
            Fail(message);
        }
    }

    private void Poll()
    {
        if (!listening && !finishing) return;
        if (Native.Foreground != originalForeground) focusUnchanged = false;
        if (Native.Down(0x1B)) { Cancel(); return; }
        if (listening && (DateTime.UtcNow >= listenUntil || !shortcut.IsHeld(Native.Down)))
        {
            listening = false;
            finishing = true;
            finishUntil = DateTime.UtcNow.AddSeconds(10);
            overlay.Status("FINISHING");
            try { recognition?.Finish(); }
            catch { Fail("Could not finish dictation."); }
        }
        else if (finishing && DateTime.UtcNow >= finishUntil)
            Fail("Recognition did not finish. Try again.");
    }

    private async Task CompleteAsync(int id, string? text, string? error)
    {
        if (listening && error is null) { Fail("Recognition stopped before key release. Try a shorter recording."); return; }
        if (error is not null) { Fail(error); return; }
        DisposeRecognition();
        text = text?.Trim();
        if (string.IsNullOrWhiteSpace(text)) { Cancel(); return; }
        // Keep polling foreground/Esc while clipboard contention or focus lookup resolves.
        finishUntil = DateTime.UtcNow.AddSeconds(3);
        try
        {
            for (int i = 0; ; ++i)
            {
                if (id != generation) return;
                try { Clipboard.SetText(text); break; }
                catch (System.Runtime.InteropServices.ExternalException) when (i < 4) { await Task.Delay(45); }
            }
        }
        catch
        {
            Fail("The clipboard is busy. The transcript was not pasted.");
            return;
        }

        uint clipboardVersion = Native.GetClipboardSequenceNumber();
        bool pasted = false;
        if (settings.PasteAutomatically && focusUnchanged && originalTarget is not null)
        {
            for (int i = 0; i < 12 && Native.AnyModifier; ++i) await Task.Delay(45);
            if (generation != id) return;
            try
            {
                var target = await originalTarget.WaitAsync(TimeSpan.FromMilliseconds(350));
                var same = target is not null && await Task.Run(target.IsStillFocused).WaitAsync(TimeSpan.FromMilliseconds(350));
                if (generation != id) return;
                if (focusUnchanged && same && target!.Window == Native.Foreground && !Native.AnyModifier
                    && clipboardVersion != 0 && clipboardVersion == Native.GetClipboardSequenceNumber())
                    pasted = Native.Paste();
            }
            catch { /* clipboard-only fallback */ }
        }
        if (generation != id) return;
        Cancel();
        if (!pasted && settings.PasteAutomatically) Notice("Copied. Paste manually with Ctrl+V.");
    }

    private void Preview()
    {
        if (listening || finishing) return;
        int id = generation;
        overlay.Render("PREVIEW", "A quiet overlay for whatever you’re saying.", 65);
        var delay = new DispatcherTimer { Interval = TimeSpan.FromSeconds(4) };
        delay.Tick += (_, _) => { delay.Stop(); if (!disposed && id == generation) overlay.Hide(); };
        delay.Start();
    }

    private void OpenSettings()
    {
        Cancel();
        var dialog = new SettingsWindow(settings, ApplySettings);
        dialog.ShowDialog();
    }

    private void ApplySettings(Settings next)
    {
        next.Validate();
        var previous = settings;
        var currentHotkey = shortcut;
        bool hadHotkey = registered;
        bool newShortcut = !registered || Hotkey.Parse(next.Shortcut) != shortcut;
        try
        {
            if (newShortcut)
            {
                RemoveHotkey();
                clipboardActions.UpdateSettings(next);
                InstallHotkey(Hotkey.Parse(next.Shortcut));
            }
            if (previous.StartAtLogin != next.StartAtLogin) SettingsWindow.SetLogin(next.StartAtLogin);
            next.Save();
        }
        catch
        {
            if (previous.StartAtLogin != next.StartAtLogin)
                try { SettingsWindow.SetLogin(previous.StartAtLogin); } catch { }
            if (newShortcut)
            {
                RemoveHotkey();
                clipboardActions.UpdateSettings(previous);
                if (hadHotkey) try { InstallHotkey(currentHotkey); } catch { }
            }
            RefreshStatus();
            throw;
        }
        settings = next;
        clipboardActions.UpdateSettings(next);
        overlay.Close();
        overlay = new Overlay(settings);
        RefreshStatus();
    }

    private void DisposeRecognition()
    {
        try { recognition?.Dispose(); } catch { }
        recognition = null;
    }
    private void Cancel()
    {
        ++generation;
        listening = finishing = false;
        DisposeRecognition();
        originalTarget = null;
        overlay.Hide();
    }
    private void Fail(string error) { Cancel(); Notice(error); }
    private void Notice(string text) => tray.ShowBalloonTip(2600, "Hold to Dictate", text, Forms.ToolTipIcon.Info);
    public void Dispose()
    {
        disposed = true;
        clipboardActions.Dispose();
        timer.Stop();
        RemoveHotkey();
        Cancel();
        overlay.Close();
        messageWindow.Dispose();
        tray.Visible = false;
        tray.Dispose();
        menu.Dispose();
    }
}
