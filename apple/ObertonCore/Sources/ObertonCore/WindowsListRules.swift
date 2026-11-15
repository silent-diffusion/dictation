import Foundation

/// The 3-px mark beside a row in Windows' lists (App.xaml's RowItem triggers): ink beside the selected row, also while
/// the list has the keyboard focus (the IsSelected trigger comes after IsKeyboardFocused, so it wins), and the accent
/// beside a row that has the keyboard focus without being selected.
public enum RowMark: Equatable, Sendable {
    case none, ink, accent

    public static func of(selected: Bool, focused: Bool) -> RowMark { selected ? .ink : focused ? .accent : .none }
}

/// Settings › Models' downloads (ModelsPage.RunDownloadAsync): one at a time. Every row's button stays usable while one
/// runs (the rows keep the state they were built with); a second Download does nothing (`if (Busy) return;`).
public enum ModelDownloads {
    public static func buttonEnabled(busy: Bool) -> Bool { true }
    public static func mayStart(busy: Bool) -> Bool { !busy }
}

/// One question waiting for an answer from one place at a time (Windows' OverlayWindow `_trial`, a
/// TaskCompletionSource): `ask` shows it and waits; `end` answers it (nil: dismissed). A new question first ends the
/// one before it with nil. The answer goes back to whoever asked, wherever the user has gone since.
@MainActor
public final class ChoiceSlot<Info, Value: Sendable> {
    public private(set) var current: Info?
    private var waiting: CheckedContinuation<Value?, Never>?
    private var show: ((Info?) -> Void)?

    public init() {}

    public var isWaiting: Bool { waiting != nil }

    /// Show `info` (through `show`, which gets nil when it goes) and wait for the answer.
    public func ask(_ info: Info, show: @escaping (Info?) -> Void) async -> Value? {
        end(nil)
        return await withCheckedContinuation { c in
            MainActor.assumeIsolated {
                waiting = c
                current = info
                self.show = show
                show(info)
            }
        }
    }

    public func end(_ value: Value?) {
        guard let w = waiting else { return }
        waiting = nil
        current = nil
        let s = show
        show = nil
        s?(nil)
        w.resume(returning: value)
    }
}
