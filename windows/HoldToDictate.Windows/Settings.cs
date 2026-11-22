using System.Globalization;
using System.Text.Json;

namespace HoldToDictate.WindowsApp;

internal sealed record Settings
{
    public string Shortcut { get; init; } = "ctrl+shift+k";
    public string Engine { get; init; } = "onDevice";
    public string AgentModel { get; init; } = "gpt-6-luna";
    public string AgentReasoningEffort { get; init; } = "low";
    public string CodexExecutable { get; init; } = "";
    public string Language { get; init; } = "";
    public bool PasteAutomatically { get; init; } = false;
    public bool PlaySound { get; init; } = false;
    public bool StartAtLogin { get; init; } = false;
    public string Accent { get; init; } = "#7BDFFF";
    public int OverlayWidth { get; init; } = 470;

    private static string DirectoryPath => Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "HoldToDictate");
    private static string SettingsPath => Path.Combine(DirectoryPath, "settings.json");
    private static readonly JsonSerializerOptions Json = new()
    {
        PropertyNamingPolicy = JsonNamingPolicy.CamelCase, PropertyNameCaseInsensitive = true,
        WriteIndented = true
    };

    public static Settings Load()
    {
        if (!File.Exists(SettingsPath)) return new();
        var result = JsonSerializer.Deserialize<Settings>(File.ReadAllText(SettingsPath), Json)
            ?? throw new InvalidDataException("The settings file is empty.");
        result.Validate();
        return result;
    }

    public void Validate()
    {
        _ = Hotkey.Parse(Shortcut);
        if (string.IsNullOrWhiteSpace(AgentModel) || AgentModel.Contains('\n') || AgentModel.Contains('\r'))
            throw new FormatException("Enter a valid agent model.");
        if (AgentReasoningEffort is not ("minimal" or "low" or "medium" or "high" or "xhigh" or "max"))
            throw new FormatException("Choose a supported reasoning effort.");
        if (CodexExecutable is null) throw new FormatException("Invalid Codex executable path.");
        if (Engine is not ("onDevice" or "codex")) throw new FormatException("Choose a supported recognition engine.");
        if (Language is null || Accent is null || Accent.Length != 7 || Accent[0] != '#'
            || !uint.TryParse(Accent.AsSpan(1), NumberStyles.HexNumber, CultureInfo.InvariantCulture, out _))
            throw new FormatException("Accent must be a color such as #7BDFFF.");
        if (OverlayWidth is < 320 or > 780) throw new FormatException("Choose an overlay width between 320 and 780.");
    }

    public void Save()
    {
        Validate();
        Directory.CreateDirectory(DirectoryPath);
        var temp = SettingsPath + ".tmp";
        try
        {
            File.WriteAllText(temp, JsonSerializer.Serialize(this, Json));
            File.Move(temp, SettingsPath, overwrite: true);
        }
        finally { if (File.Exists(temp)) File.Delete(temp); }
    }
}

internal readonly record struct Hotkey(uint Mods, uint Key)
{
    private const uint Alt = 1, Control = 2, Shift = 4, Win = 8;
    public const uint NoRepeat = 0x4000;

    public static Hotkey Parse(string value)
    {
        var parts = value?.Trim().ToUpperInvariant().Split('+', StringSplitOptions.TrimEntries)
            ?? throw new FormatException("Enter a shortcut such as Ctrl+Shift+K.");
        uint mods = 0;
        foreach (var modifier in parts.SkipLast(1))
        {
            uint m = modifier switch
            {
                "CTRL" or "CONTROL" => Control, "ALT" => Alt, "SHIFT" => Shift, "WIN" => Win,
                _ => throw new FormatException("Use Ctrl, Alt, Shift or Win as modifiers.")
            };
            if ((mods & m) != 0) throw new FormatException("A modifier may only appear once.");
            mods |= m;
        }
        if (mods == 0) throw new FormatException("Use at least one modifier.");
        var key = parts[^1];
        uint code;
        if (key.Length == 1 && (key[0] is >= 'A' and <= 'Z' or >= '0' and <= '9')) code = key[0];
        else if (key == "SPACE") code = 0x20;
        else if (key.StartsWith('F') && int.TryParse(key.AsSpan(1), NumberStyles.None, CultureInfo.InvariantCulture, out int f)
                 && f is >= 1 and <= 12 && f != 12) code = (uint)(0x6F + f);
        else throw new FormatException("Use A–Z, 0–9, Space or F1–F11 (F12 is reserved).");
        return new(mods, code);
    }

    public bool IsHeld(Func<int, bool> down) => down((int)Key)
        && ((Mods & Alt) == 0 || down(0x12))
        && ((Mods & Control) == 0 || down(0x11))
        && ((Mods & Shift) == 0 || down(0x10))
        && ((Mods & Win) == 0 || down(0x5B) || down(0x5C));
}
