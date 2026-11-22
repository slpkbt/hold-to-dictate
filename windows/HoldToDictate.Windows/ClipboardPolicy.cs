using System.Text.Json;

namespace HoldToDictate.WindowsApp;

internal static class ClipboardPolicy
{
    public static bool CanWrite(uint captured, uint current) => captured != 0 && captured == current;
    public static string? ThreadId(string line)
    {
        try
        {
            using var message = JsonDocument.Parse(line);
            var root = message.RootElement;
            if (root.TryGetProperty("type", out var type) && type.GetString() == "thread.started"
                && root.TryGetProperty("thread_id", out var id) && Guid.TryParse(id.GetString(), out var parsed))
                return parsed.ToString("D");
        }
        catch (Exception e) when (e is JsonException or InvalidOperationException) { }
        return null;
    }
}
