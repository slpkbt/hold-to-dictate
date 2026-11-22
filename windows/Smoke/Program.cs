using System.Text.Json;
using System.Diagnostics;
using HoldToDictate.WindowsApp;

if (args.SequenceEqual(new[] { "--fake-child" }))
{
    await Task.Delay(TimeSpan.FromSeconds(30));
    return;
}

static void Check(bool condition, string description)
{
    if (!condition) throw new InvalidOperationException(description);
}

static void Reject(Action operation)
{
    try { operation(); }
    catch (FormatException) { return; }
    throw new InvalidOperationException("Invalid setting was accepted.");
}

var command = Hotkey.Parse(" ctrl + SHIFT + k ");
Check(command.Mods == 6 && command.Key == 'K', "Shortcut parsing");
Check(Hotkey.Parse("alt+f11").Key == 0x7A, "Function key parsing");
Check(Hotkey.Parse("Win+Space").Key == 0x20, "Space key parsing");
Reject(() => Hotkey.Parse("K"));
Reject(() => Hotkey.Parse("Ctrl+Ctrl+K"));
Reject(() => Hotkey.Parse("Ctrl+F12"));
Reject(() => Hotkey.Parse("Ctrl+"));
var held = new HashSet<int> { 'K', 0x10, 0x11 };
Check(command.IsHeld(held.Contains), "All bind keys held");
held.Remove(0x10);
Check(!command.IsHeld(held.Contains), "Lifting a modifier ends the hold");
held.Add(0x10);
held.Remove('K');
Check(!command.IsHeld(held.Contains), "Lifting the main key ends the hold");
Check(ClipboardGesture.IsTap(349) && !ClipboardGesture.IsTap(350), "Image tap versus hold");
Check(ClipboardGesture.IsDoubleTap(400) && !ClipboardGesture.IsDoubleTap(401), "Image double tap window");
new Settings().Validate();
(new Settings { Shortcut = "Ctrl+Shift+L" }).Validate();
(new Settings { AgentReasoningEffort = "max" }).Validate();
Check(ClipboardPolicy.CanWrite(9, 9) && !ClipboardPolicy.CanWrite(9, 10) && !ClipboardPolicy.CanWrite(0, 0), "Stale clipboard stays untouched");
Check(ClipboardPolicy.ThreadId("{\"type\":\"thread.started\",\"thread_id\":\"00000000-0000-0000-0000-000000000001\"}") == "00000000-0000-0000-0000-000000000001", "Trusted thread identifier");
Check(ClipboardPolicy.ThreadId("{\"type\":\"thread.started\",\"thread_id\":\"../../output.png\"}") is null && ClipboardPolicy.ThreadId("bad json") is null, "Reject untrusted output paths");
Check(ClipboardPolicy.AgentText("{\"type\":\"item.updated\",\"item\":{\"type\":\"agent_message\",\"text\":\"partial\"}}") == "partial", "Show agent progress");
Check(ClipboardPolicy.AgentText("{\"type\":\"item.completed\",\"item\":{\"type\":\"command_execution\",\"text\":\"secret\"}}") is null, "Never show tool events");
var turn = new CliTurn();
string? shown = null;
Check(turn.Observe("{\"type\":\"item.updated\",\"item\":{\"type\":\"agent_message\",\"text\":\"part\"}}", t => shown = t) is null && shown == "part", "Partial answer is display only");
Check(turn.Observe("{\"type\":\"item.completed\",\"item\":{\"type\":\"agent_message\",\"text\":\"full\"}}", null) is null, "Do not commit before completed turn");
Check(turn.Observe("{\"type\":\"turn.completed\"}", null) == "full", "Commit only final completed answer");
var failedTurn = new CliTurn();
failedTurn.Observe("{\"type\":\"item.completed\",\"item\":{\"type\":\"agent_message\",\"text\":\"bad\"}}", null);
failedTurn.Observe("{\"type\":\"turn.failed\"}", null);
Check(failedTurn.Observe("{\"type\":\"turn.completed\"}", null) is null, "Failure cannot commit partial answer");
var pending = new TaskCompletionSource<string>(TaskCreationOptions.RunContinuationsAsynchronously);
var failedStream = new CliTurn();
failedStream.Feed("{\"type\":\"turn.failed\"}", null, pending);
try { await pending.Task.WaitAsync(TimeSpan.FromSeconds(2)); throw new Exception("Failure was accepted."); }
catch (IOException) { }
Check(pending.Task.IsFaulted, "Failed turn resolves the pending result");
string cleanupDir = Path.Combine(Path.GetTempPath(), "hold-to-dictate-smoke-" + Guid.NewGuid().ToString("N"));
Directory.CreateDirectory(cleanupDir);
Process StartFake()
{
    var startChild = new ProcessStartInfo(Environment.ProcessPath!) { UseShellExecute = false };
    if (Path.GetFileNameWithoutExtension(Environment.ProcessPath!).Equals("dotnet", StringComparison.OrdinalIgnoreCase))
        startChild.ArgumentList.Add(typeof(ClipboardPolicy).Assembly.Location);
    startChild.ArgumentList.Add("--fake-child");
    return Process.Start(startChild) ?? throw new Exception("Could not start smoke child.");
}
var child = StartFake();
int childId = child.Id;
await CliProcess.ReapAsync(child, cleanupDir, Task.CompletedTask, Task.CompletedTask, TimeSpan.FromMilliseconds(150));
bool childAlive;
try { using var checkChild = Process.GetProcessById(childId); childAlive = !checkChild.HasExited; }
catch (ArgumentException) { childAlive = false; }
Check(!childAlive && !Directory.Exists(cleanupDir), "Timed out process is killed and temporary files are removed");
string cancelDir = Path.Combine(Path.GetTempPath(), "hold-to-dictate-smoke-" + Guid.NewGuid().ToString("N"));
Directory.CreateDirectory(cancelDir);
var cancelledChild = StartFake();
using (var cancelChild = new CancellationTokenSource())
{
    using var registration = cancelChild.Token.Register(() => CliProcess.Kill(cancelledChild));
    cancelChild.Cancel();
    await cancelledChild.WaitForExitAsync().WaitAsync(TimeSpan.FromSeconds(5));
    await CliProcess.ReapAsync(cancelledChild, cancelDir, Task.CompletedTask, Task.CompletedTask, TimeSpan.FromSeconds(1));
}
Check(!Directory.Exists(cancelDir), "Cancellation kills the process and removes its temporary directory");
Reject(() => (new Settings { AgentReasoningEffort = "invalid" }).Validate());
Reject(() => (new Settings { OverlayWidth = 900 }).Validate());
Reject(() => (new Settings { Accent = "#invalid" }).Validate());
Reject(() => (new Settings { Engine = "unset" }).Validate());
Check(!new Settings().PasteAutomatically && new Settings().Engine == "onDevice", "Consent-sensitive defaults");

var transcript = new Transcript();
void Update(string id, string text, int revision, bool final = false)
{
    using var message = JsonDocument.Parse(JsonSerializer.Serialize(new { utterance_id = id, text, revision }));
    transcript.Update(message.RootElement, final);
}
Update("1", " hello ", 1);
Update("2", " world ", 1);
Update("1", "stale", 0);
Check(transcript.Text == "hello world", "Out-of-order events ignored");
Update("1", "Hello,", 1, true);
Update("1", "late", 2);
Update("2", "world!", 2, true);
Update("3", "   ", 1, true);
Check(transcript.Text == "Hello, world!", "Final segments are immutable and empty segments ignored");
Update("4", "Привет", 1, true);
Check(transcript.Text == "Hello, world! Привет", "Non-Latin text preserved");
Console.WriteLine("Windows smoke: settings, hotkey press/release and transcript revision checks passed.");
