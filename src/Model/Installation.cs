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
    bool Transparency = true)
{
    public string Rmw => Dds == Middleware.Cyclone ? "rmw_cyclonedds_cpp" : "rmw_fastrtps_cpp";
}

public sealed record Step(string Title, string Detail, bool RequiresAdmin = false);

public interface IInstallation
{
    IReadOnlyList<Step> Steps { get; }
    IReadOnlyList<string> Reused { get; }
    string Launcher { get; }
    string? LogPath { get; }
    Task ExecuteAsync(int index);
}
