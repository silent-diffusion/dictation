import Foundation
import ObertonCore

// STAND-IN for lane F's unload timer (AppModel.unloadCountdown / unloadNote). Delete this file once lane F's versions
// are on AppModel; the dashboard reads only these two names. Without a timer there is no countdown, so a model that
// would unload after N minutes reads as plainly loaded here.
extension AppModel {
    /// Seconds until the models unload, or nil when nothing is waiting to unload.
    var unloadCountdown: TimeInterval? { nil }

    /// The signal path's right-hand note, in Windows' words.
    var unloadNote: String {
        if settings.unloadAfterMinutes < 0 { return "Models unload right after use" }
        if settings.unloadAfterMinutes == 0 { return "Models stay loaded" }
        if !speechLoaded { return "Nothing loaded" }
        return "Models stay loaded"
    }
}
