import Foundation
import MetricKit
import os

/// Receives MetricKit diagnostic payloads and writes a one-line summary of each
/// crash, hang, CPU exception, disk-write exception and slow launch through
/// `AppLog.diagnostics`.
///
/// iOS delivers diagnostics on the launch after they happen (at most daily), on a
/// background queue. Register once, early in launch, so the payload for a crash in
/// the previous session is not missed.
final class MetricDiagnosticsSubscriber: NSObject, MXMetricManagerSubscriber, Sendable {
    static let shared = MetricDiagnosticsSubscriber()

    private let registration = OSAllocatedUnfairLock(initialState: false)

    func register() {
        let shouldRegister = registration.withLock { isRegistered -> Bool in
            guard !isRegistered else { return false }
            isRegistered = true
            return true
        }
        guard shouldRegister else { return }

        MXMetricManager.shared.add(self)
        AppLog.diagnostics.debug("MetricKit subscriber registered")
    }

    nonisolated func didReceive(_ payloads: [MXDiagnosticPayload]) {
        for payload in payloads {
            Self.logSummary(of: payload)
        }
    }

    // MARK: - Summaries

    nonisolated private static func logSummary(of payload: MXDiagnosticPayload) {
        let window = "\(payload.timeStampBegin.ISO8601Format())..\(payload.timeStampEnd.ISO8601Format())"

        for crash in payload.crashDiagnostics ?? [] {
            let context = metadataDescription(for: crash)
            let exceptionType = numberDescription(crash.exceptionType)
            let exceptionCode = numberDescription(crash.exceptionCode)
            let signal = numberDescription(crash.signal)
            let termination = crash.terminationReason ?? "none"
            let objcException = crash.exceptionReason.map { "\($0.exceptionName) (\($0.className))" } ?? "none"
            let objcMessage = crash.exceptionReason?.composedMessage ?? ""
            AppLog.diagnostics.fault("crash window=\(window, privacy: .public) \(context, privacy: .public) exceptionType=\(exceptionType, privacy: .public) exceptionCode=\(exceptionCode, privacy: .public) signal=\(signal, privacy: .public) termination=\(termination, privacy: .public) objcException=\(objcException, privacy: .public) message=\(objcMessage, privacy: .private)")
        }

        for hang in payload.hangDiagnostics ?? [] {
            let context = metadataDescription(for: hang)
            let seconds = hang.hangDuration.converted(to: .seconds).value
            AppLog.diagnostics.error("hang window=\(window, privacy: .public) \(context, privacy: .public) duration=\(seconds, format: .fixed(precision: 2), privacy: .public)s")
        }

        for exception in payload.cpuExceptionDiagnostics ?? [] {
            let context = metadataDescription(for: exception)
            let cpuSeconds = exception.totalCPUTime.converted(to: .seconds).value
            let sampledSeconds = exception.totalSampledTime.converted(to: .seconds).value
            AppLog.diagnostics.error("cpuException window=\(window, privacy: .public) \(context, privacy: .public) cpu=\(cpuSeconds, format: .fixed(precision: 1), privacy: .public)s sampled=\(sampledSeconds, format: .fixed(precision: 1), privacy: .public)s")
        }

        for exception in payload.diskWriteExceptionDiagnostics ?? [] {
            let context = metadataDescription(for: exception)
            let megabytes = exception.totalWritesCaused.converted(to: .megabytes).value
            AppLog.diagnostics.error("diskWriteException window=\(window, privacy: .public) \(context, privacy: .public) writes=\(megabytes, format: .fixed(precision: 1), privacy: .public)MB")
        }

        for launch in payload.appLaunchDiagnostics ?? [] {
            let context = metadataDescription(for: launch)
            let seconds = launch.launchDuration.converted(to: .seconds).value
            AppLog.diagnostics.error("slowLaunch window=\(window, privacy: .public) \(context, privacy: .public) duration=\(seconds, format: .fixed(precision: 2), privacy: .public)s")
        }
    }

    nonisolated private static func metadataDescription(for diagnostic: MXDiagnostic) -> String {
        let metaData = diagnostic.metaData
        return "app=\(diagnostic.applicationVersion) build=\(metaData.applicationBuildVersion) os=\(metaData.osVersion) device=\(metaData.deviceType)"
    }

    nonisolated private static func numberDescription(_ number: NSNumber?) -> String {
        number.map { $0.stringValue } ?? "none"
    }
}
