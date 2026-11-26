namespace Ros2Setup;

public enum Middleware { Cyclone, Fast }

public sealed record Options(
    string Destination = @"C:\dev\ros2_humble",
    Middleware Dds = Middleware.Cyclone,
    bool Development = false,
    bool Visualization = false,
    bool Graphviz = false,
    bool OpenCv = false,
    bool StartMenu = true,
    bool Desktop = false,
    bool Transparency = true,
    bool WalkableOrReceiver = true,
    string? WalkableOrProject = null,
    bool ReplaceWalkableOrConfig = false)
{
    public string Rmw => Dds == Middleware.Cyclone ? "rmw_cyclonedds_cpp" : "rmw_fastrtps_cpp";
}

public sealed record Step(string Title, string Detail, bool RequiresAdmin = false);

public static class ReceiverLayout
{
    public const string Folder = "pointcloud_receiver";
    public const string ShortcutName = "Start Point Cloud Receiver";

    public static string ConfigPath(string destination) =>
        Path.Combine(destination, Folder, "configs", "walkableOR.yaml");

    public static string CompletionMessage(string configPath, bool fromProject, bool existingConfig = false)
    {
        if (fromProject)
            return $"WalkableOR configuration is ready at:\n{configPath}\nOpen {ShortcutName} from your desktop.";
        if (existingConfig)
            return $"You can open {ShortcutName} with the existing configuration. To update it later, copy your walkableOR.yaml to:\n{configPath}";
        return $"Copy your walkableOR.yaml to:\n{configPath}\nThen open {ShortcutName} from your desktop.";
    }
}

public interface IInstallation
{
    IReadOnlyList<Step> Steps { get; }
    IReadOnlyList<string> Reused { get; }
    string Launcher { get; }
    string? ReceiverCompletionMessage { get; }
    string? LogPath { get; }
    Task ExecuteAsync(int index);
}
