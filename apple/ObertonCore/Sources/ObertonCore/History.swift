import Foundation

/// One past dictation: what was heard, what the AI made of it, where it went.
public struct HistoryEntry: Codable, Identifiable, Sendable, Hashable {
    public var id = UUID()
    public var date = Date()
    public var transcription: String
    public var aiEdit: String?
    public var inserted: String
    public var profileName: String
    public var model: String?
    public var appName: String?
    public var seconds: Double
    public var turnaroundSeconds: Double
    public var warning: String?
    /// The safety net rejected the AI's edit (all of it or some parts); nil in entries saved before this was kept.
    public var safetyNet: Bool?

    public init(transcription: String, aiEdit: String?, inserted: String, profileName: String, model: String?, appName: String?,
                seconds: Double, turnaroundSeconds: Double, warning: String?, safetyNet: Bool = false) {
        self.transcription = transcription
        self.aiEdit = aiEdit
        self.inserted = inserted
        self.profileName = profileName
        self.model = model
        self.appName = appName
        self.seconds = seconds
        self.turnaroundSeconds = turnaroundSeconds
        self.warning = warning
        self.safetyNet = safetyNet
    }

    public var words: Int { inserted.split(whereSeparator: \.isWhitespace).count }
}
