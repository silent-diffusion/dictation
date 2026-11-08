import Foundation

/// How Extended Notes keeps its files on the iPhone and iPad: an explicit data-protection class for everything in
/// notes/ (session.json, audio.wav, draft.txt, usage.json), and the recordings left out of iCloud and Finder backups.
///
/// The class is `completeUntilFirstUserAuthentication`, not `complete`: a session keeps recording with the screen
/// locked (the app's background audio mode), and during that time it appends to audio.wav, rewrites session.json every
/// few seconds (a new file each time) and reads the transcript back to format and sum it up. Under `complete` the files
/// become unreadable about ten seconds after the lock and those writes would fail mid-lecture; `completeUnlessOpen`
/// would keep the open audio.wav writable but not let the formatting re-read anything. So the files are encrypted until
/// the device is first unlocked after a restart, which is iOS's own default for app files, made explicit here so it
/// can't silently change with an entitlement.
///
/// Recordings (audio.wav) are excluded from backups: they can hold other people's voices (a lecture, a meeting) and
/// are large. The notes text stays in backups, so a restored phone keeps the user's notes; only the playback is gone.
/// On the Mac, FileVault protects the disk and these calls change nothing but the backup flag (Time Machine honours it).
public enum NotesFiles {
    public static let protection = FileProtectionType.completeUntilFirstUserAuthentication

    /// Options for writing a notes file: atomic, with the protection class on iOS.
    public static var writeOptions: Data.WritingOptions {
        #if os(iOS)
        [.atomic, .completeFileProtectionUntilFirstUserAuthentication]
        #else
        [.atomic]
        #endif
    }

    /// Creates `folder` (and its parents) with the protection class, so files made in it inherit it.
    public static func makeFolder(_ folder: URL) throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: attributes)
        protect(folder)
    }

    /// The attributes a new notes file or folder is created with.
    public static var attributes: [FileAttributeKey: Any]? {
        #if os(iOS)
        [.protectionKey: protection]
        #else
        nil
        #endif
    }

    /// Sets the protection class on an existing file or folder (iOS; nothing elsewhere).
    public static func protect(_ url: URL) {
        #if os(iOS)
        do { try FileManager.default.setAttributes([.protectionKey: protection], ofItemAtPath: url.path) } catch {
            CoreLog.warn("Extended notes: couldn't set the file protection: " + error.localizedDescription)
        }
        #endif
    }

    /// A recording: protected, and kept out of iCloud and Finder (and Time Machine) backups.
    public static func protectRecording(_ url: URL) {
        protect(url)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var u = url
        do { try u.setResourceValues(values) } catch {
            CoreLog.warn("Extended notes: couldn't keep the recording out of backups: " + error.localizedDescription)
        }
    }
}
