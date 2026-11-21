using System.Text.Json;

namespace HoldToDictate.WindowsApp;

internal sealed class Transcript
{
    private record Segment(int Revision, string Text, bool Final);
    private readonly List<string> order = [];
    private readonly Dictionary<string, Segment> segments = [];
    public string Text => string.Join(" ", order.Select(id => segments[id].Text.Trim()).Where(t => t.Length > 0));

    public void Update(JsonElement message, bool final)
    {
        string id = message.GetProperty("utterance_id").GetString()
            ?? throw new InvalidDataException("Missing transcript segment ID.");
        string text = message.GetProperty("text").GetString() ?? "";
        int revision = message.GetProperty("revision").GetInt32();
        if (segments.TryGetValue(id, out var old))
        {
            if (old.Final || revision < old.Revision || (revision == old.Revision && !final)) return;
        }
        else order.Add(id);
        segments[id] = new(revision, text, final);
    }
}
