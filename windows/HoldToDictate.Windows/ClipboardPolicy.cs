using System.Text.Json;

namespace HoldToDictate.WindowsApp;

internal static class ClipboardPolicy
{
    public static bool CanWrite(uint captured, uint current) => captured != 0 && captured == current;
    public static string? AgentText(string line)
    {
        try
        {
            using var message = JsonDocument.Parse(line);
            var root = message.RootElement;
            if (!root.TryGetProperty("type", out var eventType)
                || eventType.GetString() is not ("item.updated" or "item.completed")
                || !root.TryGetProperty("item", out var item) || item.ValueKind != JsonValueKind.Object
                || !item.TryGetProperty("type", out var type) || type.GetString() != "agent_message"
                || !item.TryGetProperty("text", out var text) || text.ValueKind != JsonValueKind.String)
                return null;
            return text.GetString();
        }
        catch (Exception e) when (e is JsonException or InvalidOperationException) { return null; }
    }

    public static string? EventType(string line)
    {
        try
        {
            using var message = JsonDocument.Parse(line);
            return message.RootElement.TryGetProperty("type", out var value) && value.ValueKind == JsonValueKind.String
                ? value.GetString() : null;
        }
        catch (Exception e) when (e is JsonException or InvalidOperationException) { return null; }
    }

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

internal sealed class CliTurn
{
    private string? final;
    private bool failed, completed;
    public string? Observe(string json, Action<string>? progress)
    {
        if (failed || completed) return null;
        string? type = ClipboardPolicy.EventType(json);
        if (ClipboardPolicy.AgentText(json) is string text && text.Length > 0)
        {
            if (type == "item.completed") final = text;
            progress?.Invoke(text);
        }
        if (type is "turn.failed" or "error") { failed = true; return null; }
        if (type == "turn.completed")
        {
            completed = true;
            return string.IsNullOrWhiteSpace(final) ? null : final;
        }
        return null;
    }
    public void Feed(string json, Action<string>? progress, TaskCompletionSource<string> terminal)
    {
        string? result = Observe(json, progress);
        if (result is not null) terminal.TrySetResult(result);
        else if (failed || completed) terminal.TrySetException(new IOException("Codex failed or returned no answer."));
    }
    public bool Failed => failed;
    public bool Completed => completed;
}
