using System.Windows;
using Ros2Setup;

internal static class Program
{
    [STAThread]
    private static void Main()
    {
        var app = new Application();
        app.Run(new SetupWindow(options => new Simulation(options), preview: true));
    }

    private sealed class Simulation(Options options) : IInstallation
    {
        public IReadOnlyList<Step> Steps { get; } = Plan(options);
        public IReadOnlyList<string> Reused => [];
        public string Launcher => System.IO.Path.Combine(options.Destination, "ros-humble.cmd");
        public string? LogPath => null;

        public async Task ExecuteAsync(int index)
        {
            await Task.Delay(350);
            if (options.Destination.Equals("fail", StringComparison.OrdinalIgnoreCase) && index == 1)
                throw new InvalidOperationException("Simulated failure while setting up prerequisites.");
        }

        private static List<Step> Plan(Options options)
        {
            var steps = new List<Step>
            {
                new("Download and verify ROS 2 Humble", "Fetch the pinned Windows archive from GitHub."),
                new("Set up prerequisites", "Install the required Python and Visual C++ runtimes.", true),
                new("Extract ROS 2 Humble", options.Destination),
                new("Configure ROS command prompt", $"RMW_IMPLEMENTATION={options.Rmw}")
            };
            if (options.Development) steps.Add(new("Install C++ development tools", "Set up the Visual Studio 2019 C++ workload.", true));
            if (options.Visualization || options.Graphviz) steps.Add(new("Configure visualization", "Set up Qt and the selected visualization tools."));
            if (options.OpenCv) steps.Add(new("Configure OpenCV examples", "Install OpenCV runtime dependencies."));
            if (options.StartMenu) steps.Add(new("Create Start menu shortcut", "Add a shortcut for the current user."));
            if (options.Desktop) steps.Add(new("Create desktop shortcut", "Add a shortcut for the current user."));
            steps.Add(new("Verify ROS 2 command prompt", "Load the selected middleware and check the ROS CLI."));
            return steps;
        }
    }
}
