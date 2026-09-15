import Foundation

/// Converts recorder metering into something a meter can draw.
public enum AudioLevel {

    /// Decibels full scale, as `AVAudioRecorder` reports them, mapped to 0 through 1.
    ///
    /// The floor is -60 rather than -160: real room noise sits around -50, so using the
    /// full range would leave the meter visually dead for normal speech.
    public static let floorDB: Double = -60

    public static func normalized(decibels: Double) -> Double {
        guard decibels.isFinite else { return 0 }
        if decibels <= floorDB { return 0 }
        if decibels >= 0 { return 1 }
        return (decibels - floorDB) / -floorDB
    }

    /// True when the input has been at the floor long enough to mean something is wrong.
    ///
    /// This is the check that turns the level meter from decoration into a diagnostic. One
    /// threshold catches three of the app's nastiest silent failures at once: a dead
    /// microphone, a hardware-muted microphone, and a privacy grant that denies without a
    /// dialog. Revision 1 justified the meter by exactly this scenario and then wired no
    /// logic to it.
    public static let silenceSeconds: Double = 3.0
    public static let silenceThreshold: Double = 0.02

    public static func isEffectivelySilent(_ level: Double) -> Bool {
        level <= silenceThreshold
    }
}
