using NAudio.Wave;
using System.Globalization;
using System.Net.Http;
using System.Net.WebSockets;
using System.Speech.Recognition;
using System.Text.Json;
using System.Threading.Channels;

namespace HoldToDictate.WindowsApp;

internal interface IRecognition : IDisposable
{
    void Finish();
}

internal sealed class LocalRecognition : IRecognition
{
    private readonly SpeechRecognitionEngine engine;
    private readonly List<string> segments = [];

    public static string[] Languages()
    {
        try { return SpeechRecognitionEngine.InstalledRecognizers().Select(r => r.Culture.Name).Distinct().Order().ToArray(); }
        catch (PlatformNotSupportedException) { return []; }
    }

    public LocalRecognition(string language, Action<string> update, Action<int> level,
        Action<string?, string?> completed)
    {
        var recognizers = SpeechRecognitionEngine.InstalledRecognizers();
        var wanted = string.IsNullOrWhiteSpace(language) ? CultureInfo.CurrentUICulture.Name : language;
        var recognizer = recognizers.FirstOrDefault(r => r.Culture.Name.Equals(wanted, StringComparison.OrdinalIgnoreCase))
            ?? (string.IsNullOrWhiteSpace(language) ? recognizers.FirstOrDefault() : null)
            ?? throw new InvalidOperationException("No desktop speech recognizer for this language. See Settings or choose Codex.");
        engine = new(recognizer);
        try
        {
            engine.LoadGrammar(new DictationGrammar());
            engine.SetInputToDefaultAudioDevice();
            engine.AudioLevelUpdated += (_, e) => level(e.AudioLevel);
            engine.SpeechHypothesized += (_, e) =>
                update(string.Join(" ", segments.Append(e.Result.Text)));
            engine.SpeechRecognized += (_, e) =>
            {
                if (!string.IsNullOrWhiteSpace(e.Result.Text)) segments.Add(e.Result.Text);
                update(string.Join(" ", segments));
            };
            engine.RecognizeCompleted += (_, e) =>
            {
                completed(e.Error is null && !e.Cancelled ? string.Join(" ", segments) : null,
                    e.Error is null ? null : "Windows Speech could not finish. Check microphone access and speech language.");
            };
            engine.RecognizeAsync(RecognizeMode.Multiple);
        }
        catch
        {
            engine.Dispose();
            throw;
        }
    }

    public void Finish() => engine.RecognizeAsyncStop();
    public void Dispose()
    {
        try { engine.RecognizeAsyncCancel(); }
        catch (InvalidOperationException) { }
        engine.Dispose();
    }
}

internal sealed class CodexRecognition : IRecognition
{
    // The opt-in uses the same first-party destination as the macOS implementation.
    // Never send the bearer to a redirect, custom endpoint, logs or crash reports.
    private static readonly Uri Endpoint = new(
        "wss://chatgpt.com/backend-api/dictation/stream?dictation_surface=composer&client_type=desktop");
    private readonly ClientWebSocket socket = new();
    private readonly HttpMessageInvoker http = new(new SocketsHttpHandler { AllowAutoRedirect = false, UseCookies = false });
    private readonly Channel<byte[]> audio = Channel.CreateBounded<byte[]>(
        new BoundedChannelOptions(256) { SingleReader = true, FullMode = BoundedChannelFullMode.Wait });
    private readonly CancellationTokenSource cancel = new();
    private readonly Transcript transcript = new();
    private readonly WaveInEvent mic;
    private int stopping, disposed;
    private Task work = Task.CompletedTask;

    public CodexRecognition(Action<string> update, Action<int> level, Action<string?, string?> completed)
    {
        try
        {
            var directory = Environment.GetEnvironmentVariable("CODEX_HOME");
            if (string.IsNullOrWhiteSpace(directory))
                directory = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), ".codex");
            using var account = JsonDocument.Parse(File.ReadAllBytes(Path.Combine(directory, "auth.json")));
            var root = account.RootElement;
            if (root.TryGetProperty("auth_mode", out var mode) && mode.ValueKind != JsonValueKind.Null
                && mode.GetString() != "chatgpt") throw new InvalidDataException();
            var tokens = root.GetProperty("tokens");
            var bearer = tokens.GetProperty("access_token").GetString();
            if (string.IsNullOrWhiteSpace(bearer)) throw new InvalidDataException();
            socket.Options.SetRequestHeader("Authorization", "Bearer " + bearer);
            if (tokens.TryGetProperty("account_id", out var accountId) && accountId.GetString() is string id)
                socket.Options.SetRequestHeader("ChatGPT-Account-Id", id);
            socket.Options.AddSubProtocol("chatgpt-dictation");
            socket.Options.AddSubProtocol("codex-desktop");
            socket.Options.SetRequestHeader("User-Agent", "HoldToDictate/Windows");
        }
        catch
        {
            socket.Dispose(); http.Dispose(); cancel.Dispose();
            throw new InvalidOperationException("Sign in to Codex through ChatGPT using file-based credentials, or choose On-device.");
        }

        mic = new WaveInEvent { DeviceNumber = -1, WaveFormat = new WaveFormat(24000, 16, 1), BufferMilliseconds = 40 };
        mic.DataAvailable += (_, e) =>
        {
            if (Volatile.Read(ref disposed) != 0 || e.BytesRecorded <= 0) return;
            var data = e.Buffer.AsSpan(0, e.BytesRecorded).ToArray();
            if (!audio.Writer.TryWrite(data))
            {
                audio.Writer.TryComplete(new IOException("Audio queue was full."));
                return;
            }
            int peak = 0;
            for (int i = 0; i + 1 < data.Length; i += 2)
                peak = Math.Max(peak, Math.Abs((int)(short)(data[i] | (data[i + 1] << 8))));
            level(Math.Min(100, peak * 100 / 32768));
        };
        mic.RecordingStopped += (_, e) =>
        {
            if (Volatile.Read(ref stopping) == 0 && Volatile.Read(ref disposed) == 0)
                audio.Writer.TryComplete(new IOException("The microphone stopped before key release."));
            else audio.Writer.TryComplete(e.Exception);
        };

        try
        {
            mic.StartRecording();
            work = RunAsync(update, completed);
        }
        catch
        {
            Dispose();
            throw new InvalidOperationException("Could not open the default microphone. Check Windows microphone access.");
        }
    }

    public void Finish()
    {
        if (Interlocked.Exchange(ref stopping, 1) == 0)
        {
            cancel.CancelAfter(TimeSpan.FromSeconds(9));
            mic.StopRecording();
        }
    }

    public void Dispose()
    {
        if (Interlocked.Exchange(ref disposed, 1) != 0) return;
        cancel.Cancel();
        socket.Abort();
        audio.Writer.TryComplete();
        mic.Dispose();
        _ = work.ContinueWith(_ =>
        {
            socket.Dispose();
            http.Dispose();
            cancel.Dispose();
        }, CancellationToken.None, TaskContinuationOptions.ExecuteSynchronously, TaskScheduler.Default);
    }

    private async Task RunAsync(Action<string> update, Action<string?, string?> completed)
    {
        string? result = null;
        string? error = null;
        try
        {
            using var handshake = CancellationTokenSource.CreateLinkedTokenSource(cancel.Token);
            handshake.CancelAfter(TimeSpan.FromSeconds(12));
            await socket.ConnectAsync(Endpoint, http, handshake.Token).ConfigureAwait(false);
            await SendAsync(new
            {
                type = "session.start",
                config = new
                {
                    input_audio_format = "pcm16", sample_rate_hz = 24000, num_channels = 1,
                    max_buffer_size_bytes = 4_194_304, max_utterance_duration_ms = 30_000,
                    session_ttl_ms = 300_000, provider_mode = "streaming_sse", transcript_delivery_mode = "segment",
                    vad = new { type = "server_vad", threshold = 0.5, prefix_padding_ms = 300, silence_duration_ms = 500 }
                }
            }, handshake.Token).ConfigureAwait(false);
            while (true)
            {
                using var message = await ReceiveAsync(handshake.Token).ConfigureAwait(false);
                if (Type(message) == "session.started") break;
                Handle(message, update);
            }
            var send = SendAudioAsync();
            var receive = ReceiveTranscriptAsync(update);
            var first = await Task.WhenAny(send, receive).ConfigureAwait(false);
            if (first.IsFaulted || first.IsCanceled) socket.Abort();
            await Task.WhenAll(send, receive).ConfigureAwait(false);
            result = transcript.Text;
        }
        catch
        {
            error = "Codex dictation could not finish. Check your connection and Codex sign-in, or choose On-device.";
        }
        if (Volatile.Read(ref disposed) == 0) completed(result, error);
    }

    private async Task SendAudioAsync()
    {
        await foreach (var chunk in audio.Reader.ReadAllAsync(cancel.Token).ConfigureAwait(false))
            await SendAsync(new { type = "audio.append", audio = Convert.ToBase64String(chunk) }, cancel.Token).ConfigureAwait(false);
        if (Volatile.Read(ref stopping) == 0) throw new IOException("Recording stopped early.");
        await SendAsync(new { type = "audio.append", audio = Convert.ToBase64String(new byte[12000]) }, cancel.Token).ConfigureAwait(false);
        await SendAsync(new { type = "session.close" }, cancel.Token).ConfigureAwait(false);
    }

    private async Task ReceiveTranscriptAsync(Action<string> update)
    {
        while (true)
        {
            using var message = await ReceiveAsync(cancel.Token).ConfigureAwait(false);
            if (Type(message) == "session.updated" && message.RootElement.TryGetProperty("session", out var session)
                && session.TryGetProperty("status", out var status) && status.GetString() == "closed")
            {
                if (Volatile.Read(ref stopping) == 0) throw new IOException("Session closed early.");
                return;
            }
            Handle(message, update);
        }
    }

    private static string? Type(JsonDocument doc) => doc.RootElement.GetProperty("type").GetString();

    private void Handle(JsonDocument message, Action<string> update)
    {
        var type = Type(message);
        if (type is "transcript.segment" or "transcript.final")
        {
            transcript.Update(message.RootElement, type == "transcript.final");
            update(transcript.Text);
        }
        else if (type is "error" or "transcript.failed"
            || type == "session.error" &&
                (!message.RootElement.TryGetProperty("fatal", out var fatal) || fatal.ValueKind != JsonValueKind.False))
            throw new IOException("Codex rejected transcription.");
    }

    private async Task<JsonDocument> ReceiveAsync(CancellationToken token)
    {
        using var message = new MemoryStream();
        var chunk = new byte[8192];
        ValueWebSocketReceiveResult result;
        do
        {
            result = await socket.ReceiveAsync(chunk.AsMemory(), token).ConfigureAwait(false);
            if (result.MessageType != WebSocketMessageType.Text || message.Length + result.Count > 1_048_576)
                throw new InvalidDataException("Invalid message.");
            message.Write(chunk, 0, result.Count);
        } while (!result.EndOfMessage);
        return JsonDocument.Parse(message.ToArray());
    }

    private ValueTask SendAsync<T>(T message, CancellationToken token) =>
        socket.SendAsync(JsonSerializer.SerializeToUtf8Bytes(message).AsMemory(), WebSocketMessageType.Text, true, token);
}
