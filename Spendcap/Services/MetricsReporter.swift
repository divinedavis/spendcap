import MetricKit
import os

/// MetricKit subscriber (2026-10-04), the fourth of the quality checks
/// scripts/ship.sh insists on. iOS hands the app a daily summary of launch
/// time, hangs, memory and disk writes, plus crash and hang diagnostics, and
/// this logs a one-line digest of each to the unified log.
///
/// It deliberately sends nothing anywhere: Spendcap's App Privacy label does
/// not declare crash or performance data, and changing that is the owner's
/// call. The same numbers reach Apple from devices that share analytics and
/// surface in Xcode > Organizer, which `scripts/organizer_report.py` prints on
/// every ship.
final class MetricsReporter: NSObject, MXMetricManagerSubscriber {
    static let shared = MetricsReporter()
    private let log = Logger(subsystem: "com.divinedavis.spendcap", category: "metrics")

    func start() {
        MXMetricManager.shared.add(self)
    }

    func didReceive(_ payloads: [MXMetricPayload]) {
        for p in payloads {
            let launch = p.applicationLaunchMetrics?.histogrammedTimeToFirstDraw.bucketEnumerator.allObjects.count ?? 0
            let hangs = p.applicationResponsivenessMetrics?.histogrammedApplicationHangTime.bucketEnumerator.allObjects.count ?? 0
            let peak = p.memoryMetrics?.peakMemoryUsage.formatted() ?? "n/a"
            log.notice("metrics \(p.latestApplicationVersion, privacy: .public): launch buckets \(launch), hang buckets \(hangs), peak memory \(peak, privacy: .public)")
        }
    }

    func didReceive(_ payloads: [MXDiagnosticPayload]) {
        for p in payloads {
            log.error("diagnostics: \(p.crashDiagnostics?.count ?? 0) crash, \(p.hangDiagnostics?.count ?? 0) hang, \(p.diskWriteExceptionDiagnostics?.count ?? 0) disk-write, \(p.cpuExceptionDiagnostics?.count ?? 0) cpu")
        }
    }
}
