import AVFoundation
import Foundation
import Observation

/// Plays a take, and plays the reference against it.
@Observable
@MainActor
public final class AudioPlayerService {

    /// Two slots, because A/B needs both alive at once. One slot would force a reload and
    /// an audible gap. Each needs its own strong reference: a player held only locally
    /// deallocates mid-play and goes silent, which presents as "the second one is broken".
    private var referencePlayer: AVAudioPlayer?
    private var takePlayer: AVAudioPlayer?
    private var referenceDelegate: PlayerDelegate?
    private var takeDelegate: PlayerDelegate?

    public private(set) var isPlaying = false

    public init() {}

    public enum Slot { case reference, take }

    public func play(_ url: URL, slot: Slot, rate: Double = 1.0) async throws {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw AppFailure.audioMissing(path: url.lastPathComponent)
        }

        let player: AVAudioPlayer
        do {
            player = try AVAudioPlayer(contentsOf: url)
        } catch {
            Log.unexpected(Log.audio, error, context: "player init")
            throw AppFailure.audioMissing(path: url.lastPathComponent)
        }

        // enableRate must be set BEFORE prepareToPlay, or rate changes are ignored with no
        // error at all.
        player.enableRate = true
        player.prepareToPlay()
        player.rate = Float(rate)

        let shim = PlayerDelegate(timeout: Deadlines.playerFinish(duration: player.duration))
        player.delegate = shim

        switch slot {
        case .reference: referencePlayer = player; referenceDelegate = shim
        case .take: takePlayer = player; takeDelegate = shim
        }

        isPlaying = true
        player.play()
        defer { isPlaying = referencePlayer?.isPlaying == true || takePlayer?.isPlaying == true }
        _ = try await shim.value()
    }

    /// Reference, a pause, then the take. Sequential by default: it is what trains the ear,
    /// and it needs no time alignment.
    public func playAB(reference: URL?, take: URL, gap: Duration = .milliseconds(400), rate: Double = 1.0) async throws {
        if let reference {
            try await play(reference, slot: .reference, rate: rate)
            try? await Task.sleep(for: gap)
        }
        try await play(take, slot: .take, rate: rate)
    }

    /// Both at once, from a shared anchor.
    ///
    /// Two players mix at the system level with no session to configure, so overlay works —
    /// but calling `play()` on both back to back gives a skew of tens of milliseconds that
    /// is clearly audible on speech onsets. Only offered against baked reference audio:
    /// live synthesis cannot be time-aligned against a recording.
    public func playOverlaid(reference: URL, take: URL, rate: Double = 1.0) throws {
        let a = try AVAudioPlayer(contentsOf: reference)
        let b = try AVAudioPlayer(contentsOf: take)
        for p in [a, b] {
            p.enableRate = true
            p.prepareToPlay()
            p.rate = Float(rate)
        }
        referencePlayer = a
        takePlayer = b
        let anchor = a.deviceCurrentTime + 0.1
        a.play(atTime: anchor)
        b.play(atTime: anchor)
        isPlaying = true
    }

    public func stopAll() {
        referencePlayer?.stop()
        takePlayer?.stop()
        referencePlayer = nil
        takePlayer = nil
        referenceDelegate = nil
        takeDelegate = nil
        isPlaying = false
    }
}

private final class PlayerDelegate: NSObject, AVAudioPlayerDelegate, @unchecked Sendable {
    private let shot: OneShot<Bool>

    init(timeout: Duration) {
        self.shot = OneShot(operation: "playing the audio", timeout: timeout)
        super.init()
    }

    func value() async throws -> Bool { try await shot.value() }

    nonisolated func audioPlayerDidFinishPlaying(_ p: AVAudioPlayer, successfully flag: Bool) {
        shot.complete(flag)
    }

    nonisolated func audioPlayerDecodeErrorDidOccur(_ p: AVAudioPlayer, error: Error?) {
        shot.complete(false)
    }
}
