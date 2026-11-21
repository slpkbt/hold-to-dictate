using System.Runtime.InteropServices;
using System.Windows.Automation;

namespace HoldToDictate.WindowsApp;

internal static class Native
{
    [DllImport("user32.dll", SetLastError = true)]
    public static extern bool RegisterHotKey(nint window, int id, uint modifiers, uint key);
    [DllImport("user32.dll", SetLastError = true)]
    public static extern bool UnregisterHotKey(nint window, int id);
    [DllImport("user32.dll")]
    private static extern short GetAsyncKeyState(int key);
    [DllImport("user32.dll")]
    private static extern nint GetForegroundWindow();
    [DllImport("user32.dll")]
    public static extern uint GetClipboardSequenceNumber();
    [DllImport("user32.dll")]
    private static extern uint GetWindowThreadProcessId(nint hwnd, out uint process);
    [DllImport("user32.dll", SetLastError = true)]
    private static extern uint SendInput(uint count, [In] Input[] data, int size);

    public static bool Down(int key) => (GetAsyncKeyState(key) & 0x8000) != 0;
    public static bool AnyModifier => Down(0x11) || Down(0x10) || Down(0x12) || Down(0x5B) || Down(0x5C);
    public static nint Foreground => GetForegroundWindow();

    internal sealed record Target(nint Window, int Process, int[] RuntimeId)
    {
        public static Target? Capture(nint window)
        {
            if (window == 0 || window != Foreground) return null;
            try
            {
                _ = GetWindowThreadProcessId(window, out uint pid);
                var element = AutomationElement.FocusedElement;
                if (element is null || element.Current.IsPassword || element.Current.ProcessId != (int)pid
                    || pid == Environment.ProcessId)
                    return null;
                var id = element.GetRuntimeId();
                return window == Foreground && id is { Length: > 0 } ? new(window, (int)pid, id) : null;
            }
            catch (Exception e) when (e is InvalidOperationException or COMException or TimeoutException)
            {
                return null;
            }
        }

        public bool IsStillFocused()
        {
            var current = Capture(Window);
            return current is not null && current.Process == Process && RuntimeId.SequenceEqual(current.RuntimeId);
        }
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct KeyInput
    {
        public ushort Key, Scan;
        public uint Flags, Time;
        public nuint Extra;
    }
    // SendInput requires the size of the full Win32 union (40 bytes on x64).
    [StructLayout(LayoutKind.Sequential)]
    private struct MouseInput
    {
        public int X, Y;
        public uint MouseData, Flags, Time;
        public nuint Extra;
    }
    [StructLayout(LayoutKind.Explicit)]
    private struct InputUnion
    {
        [FieldOffset(0)] public KeyInput Keyboard;
        [FieldOffset(0)] public MouseInput Mouse;
    }
    [StructLayout(LayoutKind.Sequential)]
    private struct Input
    {
        public uint Type;
        public InputUnion Data;
    }

    private static Input Key(ushort code, bool up) => new()
    {
        Type = 1, Data = new() { Keyboard = new() { Key = code, Flags = up ? 2u : 0u } }
    };

    internal static bool HasExpectedInputLayout => Marshal.SizeOf<Input>() == (Environment.Is64BitProcess ? 40 : 28);

    public static bool Paste()
    {
        Input[] input = [Key(0x11, false), Key(0x56, false), Key(0x56, true), Key(0x11, true)];
        var sent = SendInput((uint)input.Length, input, Marshal.SizeOf<Input>());
        if (sent > 0 && sent < input.Length)
        {
            Input[] undo = [Key(0x56, true), Key(0x11, true)];
            _ = SendInput((uint)undo.Length, undo, Marshal.SizeOf<Input>());
        }
        return sent == input.Length;
    }
}
