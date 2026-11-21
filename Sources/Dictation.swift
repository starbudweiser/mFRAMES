// mFRAMES — dictée vocale des commentaires (micro + reconnaissance vocale d'Apple, sur l'appareil quand c'est possible).
import Foundation
import AppKit
import AVFoundation
import Speech
import CoreAudio
import AudioToolbox

@MainActor
final class Dictation: ObservableObject {
    @Published var active = false
    @Published var error: String?
    @Published var denied = false
    private var triedServer = false
    private var starting = false
    private let engine = AVAudioEngine()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var base = ""

    struct Source: Identifiable, Hashable { let id: String; let name: String }   // id = identifiant unique du périphérique
    /// Micros disponibles (intégré, USB, Bluetooth…).
    @Published var sources: [Source] = []
    /// Micro choisi ; vide = micro par défaut du système.
    @Published var selectedUID: String = UserDefaults.standard.string(forKey: "dictationInputUID") ?? "" {
        didSet { UserDefaults.standard.set(selectedUID, forKey: "dictationInputUID") }
    }
    func refreshSources() {
        let d = AVCaptureDevice.DiscoverySession(deviceTypes: [.microphone, .external], mediaType: .audio, position: .unspecified).devices
        sources = d.map { Source(id: $0.uniqueID, name: $0.localizedName) }
        if !selectedUID.isEmpty, !sources.contains(where: { $0.id == selectedUID }) { selectedUID = "" }
    }
    var selectedName: String { sources.first { $0.id == selectedUID }?.name ?? L.t("voice.sourceDefault") }

    private func deviceID(forUID uid: String) -> AudioDeviceID? {
        var cf = uid as CFString
        var dev = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyTranslateUIDToDevice, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        let st = withUnsafeMutablePointer(to: &cf) { AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, UInt32(MemoryLayout<CFString>.size), $0, &size, &dev) }
        return st == noErr && dev != 0 ? dev : nil
    }

    private var locale: Locale {
        Locale(identifier: ["fr-FR", "en-US", "es-ES", "it-IT"][L.lang.rawValue])
    }

    /// Démarre ou arrête ; `text` reçoit le texte déjà saisi suivi de la dictée en cours.
    func toggle(current: String, update: @escaping (String) -> Void) {
        if active { stop(); return }
        if starting { return }
        starting = true
        error = nil; denied = false; triedServer = false
        SFSpeechRecognizer.requestAuthorization { [weak self] st in
            AVCaptureDevice.requestAccess(for: .audio) { ok in
                DispatchQueue.main.async {
                    guard let self else { return }
                    defer { self.starting = false }
                    guard st == .authorized, ok else { self.error = L.t("voice.denied"); self.denied = true; return }
                    self.begin(current: current, update: update)
                }
            }
        }
    }

    /// Ouvre Réglages Système › Confidentialité (micro).
    func openPrivacy() {
        if let u = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") { NSWorkspace.shared.open(u) }
    }

    private func begin(current: String, update: @escaping (String) -> Void) {
        guard let rec = SFSpeechRecognizer(locale: locale), rec.isAvailable else { error = L.t("voice.unavailable"); return }
        let req = SFSpeechAudioBufferRecognitionRequest()
        req.shouldReportPartialResults = true
        if rec.supportsOnDeviceRecognition, !triedServer { req.requiresOnDeviceRecognition = true }
        request = req
        base = current.isEmpty || current.hasSuffix(" ") ? current : current + " "
        let input = engine.inputNode
        if !selectedUID.isEmpty, var dev = deviceID(forUID: selectedUID), let au = input.audioUnit {
            AudioUnitSetProperty(au, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &dev, UInt32(MemoryLayout<AudioDeviceID>.size))
        }
        input.removeTap(onBus: 0)
        // Format d'entrée invalide (aucun micro, accès refusé en silence) : installTap lèverait une exception fatale.
        let fmt = input.inputFormat(forBus: 0)
        guard fmt.sampleRate > 0, fmt.channelCount > 0 else { error = L.t("voice.noInput"); denied = true; request = nil; return }
        input.installTap(onBus: 0, bufferSize: 1024, format: fmt) { buf, _ in req.append(buf) }
        engine.prepare()
        do { try engine.start() } catch { self.error = error.localizedDescription; cleanup(); return }
        active = true
        task = rec.recognitionTask(with: req) { [weak self] result, err in
            DispatchQueue.main.async {
                guard let self else { return }
                if let r = result { update(self.base + r.bestTranscription.formattedString) }
                if let e = err as NSError?, result == nil, self.active {
                    // Modèle sur l'appareil absent ou en échec : on retente une fois avec la reconnaissance Apple en ligne.
                    if !self.triedServer { self.triedServer = true; self.cleanup(); self.begin(current: self.base, update: update); return }
                    self.error = e.localizedDescription
                }
                if err != nil || result?.isFinal == true { self.stop() }
            }
        }
    }

    func stop() {
        guard active || engine.isRunning else { return }
        request?.endAudio()
        cleanup()
    }

    private func cleanup() {
        if engine.isRunning { engine.stop() }
        engine.inputNode.removeTap(onBus: 0)
        task?.cancel(); task = nil; request = nil
        active = false
    }
}
