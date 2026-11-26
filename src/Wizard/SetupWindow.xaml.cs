using System.ComponentModel;
using System.Windows;
using Microsoft.Win32;

namespace Ros2Setup;

public partial class SetupWindow : Window
{
    private enum Page { Settings, Review, Confirm, Running, Complete }

    private readonly Func<Options, IInstallation> _plan;
    private readonly List<string> _completed = [];
    private IInstallation? _installation;
    private Page _page;
    private bool _transparency;
    private bool _abort;
    private int _index;

    public SetupWindow(Func<Options, IInstallation> plan, bool preview = false)
    {
        InitializeComponent();
        _plan = plan;
        var defaults = new Options();
        Destination.Text = defaults.Destination;
        Dds.SelectedIndex = 0;
        StartMenu.IsChecked = defaults.StartMenu;
        Transparency.IsChecked = defaults.Transparency;
        WalkableOrReceiver.IsChecked = defaults.WalkableOrReceiver;
        if (preview)
        {
            Title = "ROS 2 Humble Setup Preview";
            Subtitle.Text = "Simulation only · enter fail as the folder to preview an error";
        }
    }

    private async void NextClicked(object sender, RoutedEventArgs e)
    {
        switch (_page)
        {
            case Page.Settings:
                Review();
                break;
            case Page.Review:
                if (_transparency) ShowConfirmation();
                else await ExecuteAsync();
                break;
            case Page.Confirm:
                await ExecuteAsync();
                break;
            case Page.Complete:
                Close();
                break;
        }
    }

    private void Review()
    {
        try
        {
            var includeReceiver = WalkableOrReceiver.IsChecked == true;
            string? project = null;
            if (includeReceiver && UseLocalProject.IsChecked == true)
            {
                project = WalkableOrProject.Text.Trim();
                if (string.IsNullOrEmpty(project))
                    throw new ArgumentException("Choose the walkableOR_unity project folder.");
            }
            else if (includeReceiver && DeferReceiverConfig.IsChecked != true)
                throw new ArgumentException("Choose a local WalkableOR project or choose to supply the configuration later.");

            var options = new Options(Destination.Text.Trim(), Dds.SelectedIndex == 0 ? Middleware.Cyclone : Middleware.Fast,
                Development.IsChecked == true, Visualization.IsChecked == true, Graphviz.IsChecked == true,
                OpenCv.IsChecked == true, StartMenu.IsChecked == true, Desktop.IsChecked == true,
                Transparency.IsChecked == true, includeReceiver, project,
                project is not null && ReplaceWalkableOrConfig.IsChecked == true);
            var installation = _plan(options);
            _installation = installation;
            _transparency = options.Transparency;
            var steps = installation.Steps.Select((step, index) => $"{index + 1}. {step.Title}\n{Describe(step)}");
            var reused = installation.Reused.Count == 0 ? "" : "\n\nAlready available\n" + string.Join("\n", installation.Reused);
            Show(Page.Review, "Review installation", string.Join("\n\n", steps) + reused, "Install");
        }
        catch (Exception error)
        {
            SettingsError.Text = error.Message;
            SettingsError.BringIntoView();
        }
    }

    private void BrowseProjectClicked(object sender, RoutedEventArgs e)
    {
        var dialog = new OpenFolderDialog { Title = "Select the walkableOR_unity project folder" };
        if (dialog.ShowDialog(this) == true)
            WalkableOrProject.Text = dialog.FolderName;
    }

    private void ShowConfirmation()
    {
        var installation = _installation!;
        Show(Page.Confirm, $"Step {_index + 1} of {installation.Steps.Count} · {installation.Steps[_index].Title}",
            Describe(installation.Steps[_index]), "Confirm");
    }

    private async Task ExecuteAsync()
    {
        var installation = _installation!;
        try
        {
            do
            {
                var step = installation.Steps[_index];
                Show(Page.Running, step.Title, Describe(step), "");
                await installation.ExecuteAsync(_index);
                _completed.Add(step.Title);
                _index++;
            }
            while (!_abort && !_transparency && _index < installation.Steps.Count);

            if (_abort) Finish("Installation aborted", "No further steps were started.");
            else if (_index == installation.Steps.Count)
            {
                var message = $"Open the ROS command prompt or run:\n{installation.Launcher}";
                if (installation.ReceiverCompletionMessage is { } receiverMessage)
                    message += $"\n\n{receiverMessage}";
                message += $"\n\nTo uninstall ROS 2 Humble later, open:\n{installation.Uninstaller}";
                Finish("ROS 2 Humble is ready", message);
            }
            else ShowConfirmation();
        }
        catch (Exception error)
        {
            Finish("Installation stopped", $"{installation.Steps[_index].Title}\n{error.Message}\n\nThe failed step may have made partial changes.");
        }
    }

    private void Finish(string title, string message)
    {
        var changes = _completed.Count == 0 ? "No steps completed." : "Completed steps\n" + string.Join("\n", _completed);
        var log = _installation?.LogPath;
        (_installation as IDisposable)?.Dispose();
        Show(Page.Complete, title, $"{message}\n\n{changes}" + (log is null ? "" : $"\n\nLog\n{log}"), "Close");
    }

    private void Show(Page page, string heading, string description, string next)
    {
        _page = page;
        Settings.Visibility = Visibility.Collapsed;
        Details.Visibility = Visibility.Visible;
        Status.Text = heading;
        Detail.Text = description;
        Detail.ScrollToHome();
        BackButton.Visibility = page == Page.Review ? Visibility.Visible : Visibility.Collapsed;
        AbortButton.Visibility = page == Page.Complete ? Visibility.Collapsed : Visibility.Visible;
        AbortButton.Content = page == Page.Review ? "Cancel" : "Abort";
        AbortButton.IsEnabled = !_abort;
        NextButton.Visibility = page == Page.Running ? Visibility.Collapsed : Visibility.Visible;
        NextButton.Content = next;
        // Confirm should require an explicit button press, including when returning to focus with Enter.
        NextButton.IsDefault = page != Page.Confirm;
        if (page == Page.Confirm) Detail.Focus();
    }

    private void BackClicked(object sender, RoutedEventArgs e)
    {
        (_installation as IDisposable)?.Dispose();
        _installation = null;
        _page = Page.Settings;
        Details.Visibility = Visibility.Collapsed;
        Settings.Visibility = Visibility.Visible;
        BackButton.Visibility = Visibility.Collapsed;
        AbortButton.Content = "Cancel";
        NextButton.Content = "Review plan";
        SettingsError.Text = "";
        Destination.Focus();
    }

    private void AbortClicked(object sender, RoutedEventArgs e)
    {
        if (_page == Page.Running)
        {
            _abort = true;
            AbortButton.IsEnabled = false;
            Status.Text = "Stopping after the current step";
        }
        else if (_page == Page.Confirm) Finish("Installation aborted", "The pending step was not started.");
        else Close();
    }

    protected override void OnClosing(CancelEventArgs e)
    {
        if (_page is Page.Running or Page.Confirm)
        {
            e.Cancel = true;
            AbortClicked(this, new RoutedEventArgs());
        }
        base.OnClosing(e);
    }

    private static string Describe(Step step) => step.Detail + (step.RequiresAdmin ? "\nRequires administrator approval." : "");
}
