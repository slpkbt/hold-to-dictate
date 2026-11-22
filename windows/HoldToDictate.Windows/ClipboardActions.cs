using System.Diagnostics;
using System.Text.Json;
using System.Windows;
using System.Windows.Media.Imaging;
using System.Windows.Threading;

namespace HoldToDictate.WindowsApp;

// Owns the fixed clipboard shortcut independently of the configurable dictation shortcut.
internal sealed class ClipboardActions : IDisposable
{
    internal const int HotkeyId = 101;
    private static readonly Hotkey Key = Hotkey.Parse("Ctrl+Shift+L");
    private readonly Application app;
    private readonly nint window;
    private readonly DispatcherTimer timer;
    private readonly Overlay overlay;
    private readonly Func<bool> dictationBusy;
    private Settings settings;
    private IRecognition? recognition;
    private CancellationTokenSource? operation;
    private string? text;
    private byte[]? image;
    private uint clipboardVersion;
    private DateTime pressed, released, finishDeadline;
    private bool active, finishing, latched, secondPress, edit, registered;
    private int generation;

    public ClipboardActions(Application app, nint window, Settings settings, Func<bool> dictationBusy)
    {
        this.app = app; this.window = window; this.settings = settings; this.dictationBusy = dictationBusy;
        overlay = new Overlay(settings, centered: true);
        registered = Hotkey.Parse(settings.Shortcut) != Key && Native.RegisterHotKey(window, HotkeyId, Key.Mods | Hotkey.NoRepeat, Key.Key);
        timer = new DispatcherTimer(DispatcherPriority.Input, app.Dispatcher) { Interval = TimeSpan.FromMilliseconds(24) };
        timer.Tick += (_, _) => Poll();
        timer.Start();
    }

    public bool Registered => registered;
    public bool Busy => active;
    public void UpdateSettings(Settings value)
    {
        settings = value;
        if (registered && Hotkey.Parse(value.Shortcut) == Key)
        { _ = Native.UnregisterHotKey(window, HotkeyId); registered = false; }
        else if (!registered && Hotkey.Parse(value.Shortcut) != Key)
            registered = Native.RegisterHotKey(window, HotkeyId, Key.Mods | Hotkey.NoRepeat, Key.Key);
    }

    public void Press()
    {
        if (!registered || finishing || dictationBusy()) return;
        if (active)
        {
            if (!latched)
            {
                if (image is null) return;
                // A second WM_HOTKEY proves a release even if polling missed the first tap.
                latched = true; released = DateTime.UtcNow;
            }
            pressed = DateTime.UtcNow;
            secondPress = image is not null && !edit && ClipboardGesture.IsDoubleTap((pressed - released).TotalMilliseconds);
            if (secondPress)
            {
                edit = true;
                overlay.Render("EDIT IMAGE", "Describe the edit. Release after holding, or tap again to finish.", 0);
            }
            else Finish();
            return;
        }
        try
        {
            // File drops can also expose text or thumbnails. They are not clipboard content for this feature.
            clipboardVersion = Native.GetClipboardSequenceNumber();
            if (clipboardVersion == 0) return;
            var data = Clipboard.GetDataObject();
            if (data is null || data.GetDataPresent(DataFormats.FileDrop) || data.GetDataPresent("FileGroupDescriptor")
                || data.GetDataPresent("FileGroupDescriptorW")) return;
            image = null; text = null;
            if (data.GetDataPresent(DataFormats.Bitmap))
            {
                var bitmap = data.GetData(DataFormats.Bitmap) as BitmapSource;
                if (bitmap is null) return;
                var encoder = new PngBitmapEncoder(); encoder.Frames.Add(BitmapFrame.Create(bitmap));
                using var stream = new MemoryStream(); encoder.Save(stream); image = stream.ToArray();
            }
            else if (data.GetDataPresent(DataFormats.UnicodeText) || data.GetDataPresent(DataFormats.Text))
            {
                text = (data.GetData(DataFormats.UnicodeText) ?? data.GetData(DataFormats.Text)) as string;
                if (string.IsNullOrWhiteSpace(text)) return;
            }
            else return;
            if (!ClipboardPolicy.CanWrite(clipboardVersion, Native.GetClipboardSequenceNumber())) return;
            int id = ++generation;
            active = true; finishing = latched = secondPress = edit = false; pressed = DateTime.UtcNow;
            overlay.SetPreview(image);
            overlay.Render(image is null ? "CLIPBOARD TEXT" : "ANALYZE IMAGE", "Speak now. Release to finish.", 0);
            recognition = new CodexRecognition(
                value => app.Dispatcher.BeginInvoke(() => { if (id == generation && active && !string.IsNullOrWhiteSpace(value)) overlay.Render(edit ? "EDIT IMAGE" : "LISTENING", value, null); }),
                level => app.Dispatcher.BeginInvoke(() => { if (id == generation && active && !finishing) overlay.SetLevel(level); }),
                (value, error) => app.Dispatcher.BeginInvoke(() => { if (id == generation) _ = CompleteAsync(id, value, error); }));
        }
        catch { ShowResult("FAILED", "Could not start clipboard action. Check clipboard and Codex sign-in."); }
    }

    private void Poll()
    {
        if (!active) return;
        if (Native.Down(0x1B)) { Cancel(); return; }
        if (finishing)
        {
            if (operation is null && DateTime.UtcNow >= finishDeadline) ShowResult("FAILED", "Recognition did not finish. Try again.");
            return;
        }
        if ((DateTime.UtcNow - pressed).TotalSeconds >= 60) { Finish(); return; }
        if (Key.IsHeld(Native.Down)) return;
        if (!latched)
        {
            if (image is not null && ClipboardGesture.IsTap((DateTime.UtcNow - pressed).TotalMilliseconds))
            {
                latched = true; released = DateTime.UtcNow;
                overlay.Render("ANALYZE IMAGE", "Speak now. Press the shortcut again to finish.", null);
            }
            else Finish();
        }
        else if (secondPress)
        {
            secondPress = false;
            if (!ClipboardGesture.IsTap((DateTime.UtcNow - pressed).TotalMilliseconds)) Finish();
            else overlay.Render("EDIT IMAGE", "Speak now. Press the shortcut again to finish.", null);
        }
    }

    private void Finish()
    {
        if (!active || finishing) return;
        finishing = true; finishDeadline = DateTime.UtcNow.AddSeconds(15); overlay.Status("FINISHING");
        try { recognition?.Finish(); }
        catch { ShowResult("FAILED", "Could not finish recording."); }
    }

    private async Task CompleteAsync(int id, string? instruction, string? error)
    {
        if (!finishing || error is not null) { ShowResult("FAILED", error ?? "Recording stopped unexpectedly."); return; }
        recognition?.Dispose(); recognition = null;
        if (string.IsNullOrWhiteSpace(instruction)) { Cancel(); return; }
        overlay.Render("WORKING", "Running clipboard action…", 0);
        overlay.SetWorking(true);
        operation = new CancellationTokenSource(TimeSpan.FromMinutes(10));
        try
        {
            var result = await ClipboardAgent.RunAsync(settings, image, text, instruction.Trim(), edit, operation.Token);
            if (id != generation) return;
            if (!ClipboardPolicy.CanWrite(clipboardVersion, Native.GetClipboardSequenceNumber()))
            {
                ShowResult("NOT COPIED", "Clipboard changed while the action was running."); return;
            }
            if (result.Image is not null)
            {
                using var stream = new MemoryStream(result.Image);
                var bitmap = new BitmapImage(); bitmap.BeginInit(); bitmap.CacheOption = BitmapCacheOption.OnLoad;
                bitmap.StreamSource = stream; bitmap.EndInit(); bitmap.Freeze();
                Clipboard.SetImage(bitmap);
                overlay.SetPreview(result.Image);
            }
            else Clipboard.SetText(result.Text!);
            ShowResult("DONE", string.IsNullOrWhiteSpace(result.Text) ? "Result copied to clipboard." : result.Text);
        }
        catch (OperationCanceledException) { if (id == generation) ShowResult("FAILED", "Clipboard action timed out."); }
        catch (CodexNotFoundException) { if (id == generation) ShowResult("FAILED", "Codex executable not found. Set its path in Settings."); }
        catch { if (id == generation) ShowResult("FAILED", "Clipboard action failed. Check Codex and try again."); }
    }

    private void ShowResult(string status, string message)
    {
        ++generation; active = finishing = latched = false;
        image = null; text = null;
        recognition?.Dispose(); recognition = null;
        operation?.Dispose(); operation = null;
        overlay.SetWorking(false);
        overlay.Render(status, message, 0);
        int id = generation;
        var delay = new DispatcherTimer { Interval = TimeSpan.FromSeconds(3) };
        delay.Tick += (_, _) => { delay.Stop(); if (id == generation) overlay.HideAnimated(); };
        delay.Start();
    }
    private void Cancel()
    {
        ++generation; active = finishing = latched = false;
        image = null; text = null;
        recognition?.Dispose(); recognition = null;
        operation?.Cancel(); operation?.Dispose(); operation = null;
        overlay.SetWorking(false); overlay.HideAnimated();
    }
    public void Dispose()
    {
        timer.Stop(); Cancel(); overlay.Close();
        if (registered) _ = Native.UnregisterHotKey(window, HotkeyId);
    }
}

internal sealed class CodexNotFoundException : Exception { }

internal static class ClipboardAgent
{
    internal sealed record Result(string? Text, byte[]? Image);

    public static async Task<Result> RunAsync(Settings settings, byte[]? image, string? text, string instruction, bool edit, CancellationToken token)
    {
        string directory = Path.Combine(Path.GetTempPath(), "hold-to-dictate-" + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(directory);
        try
        {
            string kind = image is null ? "text" : edit ? "edit" : "analyze";
            string template = await File.ReadAllTextAsync(Path.Combine(AppContext.BaseDirectory, "clipboard-agent", kind + ".txt"), token);
            string prompt = template + "\n" + JsonSerializer.Serialize(new { instruction, text = image is null ? text : null }, new JsonSerializerOptions { DefaultIgnoreCondition = System.Text.Json.Serialization.JsonIgnoreCondition.WhenWritingNull });
            if (image is not null) await File.WriteAllBytesAsync(Path.Combine(directory, "input.png"), image, token);
            string reply = Path.Combine(directory, "reply.txt");
            var start = new ProcessStartInfo(FindExecutable(settings.CodexExecutable))
            {
                UseShellExecute = false, CreateNoWindow = true, WorkingDirectory = directory,
                RedirectStandardInput = true, RedirectStandardOutput = true, RedirectStandardError = true,
                StandardInputEncoding = new System.Text.UTF8Encoding(false), StandardOutputEncoding = System.Text.Encoding.UTF8
            };
            string? binaryDirectory = Path.GetDirectoryName(start.FileName);
            string? bundledPath = binaryDirectory is null ? null : Path.Combine(binaryDirectory, "..", "path");
            if (bundledPath is not null && Directory.Exists(bundledPath))
                start.Environment["PATH"] = Path.GetFullPath(bundledPath) + Path.PathSeparator + (Environment.GetEnvironmentVariable("PATH") ?? "");
            string[] args =
            [
                "-a", "never", "exec", "--json", "--ephemeral", "--ignore-user-config", "--ignore-rules", "--skip-git-repo-check",
                "-c", "default_permissions=\"clipboard\"",
                "-c", "permissions.clipboard.filesystem={\":root\"=\"deny\", \":workspace_roots\"={\".\"=\"read\"}}",
                "-c", "permissions.clipboard.network.enabled=false", "-c", "project_doc_max_bytes=0", "-c", "mcp_servers={}",
                "--model", settings.AgentModel, "-c", "model_reasoning_effort=\"" + settings.AgentReasoningEffort + "\"",
                "-c", "web_search=\"disabled\"",
                "--disable", "shell_tool", "--disable", "unified_exec", "--disable", "plugins", "--disable", "apps",
                "--disable", "hooks", "--disable", "multi_agent", "--disable", "view_image", "--disable", "browser_use",
                "--disable", "computer_use", edit ? "--enable" : "--disable", "image_generation", "-o", reply
            ];
            foreach (string arg in args) start.ArgumentList.Add(arg);
            if (image is not null) { start.ArgumentList.Add("-i"); start.ArgumentList.Add(Path.Combine(directory, "input.png")); }
            start.ArgumentList.Add("-");
            using var process = Process.Start(start) ?? throw new IOException("Codex did not start.");
            using var cancel = token.Register(() => { try { process.Kill(entireProcessTree: true); } catch { } });
            var stdout = ReadEventsAsync(process.StandardOutput, token);
            var stderr = DrainAsync(process.StandardError, token);
            await process.StandardInput.WriteAsync(prompt.AsMemory(), token); process.StandardInput.Close();
            await process.WaitForExitAsync(token); await Task.WhenAll(stdout, stderr);
            if (process.ExitCode != 0) throw new IOException("Codex failed.");
            if (edit)
            {
                string? thread = await stdout;
                string codexHome = Environment.GetEnvironmentVariable("CODEX_HOME") ?? "";
                if (string.IsNullOrWhiteSpace(codexHome)) codexHome = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), ".codex");
                string? output = thread is null ? null : FindImage(Path.Combine(codexHome, "generated_images", thread));
                output ??= FindImage(Path.Combine(directory, "generated_images"));
                if (output is null) throw new IOException("Image result missing.");
                byte[] bytes = await File.ReadAllBytesAsync(output, token);
                if (bytes.Length < 8 || !bytes.AsSpan(0, 8).SequenceEqual(new byte[] { 137, 80, 78, 71, 13, 10, 26, 10 }))
                    throw new IOException("Invalid image result.");
                return new(null, bytes);
            }
            string answer = await File.ReadAllTextAsync(reply, token);
            if (string.IsNullOrWhiteSpace(answer)) throw new IOException("Empty reply.");
            return new(answer, null);
        }
        finally { try { Directory.Delete(directory, recursive: true); } catch { } }
    }

    private static async Task<string?> ReadEventsAsync(StreamReader reader, CancellationToken token)
    {
        var line = new System.Text.StringBuilder();
        var buffer = new char[4096];
        string? thread = null;
        int count;
        while ((count = await reader.ReadAsync(buffer.AsMemory(), token)) != 0)
            for (int i = 0; i < count; i++)
            {
                if (buffer[i] == '\n')
                {
                    if (thread is null) thread = ClipboardPolicy.ThreadId(line.ToString());
                    line.Clear();
                }
                else if (line.Length < 16384) line.Append(buffer[i]);
            }
        return thread;
    }

    private static async Task DrainAsync(StreamReader reader, CancellationToken token)
    {
        var buffer = new char[4096];
        while (await reader.ReadAsync(buffer.AsMemory(), token) != 0) { }
    }

    private static string? FindImage(string directory)
    {
        if (!Directory.Exists(directory)) return null;
        // Reject links in the result path; never follow a model-provided filename.
        for (DirectoryInfo? part = new DirectoryInfo(directory); part is not null; part = part.Parent)
            if ((part.Attributes & FileAttributes.ReparsePoint) != 0) return null;
        return new DirectoryInfo(directory).EnumerateFiles("*.png", SearchOption.TopDirectoryOnly)
            .Where(file => (file.Attributes & (FileAttributes.ReparsePoint | FileAttributes.Directory)) == 0)
            .OrderByDescending(file => file.LastWriteTimeUtc).Select(file => file.FullName).FirstOrDefault();
    }

    private static string FindExecutable(string configured)
    {
        if (!string.IsNullOrWhiteSpace(configured))
        {
            if (!File.Exists(configured) || !configured.EndsWith(".exe", StringComparison.OrdinalIgnoreCase))
                throw new CodexNotFoundException();
            return Path.GetFullPath(configured);
        }
        var paths = (Environment.GetEnvironmentVariable("PATH") ?? "").Split(Path.PathSeparator, StringSplitOptions.RemoveEmptyEntries)
            .Select(p => p.Trim('"')).Append(Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData), "npm"))
            .Append(Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "Programs", "OpenAI", "Codex", "bin"));
        string architecture = System.Runtime.InteropServices.RuntimeInformation.ProcessArchitecture == System.Runtime.InteropServices.Architecture.Arm64 ? "aarch64" : "x86_64";
        string package = architecture == "aarch64" ? "codex-win32-arm64" : "codex-win32-x64";
        foreach (string path in paths)
        {
            try
            {
                string direct = Path.Combine(path, "codex.exe");
                if (File.Exists(direct)) return direct;
                // Current npm releases use a platform package; older releases bundle vendor in codex.
                foreach (string root in new[] { Path.Combine(path, "node_modules", "@openai"), Path.Combine(path, "node_modules", "@openai", "codex", "node_modules", "@openai"), Path.Combine(path, "..", "lib", "node_modules", "@openai") })
                    foreach (string name in new[] { package, "codex" })
                    {
                        string binary = Path.GetFullPath(Path.Combine(root, name, "vendor", architecture + "-pc-windows-msvc", "codex", "codex.exe"));
                        if (File.Exists(binary)) return binary;
                    }
            }
            catch (Exception e) when (e is ArgumentException or NotSupportedException or PathTooLongException) { }
        }
        throw new CodexNotFoundException();
    }
}
