using System.Text.Json;
using HoldToDictate.WindowsApp;

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
new Settings().Validate();
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
