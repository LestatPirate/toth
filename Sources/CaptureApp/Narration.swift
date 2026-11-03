// Copyright © 2026 Alex Felizardo.
// Licença MIT: ver LICENSE. MIT License: see LICENSE.

import AVFoundation
import AppKit

/// O microfone escolhido (Preferências e menu Áudio do editor de vídeo): usado na gravação de ecrã e na narração.
/// `nil` = o microfone predefinido do sistema.
enum MicrophoneChoice {
    static let key = "microphoneID"
    static var selectedID: String? {
        get { UserDefaults.standard.string(forKey: key) }
        set { if let v = newValue { UserDefaults.standard.set(v, forKey: key) } else { UserDefaults.standard.removeObject(forKey: key) } }
    }
    /// Os microfones ligados (nome e identificador).
    static func available() -> [(id: String, name: String)] {
        AVCaptureDevice.DiscoverySession(deviceTypes: [.microphone, .external], mediaType: .audio, position: .unspecified).devices.map { ($0.uniqueID, $0.localizedName) }
    }
    /// O dispositivo escolhido, se ainda estiver ligado; senão o predefinido.
    static func device() -> AVCaptureDevice? {
        if let id = selectedID, let d = AVCaptureDevice(uniqueID: id) { return d }
        return AVCaptureDevice.default(for: .audio)
    }
    static var selectedName: String {
        if let id = selectedID, let d = AVCaptureDevice(uniqueID: id) { return d.localizedName }
        return L("Predefinido do sistema")
    }
}

/// Grava a narração do microfone para um M4A (AAC), com `AVCaptureSession`, enquanto o vídeo toca.
final class NarrationRecorder: NSObject, AVCaptureAudioDataOutputSampleBufferDelegate, @unchecked Sendable {
    enum Failure: LocalizedError {
        case noMicrophone, writer(String)
        var errorDescription: String? {
            switch self {
            case .noMicrophone: L("Não há nenhum microfone disponível.")
            case let .writer(m): L("Não foi possível escrever o áudio: %@", m)
            }
        }
    }

    let url: URL
    private let session = AVCaptureSession()
    private let output = AVCaptureAudioDataOutput()
    private let writer: AVAssetWriter
    private let input: AVAssetWriterInput
    private let queue = DispatchQueue(label: "pt.toth.narration")
    private var started = false, finished = false
    private var startPTS: CMTime?
    private var lastEnd = CMTime.zero

    init(to url: URL, device: AVCaptureDevice?) throws {
        self.url = url
        guard let device else { throw Failure.noMicrophone }
        try? FileManager.default.removeItem(at: url)
        writer = try AVAssetWriter(outputURL: url, fileType: .m4a)
        input = AVAssetWriterInput(mediaType: .audio, outputSettings: [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 48_000, AVNumberOfChannelsKey: 1, AVEncoderBitRateKey: 96_000])
        input.expectsMediaDataInRealTime = true
        guard writer.canAdd(input) else { throw Failure.writer("formato não suportado") }
        writer.add(input)
        super.init()
        let devInput = try AVCaptureDeviceInput(device: device)
        session.beginConfiguration()
        guard session.canAddInput(devInput), session.canAddOutput(output) else { throw Failure.noMicrophone }
        session.addInput(devInput); session.addOutput(output)
        output.setSampleBufferDelegate(self, queue: queue)
        session.commitConfiguration()
    }

    func start() throws {
        guard writer.startWriting() else { throw Failure.writer(writer.error?.localizedDescription ?? "?") }
        session.startRunning()
        started = true
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sb: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard started, !finished, input.isReadyForMoreMediaData else { return }
        let pts = CMSampleBufferGetPresentationTimeStamp(sb)
        if startPTS == nil { startPTS = pts; writer.startSession(atSourceTime: pts) }
        if input.append(sb) { lastEnd = CMTimeAdd(pts, CMSampleBufferGetDuration(sb)) }
    }

    /// Para e fecha o ficheiro; devolve-o com a duração gravada.
    func finish() async throws -> (URL, Double) {
        session.stopRunning()
        return try await withCheckedThrowingContinuation { cont in
            queue.async { [self] in
                finished = true
                guard let s = startPTS else { writer.cancelWriting(); cont.resume(returning: (url, 0)); return }
                input.markAsFinished()
                writer.endSession(atSourceTime: lastEnd)
                let len = CMTimeSubtract(lastEnd, s).seconds
                writer.finishWriting {
                    if self.writer.status == .completed { cont.resume(returning: (self.url, len)) }
                    else { cont.resume(throwing: Failure.writer(self.writer.error?.localizedDescription ?? "?")) }
                }
            }
        }
    }
}
