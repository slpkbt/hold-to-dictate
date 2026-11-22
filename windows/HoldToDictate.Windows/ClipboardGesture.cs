namespace HoldToDictate.WindowsApp;

internal static class ClipboardGesture
{
    internal static bool IsTap(double milliseconds) => milliseconds < 350;
    internal static bool IsDoubleTap(double milliseconds) => milliseconds >= 0 && milliseconds <= 400;
}
