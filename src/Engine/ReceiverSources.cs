using System.IO.Compression;
using System.Reflection;
using System.Security.Cryptography;
using System.Text.Json;

namespace Ros2Setup;

internal static class ReceiverSources
{
    private sealed record Manifest(string Revision, Dictionary<string, string> Files);
    private static readonly Manifest Source = ReadManifest();

    public static Payload Upstream => Payloads.All.Single(asset => asset.Group == "receiver");
    public static string Revision => Source.Revision;
    public static string OfflineFileName => $"walkableor-endpoint-{Revision}.zip";

    public static async Task PrepareAsync(string scratch, string output, IProgress<StepProgress>? progress = null)
    {
        Directory.CreateDirectory(scratch);
        var download = Path.Combine(scratch, Upstream.File);
        try
        {
            await WindowsOperations.DownloadAsync(Upstream, download, progress);
            progress?.Report(new StepProgress(null, "Checking the endpoint source files…"));
            using var archive = ZipFile.OpenRead(download);
            var prefix = $"ROS-TCP-Endpoint-{Revision}/";
            using var filtered = ZipFile.Open(output, ZipArchiveMode.Create);
            foreach (var (name, hash) in Source.Files)
            {
                var entry = archive.GetEntry(prefix + name)
                    ?? throw new InvalidDataException($"The endpoint source is missing {name}.");
                VerifyEntry(entry, hash);
                using var input = entry.Open();
                using var target = filtered.CreateEntry(name).Open();
                input.CopyTo(target);
            }
        }
        finally
        {
            File.Delete(download);
        }
    }

    public static void VerifyArchive(string path)
    {
        using var archive = ZipFile.OpenRead(path);
        ValidateEntries(archive);
    }

    public static void Extract(string path, string destination)
    {
        using var archive = ZipFile.OpenRead(path);
        ValidateEntries(archive);
        archive.ExtractToDirectory(destination);
    }

    public static void VerifyDirectory(string path)
    {
        foreach (var (name, expected) in Source.Files)
        {
            using var input = File.OpenRead(Path.Combine(path, name));
            VerifyHash(input, expected, name);
        }
    }

    private static void ValidateEntries(ZipArchive archive)
    {
        var names = new HashSet<string>(StringComparer.Ordinal);
        foreach (var entry in archive.Entries)
        {
            if (!Source.Files.TryGetValue(entry.FullName, out var hash) || !names.Add(entry.FullName))
                throw new InvalidDataException($"Unexpected file in the WalkableOR payload: {entry.FullName}.");
            VerifyEntry(entry, hash);
        }
        if (names.Count != Source.Files.Count)
            throw new InvalidDataException("The WalkableOR payload is missing endpoint source files.");
    }

    private static void VerifyEntry(ZipArchiveEntry entry, string hash)
    {
        using var input = entry.Open();
        VerifyHash(input, hash, entry.FullName);
    }

    private static void VerifyHash(Stream input, string expected, string name)
    {
        var actual = Convert.ToHexString(SHA256.HashData(input));
        if (!actual.Equals(expected, StringComparison.OrdinalIgnoreCase))
            throw new InvalidDataException($"SHA-256 verification failed for WalkableOR source file {name}.");
    }

    private static Manifest ReadManifest()
    {
        using var stream = Assembly.GetExecutingAssembly().GetManifestResourceStream("receiver-source.json")!;
        return JsonSerializer.Deserialize<Manifest>(stream)!;
    }
}
