import Amplify
import AWSAPIPlugin
import AWSCognitoAuthPlugin
import Foundation

enum AmplifyService {
    private static var didConfigure = false

    /// Adds the plugins and configures Amplify, once per launch. If it throws, the app shows the startup failure
    /// screen for the rest of the launch, with no Try again (project decision of 2026-10-29): with amplify-swift 2.x
    /// a second call cannot succeed. A configuration file that failed to load fails the same way again, and a
    /// failure after that has already marked the Logging category configured, so `Amplify.configure()` throws
    /// "already configured". Only a new launch (or a new copy of the app) can recover.
    static func configureIfNeeded() throws {
        guard !didConfigure else { return }

#if DEBUG
        Amplify.Logging.logLevel = ProcessInfo.processInfo.environment["AMPLIFY_VERBOSE_LOGS"] == "1" ? .verbose : .warn
#endif

        try Amplify.add(plugin: AWSCognitoAuthPlugin())
        try Amplify.add(plugin: AWSAPIPlugin())
        try Amplify.configure()
        didConfigure = true
    }
}
