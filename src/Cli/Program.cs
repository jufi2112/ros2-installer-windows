using Ros2Setup;

return await MainAsync(args);

static async Task<int> MainAsync(string[] args)
{
    if (args.Length == 0 || args.SequenceEqual(["--help"]))
    {
        Console.WriteLine("""
            ROS 2 Humble Setup
              Ros2HumbleCli --print-plan [options]
              Ros2HumbleCli --headless --accept-plan [options]

              --destination PATH       Default: C:\dev\ros2_humble
              --dds cyclone|fast       Default: cyclone
              --development            Visual Studio 2019 C++ Build Tools, CMake, and colcon
              --visualization          Qt tools
              --graphviz               Graphviz and Qt for rqt_graph
              --opencv                 OpenCV
              --no-walkableor-receiver Skip the WalkableOR point cloud receiver and its desktop shortcut
              --walkableor-project PATH  Copy the config from this WalkableOR project folder
              --replace-walkableor-config  Allow replacing a different existing receiver config
              --no-start-menu          Skip the Start menu shortcut
              --desktop                Create a desktop shortcut
              --offline                Require local payloads
              --container              Allow Windows Server Core for container testing

            Exit codes: 0 success, 1 installation error, 2 invalid arguments, 3 restart required.
            """);
        return 0;
    }

    Installation? install = null;
    try
    {
        if (args.Length == 2 && args[0] == "--prepare-offline")
        {
            await OfflinePackaging.PrepareAsync(args[1]);
            return 0;
        }

        var options = new Options(Transparency: false);
        var preview = false;
        var headless = false;
        var accepted = false;
        var offline = false;
        var container = false;
        var flags = new HashSet<string>(StringComparer.Ordinal);
        for (var i = 0; i < args.Length; i++)
        {
            var flag = args[i];
            if (!flags.Add(flag)) throw new ArgumentException($"Repeated option {flag}.");
            string Value() => ++i < args.Length && !args[i].StartsWith("--", StringComparison.Ordinal)
                ? args[i] : throw new ArgumentException($"Missing value for {flag}.");
            switch (flag)
            {
                case "--print-plan": preview = true; break;
                case "--headless": headless = true; break;
                case "--accept-plan": accepted = true; break;
                case "--offline": offline = true; break;
                case "--container": container = true; break;
                case "--destination": options = options with { Destination = Value() }; break;
                case "--dds":
                    options = options with { Dds = Value() switch
                    {
                        "cyclone" => Middleware.Cyclone,
                        "fast" => Middleware.Fast,
                        _ => throw new ArgumentException("Use --dds cyclone or --dds fast.")
                    }};
                    break;
                case "--development": options = options with { Development = true }; break;
                case "--visualization": options = options with { Visualization = true }; break;
                case "--graphviz": options = options with { Graphviz = true }; break;
                case "--opencv": options = options with { OpenCv = true }; break;
                case "--no-walkableor-receiver": options = options with { WalkableOrReceiver = false }; break;
                case "--walkableor-project": options = options with { WalkableOrProject = Value() }; break;
                case "--replace-walkableor-config": options = options with { ReplaceWalkableOrConfig = true }; break;
                case "--no-start-menu": options = options with { StartMenu = false }; break;
                case "--desktop": options = options with { Desktop = true }; break;
                default: throw new ArgumentException($"Unknown option {flag}.");
            }
        }

        if (preview ? headless || accepted : !headless || !accepted)
            throw new ArgumentException("Use --print-plan or --headless --accept-plan.");
        if (options.WalkableOrProject is not null && !options.WalkableOrReceiver)
            throw new ArgumentException("--walkableor-project requires the WalkableOR receiver.");
        if (options.ReplaceWalkableOrConfig && options.WalkableOrProject is null)
            throw new ArgumentException("--replace-walkableor-config requires --walkableor-project.");

        install = new Installation(options, AppContext.BaseDirectory, container, offline);
        foreach (var reused in install.Reused) Console.WriteLine($"Reuse: {reused}");
        var steps = install.Steps;
        for (var index = 0; index < steps.Count; index++)
        {
            var step = steps[index];
            Console.WriteLine($"{index + 1}. {step.Title}\n{step.Detail}");
            if (step.RequiresAdmin) Console.WriteLine("Requires administrator approval.");
            if (!preview)
            {
                await install.ExecuteAsync(index);
                Console.WriteLine("Completed.\n");
            }
        }
        if (!preview)
        {
            Console.WriteLine($"ROS command prompt: {install.Launcher}");
            if (install.ReceiverCompletionMessage is { } receiverMessage)
                Console.WriteLine(receiverMessage);
        }
        return 0;
    }
    catch (RebootRequiredException error)
    {
        Console.Error.WriteLine(error.Message);
        return 3;
    }
    catch (ArgumentException error)
    {
        Console.Error.WriteLine(error.Message);
        return 2;
    }
    catch (Exception error)
    {
        Console.Error.WriteLine(error.Message);
        return 1;
    }
    finally
    {
        if (install?.LogPath is { } log) Console.WriteLine($"Log: {log}");
        install?.Dispose();
    }
}
