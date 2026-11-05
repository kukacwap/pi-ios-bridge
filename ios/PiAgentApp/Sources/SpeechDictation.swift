import Foundation
import Speech
import AVFoundation

/// Live speech-to-text for the message box. Works on iOS, iPadOS, and Mac Catalyst.
/// Emits the running transcription via `onText`; the caller decides how to apply it.
@MainActor
final class SpeechDictation: ObservableObject {
    @Published var isRecording = false
    @Published var errorText: String?

    /// Called with the full transcription so far (not deltas).
    var onText: ((String) -> Void)?

    private let recognizer = SFSpeechRecognizer()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private let engine = AVAudioEngine()

    var isAvailable: Bool { recognizer?.isAvailable ?? false }

    func toggle() { isRecording ? stop() : start() }

    func start() {
        guard !isRecording else { return }
        errorText = nil

        SFSpeechRecognizer.requestAuthorization { [weak self] status in
            Task { @MainActor in
                guard let self = self else { return }
                guard status == .authorized else {
                    self.errorText = "Speech recognition not authorized."
                    return
                }
                self.requestMicThenRun()
            }
        }
    }

    private func requestMicThenRun() {
        AVAudioApplication.requestRecordPermission { [weak self] granted in
            Task { @MainActor in
                guard let self = self else { return }
                guard granted else { self.errorText = "Microphone access denied."; return }
                self.beginSession()
            }
        }
    }

    private func beginSession() {
        guard let recognizer = recognizer, recognizer.isAvailable else {
            errorText = "Speech recognizer unavailable."; return
        }
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.record, mode: .measurement, options: .duckOthers)
            try session.setActive(true, options: .notifyOthersOnDeactivation)

            let request = SFSpeechAudioBufferRecognitionRequest()
            request.shouldReportPartialResults = true
            self.request = request

            let input = engine.inputNode
            let format = input.outputFormat(forBus: 0)
            input.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
                request.append(buffer)
            }
            engine.prepare()
            try engine.start()
            isRecording = true

            task = recognizer.recognitionTask(with: request) { [weak self] result, error in
                Task { @MainActor in
                    guard let self = self else { return }
                    if let result = result {
                        self.onText?(result.bestTranscription.formattedString)
                    }
                    if error != nil || (result?.isFinal ?? false) {
                        self.stop()
                    }
                }
            }
        } catch {
            errorText = error.localizedDescription
            stop()
        }
    }

    func stop() {
        if engine.isRunning { engine.stop() }
        engine.inputNode.removeTap(onBus: 0)
        request?.endAudio()
        task?.cancel()
        request = nil
        task = nil
        isRecording = false
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }
}
