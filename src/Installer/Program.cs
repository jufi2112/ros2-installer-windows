using System.Windows;
using Ros2Setup;

internal static class Program
{
    [STAThread]
    private static void Main()
    {
        var app = new Application();
        app.Run(new SetupWindow(options => new Installation(options, AppContext.BaseDirectory)));
    }
}
