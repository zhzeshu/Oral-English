import AVFoundation
import Foundation
import Speech

// Transcribes a file through the macOS 26 SpeechAnalyzer/SpeechTranscriber API.
//
//   ./probe.sh ModernTranscribeProbe <audio-file> ["reference text"]
//   ORAL_INSTALL_ASSETS=1 ./probe.sh ModernTranscribeProbe <file>   # allow a download
//
// Two questions, one run:
//
//  1. Does on-device recognition work AT ALL on this machine and this audio? Legacy
//     SFSpeechRecognizer returns an empty final result in 0.17s for audio measured at
//     -21.4 dBFS RMS with clear speech. If the modern API transcribes the same file, the
//     audio and any VAD behaviour are exonerated and the fault is legacy-specific.
//     This stays entirely on-device -- it never sets requiresOnDeviceRecognition = false,
//     because local-only is a hard product requirement and the alternative would upload
//     the user's voice.
//
//  2. Is per-word confidence actually non-constant? Item 03's hard-to-hear rule turns on
//     mean confidence, and legacy SFTranscriptionSegment.confidence is widely reported as
//     a constant 0.0 on-device. `.transcriptionConfidence` is claimed to be a first-class
//     feature of the new local models. That claim is MEASURED here, not assumed.
//
// Asset installation is opt-in: a download is the user's call, not a probe's.

@main
struct ModernTranscribeProbe {
    @MainActor
    static func main() async {
        guard let path = CommandLine.arguments.dropFirst().first else {
            print("Usage: ./probe.sh ModernTranscribeProbe <audio-file> [reference text]")
            return
        }
        let url = URL(fileURLWithPath: path)
        guard FileManager.default.fileExists(atPath: url.path) else {
            print("no such file: \(path)")
            return
        }
        guard #available(macOS 26.0, *) else {
            print("macOS 26 Speech API unavailable at runtime.")
            return
        }

        let reference = CommandLine.arguments.dropFirst(2).first

        // Pass 1 answers "does it work at all" with the base model already installed.
        await attempt(url, label: "PASS 1 - base options", attributes: [], reference: reference)
        // Pass 2 answers the confidence question.
        await attempt(url, label: "PASS 2 - with .transcriptionConfidence",
                      attributes: [.transcriptionConfidence], reference: reference)
    }

    @available(macOS 26.0, *)
    @MainActor
    static func attempt(
        _ url: URL,
        label: String,
        attributes: Set<SpeechTranscriber.ResultAttributeOption>,
        reference: String?
    ) async {
        print("\n=============== \(label) ===============")
        let locale = Locale(identifier: "en-US")
        let transcriber = SpeechTranscriber(
            locale: locale,
            transcriptionOptions: [],
            reportingOptions: [],
            attributeOptions: attributes)

        let status = await AssetInventory.status(forModules: [transcriber])
        print("AssetInventory.status: \(String(describing: status))")

        if status != .installed {
            guard ProcessInfo.processInfo.environment["ORAL_INSTALL_ASSETS"] == "1" else {
                print("Assets not installed for this configuration.")
                print("Re-run with ORAL_INSTALL_ASSETS=1 to allow the download.")
                return
            }
            do {
                if let request = try await AssetInventory.assetInstallationRequest(
                    supporting: [transcriber]) {
                    print("installing assets...")
                    try await request.downloadAndInstall()
                    print("installed. status now: "
                          + "\(String(describing: await AssetInventory.status(forModules: [transcriber])))")
                } else {
                    print("no installation request needed.")
                }
            } catch {
                print("asset installation failed: \(error)")
                return
            }
        }

        do {
            let file = try AVAudioFile(forReading: url)
            print("audio: \(file.length) frames at \(Int(file.fileFormat.sampleRate)) Hz, "
                  + "\(file.fileFormat.channelCount) ch")

            let analyzer = SpeechAnalyzer(modules: [transcriber])

            // Results must be consumed concurrently with analysis, not after it.
            let collector = Task { () -> [(String, Double?)] in
                var out: [(String, Double?)] = []
                for try await result in transcriber.results {
                    for run in result.text.runs {
                        let text = String(result.text[run.range].characters)
                        let conf = run[AttributeScopes.SpeechAttributes.ConfidenceAttribute.self]
                        out.append((text, conf))
                    }
                }
                return out
            }

            let start = Date()
            _ = try await analyzer.analyzeSequence(from: file)
            try await analyzer.finalizeAndFinishThroughEndOfInput()
            let runs = try await collector.value
            let elapsed = Date().timeIntervalSince(start)

            let whole = runs.map(\.0).joined()
            print("\ntranscript (\(String(format: "%.2f", elapsed))s):")
            print("  \"\(whole.trimmingCharacters(in: .whitespacesAndNewlines))\"")

            if whole.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                print("\nEMPTY -- the modern API also returned nothing.")
                print("That would clear legacy of blame and point at the audio or the model.")
                return
            }

            let confs = runs.compactMap(\.1)
            print("\nruns: \(runs.count), runs carrying confidence: \(confs.count)")
            for (t, c) in runs.prefix(20) {
                let shown = t.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !shown.isEmpty else { continue }
                print(String(format: "  %-18@ conf %@", shown as NSString,
                             c.map { String(format: "%.4f", $0) } ?? "none"))
            }

            if confs.isEmpty {
                print("\nNO confidence attribute present. The hard-to-hear rule cannot use it;")
                print("item 03's fallback (metering + missed-word ratio) applies.")
            } else {
                let distinct = Set(confs.map { String(format: "%.4f", $0) }).count
                let mean = confs.reduce(0, +) / Double(confs.count)
                print(String(format: "\nconfidence: mean %.4f, distinct values %d, min %.4f, max %.4f",
                             mean, distinct, confs.min() ?? 0, confs.max() ?? 0))
                if confs.allSatisfy({ $0 == 0 }) {
                    print("  ALL ZERO -- same problem as legacy, under a new name.")
                    print("  Item 03's fallback applies after all.")
                } else if distinct == 1 {
                    print("  Non-zero but CONSTANT. Unusable as a hard-to-hear signal.")
                } else {
                    print("  Non-zero AND varying. The hard-to-hear rule can use it as designed.")
                }
            }

            if let reference {
                print("\nreference: \"\(reference)\"")
            }
        } catch {
            print("failed: \(error)")
        }
    }
}
