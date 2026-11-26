using System.IO.Compression;
using System.Text.RegularExpressions;

namespace Ros2Setup;

internal sealed partial class RosEnvironment
{
    private const string Channel = "https://conda.anaconda.org/conda-forge/";
    private const string Core = "python setuptools pip wheel openssl libcurl curl yaml yaml-cpp zstd lz4-c sqlite tinyxml tinyxml2 spdlog console_bridge asio orocos-kdl python-orocos-kdl argcomplete catkin_pkg cryptography empy importlib-metadata lark lxml netifaces numpy psutil pyparsing pyyaml";
    private const string Development = "cmake eigen benchmark cunit cppcheck git vcstool pybind11";

    private sealed record Package(string Name, string Line, Payload Asset, string[] Dependencies);

    private readonly string _lockfile;
    private readonly Dictionary<string, Package> _packages;

    private RosEnvironment(string lockfile)
    {
        _lockfile = lockfile;
        _packages = PackageEntry().Matches(lockfile).Select(entry =>
        {
            var url = entry.Groups[1].Value;
            var file = Path.GetFileName(url);
            var name = file[..file.LastIndexOf('-')];
            name = name[..name.LastIndexOf('-')];
            var sha = ShaEntry().Match(entry.Groups[2].Value).Groups[1].Value;
            if (sha.Length != 64 || !url.StartsWith(Channel, StringComparison.Ordinal))
                throw new InvalidDataException($"Missing or invalid source for {file} in the ROS environment lock.");
            var dependencies = DependencyBlock().Match(entry.Groups[2].Value).Groups[1].Value;
            return new Package(name, $"      - conda: {url}", new Payload("conda", file, url, sha),
                DependencyName().Matches(dependencies).Select(match => match.Groups[1].Value).ToArray());
        }).ToDictionary(package => package.Name, StringComparer.OrdinalIgnoreCase);

        if (_packages.Count == 0) throw new InvalidDataException("The ROS environment lock is empty.");
    }

    public static RosEnvironment FromArchive(string archive)
    {
        using var zip = ZipFile.OpenRead(archive);
        using var reader = new StreamReader((zip.GetEntry("ros2-windows/pixi.lock")
            ?? throw new InvalidDataException("The ROS archive has no Pixi lock.")).Open());
        return new RosEnvironment(reader.ReadToEnd().ReplaceLineEndings("\n"));
    }

    public Payload[] Select(Options options) => SelectPackages(options).Select(package => package.Asset).ToArray();

    public string LocalLock(Options options, string mirror)
    {
        var urls = SelectPackages(options).Select(package => package.Line).ToHashSet();
        var kept = _lockfile.Split('\n')
            .Where(line => !line.StartsWith("      - conda:", StringComparison.Ordinal) || urls.Contains(line));
        var localChannel = new Uri(Path.GetFullPath(mirror) + Path.DirectorySeparatorChar).AbsoluteUri;
        return string.Join('\n', kept).Replace(Channel, localChannel, StringComparison.Ordinal);
    }

    private Package[] SelectPackages(Options options)
    {
        var roots = Core.Split(' ').AsEnumerable();
        if (options.Development)
            roots = roots.Concat(Development.Split(' ')).Concat(_packages.Keys.Where(name => name.StartsWith("colcon-")));
        else if (options.WalkableOrReceiver)
            roots = roots.Concat(["colcon-ros", "colcon-package-selection"]);
        if (options.Visualization || options.Graphviz)
            roots = roots.Concat(["qt", "pyqt", "assimp", "bullet"]);
        if (options.Graphviz)
            roots = roots.Concat(["graphviz", "pydot", "pygraphviz"]);
        if (options.OpenCv)
            roots = roots.Append("opencv");

        var visited = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        void Visit(string name)
        {
            if (name.StartsWith("__", StringComparison.Ordinal) || !visited.Add(name))
                return;
            if (!_packages.TryGetValue(name, out var package))
                throw new InvalidDataException($"The ROS environment lock is missing {name}.");
            foreach (var dependency in package.Dependencies) Visit(dependency);
        }

        foreach (var name in roots) Visit(name);
        return visited.Order(StringComparer.Ordinal).Select(name => _packages[name]).ToArray();
    }

    public static string MirrorPath(string root, Payload asset) =>
        Path.Combine(root, new Uri(asset.Url).Segments[^2].TrimEnd('/'), asset.File);

    [GeneratedRegex(@"(?m)^- conda: (https://[^\n]+)\n((?:^[ ]+[^\n]*\n)*)")]
    private static partial Regex PackageEntry();

    [GeneratedRegex(@"(?m)^  sha256: ([a-f0-9]{64})$")]
    private static partial Regex ShaEntry();

    [GeneratedRegex(@"(?m)^  depends:\n((?:^  - [^\n]*\n)*)")]
    private static partial Regex DependencyBlock();

    [GeneratedRegex(@"(?m)^  - ([^ \n]+)")]
    private static partial Regex DependencyName();
}
