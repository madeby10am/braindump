import CoreAudio
import Foundation

class AudioRecorder {
    private let queue = DispatchQueue(label: "OpenWispr.AudioRecorder", qos: .userInitiated)
    private var capture: AudioCaptureUnit?
    private var currentOutputURL: URL?
    private var selectedDeviceID: AudioDeviceID?
    private var wantsVoiceProcessing = false

    /// macOS voice processing (noise suppression + echo cancellation). It also
    /// ducks all other audio for as long as the unit exists, so it's opt-in.
    var useVoiceProcessing: Bool {
        get { queue.sync { wantsVoiceProcessing } }
        set { queue.async { self.wantsVoiceProcessing = newValue } }
    }

    var preferredDeviceID: AudioDeviceID? {
        get { queue.sync { selectedDeviceID } }
        set { queue.async { self.selectedDeviceID = newValue } }
    }

    func prepare() {
        queue.async {
            guard self.currentOutputURL == nil else { return }
            do {
                _ = try self.configuredCapture()
            } catch {
                self.capture = nil
                print("Microphone preparation failed: \(error.localizedDescription)")
            }
        }
    }

    func teardown() {
        queue.sync {
            capture = nil
            currentOutputURL = nil
        }
    }

    private func configuredCapture() throws -> AudioCaptureUnit {
        let defaultInput = AudioDeviceManager.getDefaultInputDeviceID()
        let route = AudioEngineCacheState.Route(
            inputDeviceID: selectedDeviceID ?? defaultInput,
            outputDeviceID: AudioDeviceManager.getDefaultOutputDeviceID(),
            defaultInputDeviceID: defaultInput
        )
        let voiceProcessing: Bool
        if #available(macOS 14.0, *) { voiceProcessing = wantsVoiceProcessing } else { voiceProcessing = false }
        if let capture, capture.voiceProcessing == voiceProcessing, capture.cacheState.canReuse(for: route) { return capture }
        capture = nil
        let startedAt = DispatchTime.now().uptimeNanoseconds
        let configured = try AudioCaptureUnit(route: route, voiceProcessing: voiceProcessing)
        capture = configured
        print("Audio setup: \((DispatchTime.now().uptimeNanoseconds - startedAt) / 1_000_000) ms; input=\(route.inputDeviceID), output=\(route.outputDeviceID)")
        return configured
    }

    func startRecording(to outputURL: URL) throws {
        let requestedAt = DispatchTime.now().uptimeNanoseconds
        try queue.sync {
            guard currentOutputURL == nil else { return }
            do {
                let capture = try configuredCapture()
                try capture.start(to: outputURL, requestedAt: requestedAt)
                currentOutputURL = outputURL
                print("Microphone ready in \((DispatchTime.now().uptimeNanoseconds - requestedAt) / 1_000_000) ms (voice processing: \(capture.voiceProcessing))")
            } catch {
                capture = nil
                throw error
            }
        }
    }

    /// Current input peak level while recording, 0 otherwise.
    var level: Float {
        queue.sync { currentOutputURL == nil ? 0 : (capture?.currentLevel ?? 0) }
    }

    func stopRecording() -> URL? {
        queue.sync {
            guard let url = currentOutputURL else { return nil }
            currentOutputURL = nil
            do {
                try capture?.stop()
                return url
            } catch {
                capture = nil
                try? FileManager.default.removeItem(at: url)
                print("Recording failed: \(error.localizedDescription)")
                return nil
            }
        }
    }
}
