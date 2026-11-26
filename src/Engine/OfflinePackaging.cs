using System.Security.Cryptography;

namespace Ros2Setup;

public static class OfflinePackaging
{
    public static async Task PrepareAsync(string target)
    {
        // The vendor bootstrapper runs only in a disposable Windows Server Core build container.
        Installation.ValidatePlatform(container: true);
        var installationType = Microsoft.Win32.Registry.GetValue(
            @"HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\Windows NT\CurrentVersion", "InstallationType", null);
        if (!Equals(installationType, "Server Core"))
            throw new PlatformNotSupportedException("Prepare offline payloads in the Server Core build container.");
        var root = Path.GetFullPath(target);
        if (Directory.Exists(root) && Directory.EnumerateFileSystemEntries(root).Any())
            throw new IOException($"The offline output must be empty: {root}");

        var payload = Path.Combine(root, "payload");
        Directory.CreateDirectory(payload);
        foreach (var asset in Payloads.All.Where(asset => asset.Group is not ("vs" or "receiver")))
            await WindowsOperations.DownloadAsync(asset, Path.Combine(payload, asset.File));

        Console.WriteLine("Preparing the pinned WalkableOR endpoint source.");
        var receiver = Path.Combine(payload, ReceiverSources.OfflineFileName);
        await ReceiverSources.PrepareAsync(root, receiver);
        ReceiverSources.VerifyArchive(receiver);

        var ros = Payloads.All.Single(asset => asset.Group == "ros");
        var environment = RosEnvironment.FromArchive(Path.Combine(payload, ros.File));
        var all = new Options(Development: true, Visualization: true, Graphviz: true, OpenCv: true);
        await Parallel.ForEachAsync(environment.Select(all), new ParallelOptions { MaxDegreeOfParallelism = 8 },
            async (asset, _) =>
            {
                var path = RosEnvironment.MirrorPath(Path.Combine(payload, "conda"), asset);
                Directory.CreateDirectory(Path.GetDirectoryName(path)!);
                await WindowsOperations.DownloadAsync(asset, path);
            });

        var vs = Payloads.All.Single(asset => asset.Group == "vs");
        var bootstrapper = Path.Combine(root, vs.File);
        await WindowsOperations.DownloadAsync(vs, bootstrapper);
        var layout = Path.Combine(payload, "vs-layout");
        var layoutLog = Path.Combine(root, "vs-layout.log");
        Console.WriteLine("Downloading Visual Studio 2019 C++ Build Tools offline layout.");
        await WindowsOperations.RunAsync(bootstrapper,
            ["--layout", layout, "--lang", "en-US", .. Installation.BuildToolsArguments(false)],
            layoutLog);
        var layoutBootstrapper = Path.Combine(layout, vs.File);
        File.Copy(bootstrapper, layoutBootstrapper, overwrite: true);
        foreach (var name in new[] { "Catalog.json", "layout.json" })
            if (!File.Exists(Path.Combine(layout, name))) throw new InvalidDataException($"Incomplete Visual Studio layout: {name}");
        var lines = new List<string>();
        foreach (var file in Directory.EnumerateFiles(layout, "*", SearchOption.AllDirectories).Order(StringComparer.Ordinal))
        {
            await using var stream = File.OpenRead(file);
            var digest = Convert.ToHexString(await SHA256.HashDataAsync(stream));
            lines.Add($"{digest}  {Path.GetRelativePath(layout, file)}");
        }
        await File.WriteAllLinesAsync(Path.Combine(layout, "layout.sha256"), lines);
        await File.WriteAllTextAsync(Path.Combine(root, "offline.json"), """{"release":"release-humble-20260220"}""");
    }
}
