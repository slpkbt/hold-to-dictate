using Microsoft.Win32;
using System.Diagnostics;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Interop;
using System.Windows.Media;
using System.Windows.Shapes;

namespace HoldToDictate.WindowsApp;

internal static class Theme
{
    public static SolidColorBrush Color(string value) => new((Color)ColorConverter.ConvertFromString(value));
    public static readonly Brush Page = Color("#141821"), Card = Color("#1C2431"), Border = Color("#334459"),
        Text = Color("#F2F7FF"), Muted = Color("#99ACC5");
}

internal sealed class Overlay : Window
{
    private readonly TextBlock label, caption;
    private readonly Rectangle[] wave = new Rectangle[24];
    private readonly double configuredWidth;

    public Overlay(Settings settings)
    {
        configuredWidth = settings.OverlayWidth;
        SizeToContent = SizeToContent.Height;
        WindowStyle = WindowStyle.None;
        ResizeMode = ResizeMode.NoResize;
        AllowsTransparency = true;
        Background = Brushes.Transparent;
        ShowActivated = false;
        Focusable = false;
        ShowInTaskbar = false;
        Topmost = true;
        UseLayoutRounding = true;
        var accent = Theme.Color(settings.Accent);
        var box = new StackPanel();
        label = new TextBlock { Foreground = accent, FontSize = 11, FontWeight = FontWeights.SemiBold };
        box.Children.Add(label);
        var meter = new StackPanel { Orientation = Orientation.Horizontal, Height = 22, Margin = new Thickness(0, 5, 0, 4) };
        for (int i = 0; i < wave.Length; ++i)
        {
            wave[i] = new Rectangle { Width = 4, Height = 3, Fill = accent, RadiusX = 2, RadiusY = 2,
                Margin = new Thickness(0, 0, 4, 0), VerticalAlignment = VerticalAlignment.Center };
            meter.Children.Add(wave[i]);
        }
        box.Children.Add(meter);
        caption = new TextBlock { Foreground = Theme.Text, FontSize = 16, TextWrapping = TextWrapping.Wrap,
            MaxHeight = 85, TextTrimming = TextTrimming.CharacterEllipsis };
        box.Children.Add(caption);
        Content = new Border { Padding = new Thickness(17, 12, 17, 14), Child = box, CornerRadius = new CornerRadius(17),
            Background = Theme.Page, BorderBrush = Theme.Border, BorderThickness = new Thickness(1) };
        SourceInitialized += (_, _) =>
        {
            if (PresentationSource.FromVisual(this) is HwndSource source)
            {
                source.AddHook(OverlayMessage);
                source.CompositionTarget.BackgroundColor = Colors.Transparent;
            }
        };
    }

    private static nint OverlayMessage(nint window, int msg, nint w, nint l, ref bool handled)
    {
        if (msg == 0x0021) { handled = true; return 3; } // MA_NOACTIVATE
        if (msg == 0x0084) { handled = true; return -1; } // HTTRANSPARENT
        return 0;
    }

    public void Status(string status) => label.Text = status;
    public void Render(string status, string text, int? level)
    {
        Status(status);
        caption.Text = text.Length <= 420 ? text : "…" + text[^419..];
        if (level is not null) SetLevel(level.Value);
        if (!IsVisible)
        {
            var work = SystemParameters.WorkArea;
            Width = Math.Min(configuredWidth, Math.Max(200, work.Width - 36));
            Left = work.Left + (work.Width - Width) / 2;
            Top = work.Top + Math.Max(8, work.Height - 155);
            Show();
        }
    }

    public void SetLevel(int percent)
    {
        for (int i = 0; i < wave.Length; ++i)
        {
            var ratio = Math.Min(1, Math.Max(0, percent) / 85.0);
            wave[i].Height = 3 + 16 * ratio * (0.23 + 0.77 * Math.Abs(Math.Sin(i * 1.17)));
            wave[i].Opacity = 0.42 + ratio * 0.58;
        }
    }
}

internal sealed class SettingsWindow : Window
{
    private const string LoginKey = @"Software\Microsoft\Windows\CurrentVersion\Run";
    private const string LoginName = "HoldToDictate";
    private readonly TextBox shortcut, accent, width;
    private readonly ComboBox engine, language;
    private readonly CheckBox paste, sound, login;
    private readonly TextBlock note;

    public SettingsWindow(Settings current, Action<Settings> save)
    {
        Title = "Hold to Dictate · Settings";
        Width = 500; Height = 660; MinWidth = 405; MinHeight = 410;
        WindowStartupLocation = WindowStartupLocation.CenterScreen;
        Background = Theme.Page; Foreground = Theme.Text; UseLayoutRounding = true;
        var panel = new StackPanel { Margin = new Thickness(24) };
        Content = new ScrollViewer { VerticalScrollBarVisibility = ScrollBarVisibility.Auto, Content = panel };
        panel.Children.Add(new TextBlock { Text = "Make it yours.", FontSize = 26, FontWeight = FontWeights.SemiBold });
        panel.Children.Add(new TextBlock { Text = "Hold a shortcut. Speak. Let go.", Foreground = Theme.Muted,
            Margin = new Thickness(0, 4, 0, 11) });
        shortcut = new TextBox { Text = current.Shortcut };
        engine = new ComboBox { ItemsSource = new[] { "On-device (Windows Speech)", "Codex (streams to ChatGPT)" },
            SelectedIndex = current.Engine == "codex" ? 1 : 0 };
        string[] languages;
        try { languages = LocalRecognition.Languages(); }
        catch { languages = []; }
        language = new ComboBox { ItemsSource = new[] { "" }.Concat(languages).ToArray(), IsEditable = true, Text = current.Language };
        accent = new TextBox { Text = current.Accent };
        width = new TextBox { Text = current.OverlayWidth.ToString(System.Globalization.CultureInfo.InvariantCulture) };

        void Field(string label, Control control)
        {
            panel.Children.Add(new TextBlock { Text = label, Margin = new Thickness(0, 9, 0, 4), Foreground = Theme.Muted });
            control.MinHeight = 24;
            System.Windows.Automation.AutomationProperties.SetName(control, label);
            panel.Children.Add(control);
        }
        CheckBox Check(string text, bool value)
        {
            var box = new CheckBox { Content = text, Foreground = Theme.Text, IsChecked = value,
                Margin = new Thickness(0, 8, 0, 0) };
            panel.Children.Add(box);
            return box;
        }

        Field("Global shortcut", shortcut);
        Field("Recognition engine", engine);
        Field("Windows Speech language (blank = automatic)", language);
        Field("Overlay accent (#RRGGBB)", accent);
        Field("Overlay width (320–780)", width);
        paste = Check("Paste into the original field when safe (always copies)", current.PasteAutomatically);
        sound = Check("Play a sound when recording starts", current.PlaySound);
        login = Check("Launch at sign-in", current.StartAtLogin);
        note = new TextBlock { Foreground = Theme.Muted, TextWrapping = TextWrapping.Wrap,
            Margin = new Thickness(0, 12, 0, 8) };
        panel.Children.Add(note);
        void Describe() => note.Text = engine.SelectedIndex == 1
            ? "Codex uses your file-based ChatGPT sign-in and sends the microphone stream to chatgpt.com while dictating. The private protocol may change."
            : languages.Length == 0
                ? "No desktop speech recognizer found. Install Windows Speech for a supported language or opt in to Codex."
                : "On-device recognition never sends your audio to the internet.";
        engine.SelectionChanged += (_, _) => { language.IsEnabled = engine.SelectedIndex == 0; Describe(); };
        language.IsEnabled = engine.SelectedIndex == 0;
        Describe();

        var buttons = new StackPanel { Orientation = Orientation.Horizontal, Margin = new Thickness(0, 5, 0, 0) };
        panel.Children.Add(buttons);
        var saveButton = new Button { Content = "Save", Padding = new Thickness(14, 5, 14, 5), IsDefault = true };
        var micButton = new Button { Content = "Microphone privacy", Padding = new Thickness(10, 5, 10, 5),
            Margin = new Thickness(8, 0, 0, 0) };
        var close = new Button { Content = "Cancel", IsCancel = true, Padding = new Thickness(10, 5, 10, 5),
            Margin = new Thickness(8, 0, 0, 0) };
        buttons.Children.Add(saveButton); buttons.Children.Add(micButton); buttons.Children.Add(close);
        micButton.Click += (_, _) =>
        {
            try { Process.Start(new ProcessStartInfo("ms-settings:privacy-microphone") { UseShellExecute = true }); }
            catch { note.Text = "Open Windows Settings → Privacy & security → Microphone."; }
        };
        saveButton.Click += (_, _) =>
        {
            try
            {
                if (!int.TryParse(width.Text.Trim(), out int parsedWidth))
                    throw new FormatException("Overlay width must be a whole number.");
                save(current with
                {
                    Shortcut = shortcut.Text.Trim(), Engine = engine.SelectedIndex == 1 ? "codex" : "onDevice",
                    Language = language.Text.Trim(), Accent = accent.Text.Trim(), OverlayWidth = parsedWidth,
                    PasteAutomatically = paste.IsChecked == true, PlaySound = sound.IsChecked == true,
                    StartAtLogin = login.IsChecked == true
                });
                DialogResult = true;
            }
            catch (Exception ex)
            {
                MessageBox.Show(this, ex is FormatException or InvalidOperationException ? ex.Message :
                    "Could not save settings or apply launch at sign-in.", "Settings not saved", MessageBoxButton.OK, MessageBoxImage.Warning);
            }
        };
    }

    public static void SetLogin(bool enabled)
    {
        using var key = Registry.CurrentUser.CreateSubKey(LoginKey, writable: true);
        if (!enabled) { key.DeleteValue(LoginName, throwOnMissingValue: false); return; }
        var exe = Environment.ProcessPath ?? throw new InvalidOperationException("Could not find the application executable.");
        key.SetValue(LoginName, "\"" + exe + "\"", RegistryValueKind.String);
    }
}
