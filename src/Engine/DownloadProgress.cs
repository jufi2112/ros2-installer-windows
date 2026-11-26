using System.Diagnostics;

namespace Ros2Setup;

internal sealed class DownloadProgress(Payload[] assets, IProgress<StepProgress> progress)
{
    private sealed class FileProgress(long? length)
    {
        public long Received;
        public long? Length = length;
        public bool Downloaded;
        public bool Verified;
    }

    private readonly Dictionary<Payload, FileProgress> _files = assets.ToDictionary(asset => asset, asset => new FileProgress(asset.Size));
    private readonly Stopwatch _elapsed = Stopwatch.StartNew();
    private readonly object _gate = new();
    private TimeSpan _lastReport = TimeSpan.MinValue;

    public void Update(Payload asset, long received, long? length, bool transferComplete = false, bool verified = false)
    {
        lock (_gate)
        {
            var file = _files[asset];
            file.Received = received;
            file.Length = length;
            file.Downloaded |= transferComplete || verified;
            file.Verified |= verified;

            var elapsed = _elapsed.Elapsed;
            var finishedTransfers = transferComplete && _files.Values.All(item => item.Downloaded);
            var finishedVerification = verified && _files.Values.All(item => item.Verified);
            if (_lastReport != TimeSpan.MinValue && elapsed - _lastReport < TimeSpan.FromMilliseconds(250)
                && !finishedTransfers && !finishedVerification)
                return;

            _lastReport = elapsed;
            var downloaded = _files.Values.Sum(item => item.Received);
            if (finishedVerification)
            {
                progress.Report(new StepProgress(1, $"Verified {FormatBytes(downloaded)}."));
                return;
            }
            if (finishedTransfers)
            {
                progress.Report(new StepProgress(null, $"{FormatBytes(downloaded)} downloaded. Verifying checksums…"));
                return;
            }

            var verifiedCount = _files.Values.Count(item => item.Verified);
            var suffix = assets.Length > 1 ? $"   •   {verifiedCount} of {assets.Length} packages verified" : "";
            var total = _files.Values.Sum(item => item.Length);
            if (!_files.Values.All(item => item.Length.HasValue) || total is null or <= 0)
            {
                progress.Report(new StepProgress(null, $"{FormatBytes(downloaded)} downloaded{suffix}"));
                return;
            }

            var estimate = "";
            if (elapsed.TotalSeconds >= 1 && downloaded > 0 && downloaded < total.Value)
            {
                var seconds = (total.Value - downloaded) * elapsed.TotalSeconds / downloaded;
                if (seconds < TimeSpan.MaxValue.TotalSeconds)
                {
                    var remaining = TimeSpan.FromSeconds(Math.Ceiling(seconds));
                    estimate = $"   •   About {FormatTime(remaining)} remaining";
                }
            }
            var fraction = Math.Clamp((double)downloaded / total.Value, 0, 1);
            progress.Report(new StepProgress(fraction,
                $"{FormatBytes(downloaded)} of {FormatBytes(total.Value)}{estimate}{suffix}"));
        }
    }

    private static string FormatBytes(long bytes) => bytes < 1024 * 1024
        ? $"{bytes / 1024.0:N1} KiB"
        : $"{bytes / (1024.0 * 1024):N1} MiB";

    private static string FormatTime(TimeSpan time) => time.TotalHours >= 1
        ? $"{(int)time.TotalHours}h {time.Minutes}m"
        : time.TotalMinutes >= 1 ? $"{time.Minutes}m {time.Seconds}s" : $"{time.Seconds}s";
}
