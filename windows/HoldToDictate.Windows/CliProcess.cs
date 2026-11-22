using System.Diagnostics;

namespace HoldToDictate.WindowsApp;

internal static class CliProcess
{
    public static void Kill(Process process)
    {
        try { if (!process.HasExited) process.Kill(entireProcessTree: true); } catch { }
    }

    public static async Task ReapAsync(Process process, string directory, Task stdout, Task stderr, TimeSpan timeout)
    {
        try
        {
            using var stop = new CancellationTokenSource(timeout);
            try { await process.WaitForExitAsync(stop.Token); }
            catch (OperationCanceledException)
            {
                Kill(process);
                try { await process.WaitForExitAsync().WaitAsync(TimeSpan.FromSeconds(2)); } catch { }
            }
            try { await Task.WhenAll(stdout, stderr).WaitAsync(TimeSpan.FromSeconds(2)); } catch { }
        }
        catch { }
        finally { process.Dispose(); try { Directory.Delete(directory, recursive: true); } catch { } }
    }
}
