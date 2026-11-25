using System.Diagnostics;
using System.IO.Compression;
using System.Net.Http;
using System.Reflection;
using System.Security.Cryptography;
using System.Text.Json;

namespace Ros2Setup;

internal sealed record Payload(string Group, string File, string Url, string Sha256);

internal static class Payloads
{
    public static readonly Payload[] All = ReadManifest();

    private static Payload[] ReadManifest()
    {
        using var stream = Assembly.GetExecutingAssembly().GetManifestResourceStream("payloads.json")!;
        return JsonSerializer.Deserialize<Payload[]>(stream)!;
    }

    public static async Task VerifyAsync(string path, string expected)
    {
        if (!File.Exists(path))
            throw new FileNotFoundException($"Required payload is missing: {path}");
        await using var file = File.OpenRead(path);
        var hash = Convert.ToHexString(await SHA256.HashDataAsync(file));
        if (!hash.Equals(expected, StringComparison.OrdinalIgnoreCase))
            throw new InvalidDataException($"SHA-256 verification failed for {Path.GetFileName(path)}.");
    }
}

internal static class WindowsOperations
{
    private static readonly HttpClient Http = new() { Timeout = TimeSpan.FromMinutes(10) };

    public static async Task DownloadAsync(Payload asset, string target)
    {
        using var response = await Http.GetAsync(asset.Url, HttpCompletionOption.ResponseHeadersRead);
        response.EnsureSuccessStatusCode();
        using var timeout = new CancellationTokenSource(TimeSpan.FromMinutes(30));
        await using (var file = new FileStream(target, FileMode.CreateNew, FileAccess.Write))
            await response.Content.CopyToAsync(file, timeout.Token);
        await Payloads.VerifyAsync(target, asset.Sha256);
    }

    public static async Task RunAsync(string file, IEnumerable<string> args, string log, bool elevate = false,
        TimeSpan? timeout = null, params int[] rebootCodes)
    {
        var start = new ProcessStartInfo(file)
        {
            UseShellExecute = elevate,
            Verb = elevate ? "runas" : "",
            RedirectStandardOutput = !elevate,
            RedirectStandardError = !elevate,
            CreateNoWindow = !elevate
        };
        foreach (var arg in args) start.ArgumentList.Add(arg);
        await RunAsync(start, log, timeout, rebootCodes);
    }

    public static async Task RunAsync(ProcessStartInfo start, string log, TimeSpan? timeout = null,
        params int[] rebootCodes)
    {
        using var process = Process.Start(start) ?? throw new InvalidOperationException($"Could not start {start.FileName}.");
        var stdout = start.RedirectStandardOutput ? process.StandardOutput.ReadToEndAsync() : Task.FromResult("");
        var stderr = start.RedirectStandardError ? process.StandardError.ReadToEndAsync() : Task.FromResult("");
        using var timeoutSource = new CancellationTokenSource(timeout ?? Timeout.InfiniteTimeSpan);
        try
        {
            await process.WaitForExitAsync(timeoutSource.Token);
        }
        catch (OperationCanceledException)
        {
            if (!process.HasExited) process.Kill(entireProcessTree: true);
            await process.WaitForExitAsync();
            throw new InvalidOperationException($"{Path.GetFileName(start.FileName)} timed out.");
        }
        await File.AppendAllTextAsync(log, $"{await stdout}\n{await stderr}\nExit code: {process.ExitCode}\n");
        if (rebootCodes.Contains(process.ExitCode))
            throw new RebootRequiredException();
        if (process.ExitCode != 0)
            throw new InvalidOperationException($"{Path.GetFileName(start.FileName)} returned exit code {process.ExitCode}. See the installation log.");
    }

    public static void ExtractZip(string archive, string destination)
    {
        using var zip = ZipFile.OpenRead(archive);
        zip.ExtractToDirectory(destination);
    }

    public static string FindFile(string root, string name) =>
        Directory.EnumerateFiles(root, name, SearchOption.AllDirectories).FirstOrDefault()
        ?? throw new InvalidDataException($"Expected {name} in {root}.");

    public static void Shortcut(string path, string launcher)
    {
        if (File.Exists(path))
        {
            dynamic existingShell = Activator.CreateInstance(Type.GetTypeFromProgID("WScript.Shell", true)!)!;
            dynamic existing = existingShell.CreateShortcut(path);
            if (existing.TargetPath == CommandPrompt && existing.Arguments == ShortcutArguments(launcher)) return;
            throw new IOException($"A different shortcut already exists at {path}.");
        }

        Directory.CreateDirectory(Path.GetDirectoryName(path)!);
        dynamic shell = Activator.CreateInstance(Type.GetTypeFromProgID("WScript.Shell", true)!)!;
        dynamic link = shell.CreateShortcut(path);
        link.TargetPath = CommandPrompt;
        link.Arguments = ShortcutArguments(launcher);
        link.Description = "Command Prompt configured for ROS 2 Humble";
        link.Save();
    }

    public static string CommandPrompt => Path.Combine(Environment.SystemDirectory, "cmd.exe");

    private static string ShortcutArguments(string launcher) => $"/d /v:off /s /k \"\"{launcher}\"\"";
}

public sealed class RebootRequiredException() : Exception("A prerequisite requested a restart. Restart Windows and run setup again.");
