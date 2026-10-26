import AVFoundation
import SwiftUI

/// AVFoundation QR scanner. The camera is unavailable in the iOS Simulator, so
/// callers show a paste-payload fallback there (see PairingView).
struct QRScannerView: UIViewRepresentable {
    var onCode: (String) -> Void
    var onUnavailable: (() -> Void)? = nil

    func makeCoordinator() -> Coordinator {
        Coordinator(onCode: onCode, onUnavailable: onUnavailable)
    }

    func makeUIView(context: Context) -> CameraPreviewView {
        let view = CameraPreviewView()
        context.coordinator.attach(to: view)
        return view
    }

    func updateUIView(_ uiView: CameraPreviewView, context: Context) {}

    static func dismantleUIView(_ uiView: CameraPreviewView, coordinator: Coordinator) {
        coordinator.stop()
    }

    final class Coordinator: NSObject, AVCaptureMetadataOutputObjectsDelegate {
        private let session = AVCaptureSession()
        private let onCode: (String) -> Void
        private let onUnavailable: (() -> Void)?
        private var configured = false
        private var gate = QRRedeliveryGate()
        private var idleReset: DispatchWorkItem?

        init(onCode: @escaping (String) -> Void, onUnavailable: (() -> Void)?) {
            self.onCode = onCode
            self.onUnavailable = onUnavailable
        }

        func attach(to view: CameraPreviewView) {
            view.previewLayer.session = session
            view.previewLayer.videoGravity = .resizeAspectFill
            let status = AVCaptureDevice.authorizationStatus(for: .video)
            switch status {
            case .authorized:
                configure()
            case .notDetermined:
                AVCaptureDevice.requestAccess(for: .video) { granted in
                    DispatchQueue.main.async {
                        if granted { self.configure() } else { self.onUnavailable?() }
                    }
                }
            default:
                onUnavailable?()
            }
        }

        private func configure() {
            guard !configured else { return }
            configured = true
            DispatchQueue.global(qos: .userInitiated).async {
                guard let device = AVCaptureDevice.default(for: .video),
                      let input = try? AVCaptureDeviceInput(device: device),
                      self.session.canAddInput(input) else {
                    DispatchQueue.main.async { self.onUnavailable?() }
                    return
                }
                self.session.beginConfiguration()
                self.session.addInput(input)
                let output = AVCaptureMetadataOutput()
                if self.session.canAddOutput(output) {
                    self.session.addOutput(output)
                    output.setMetadataObjectsDelegate(self, queue: .main)
                    output.metadataObjectTypes = [.qr]
                }
                self.session.commitConfiguration()
                self.session.startRunning()
            }
        }

        func stop() {
            idleReset?.cancel()
            idleReset = nil
            if session.isRunning {
                DispatchQueue.global(qos: .userInitiated).async { self.session.stopRunning() }
            }
        }

        func metadataOutput(_ output: AVCaptureMetadataOutput, didOutput metadataObjects: [AVMetadataObject], from connection: AVCaptureConnection) {
            guard let object = metadataObjects.first as? AVMetadataMachineReadableCodeObject,
                  object.type == .qr,
                  let value = object.stringValue else { return }
            let now = ProcessInfo.processInfo.systemUptime
            guard gate.receive(value, at: now) else { return }
            onCode(value)
            scheduleIdleReset(after: QRRedeliveryGate.idleResetDelay)
        }

 /// Spec P2-1: a payload that is still in the camera frame is delivered
 /// **once** (the old unconditional 1.25 s reset re-fired the same QR over
 /// and over → pairing retried with no user action, wiping the failure text).
 /// Re-delivery needs either a different payload (Mac refreshed the QR) or
 /// the same payload having left the frame for ≥1 s. This timer only opens
 /// the latch when the camera went silent right after delivery (QR removed);
 /// while the QR stays in frame frames keep arriving and the latch holds.
        private func scheduleIdleReset(after delay: TimeInterval) {
            idleReset?.cancel()
            let item = DispatchWorkItem { [weak self] in
                guard let self else { return }
                self.gate.resetIfCameraIdle(now: ProcessInfo.processInfo.systemUptime)
                self.idleReset = nil
            }
            idleReset = item
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
        }
    }
}

/// Spec P2-1 / A4 delivery gate for the QR scanner.
///
/// The camera metadata output fires continuously (~30 fps) while a QR stays in
/// the frame. The gate collapses that stream into **one delivery per distinct
/// payload**, and only re-arms when:
/// (a) the payload content changes (the Mac refreshed the QR after rotation /
/// expiry), or
/// (b) the same payload left the camera for at least `reappearGap` seconds and
/// came back (the user physically moved the phone away and re-aimed).
///
/// Pure value type: the timing rules are unit-tested instead of only observed on
/// a device.
struct QRRedeliveryGate {
 /// A missing-callback gap of at least this long means the code left the frame.
    static let reappearGap: TimeInterval = 1.0
 /// How long after a delivery we check whether the camera went silent.
    static let idleResetDelay: TimeInterval = 1.25

 /// Sticky latch: the payload that was already delivered.
    private(set) var lastDeliveredValue: String?
 /// Timestamp of the most recent metadata callback (delivered or ignored).
    private(set) var lastCallbackAt: TimeInterval?
 /// Timestamp of the most recent delivery.
    private(set) var lastDeliveredAt: TimeInterval?

 /// Records one metadata callback and returns true when it must be delivered.
    mutating func receive(_ value: String, at now: TimeInterval) -> Bool {
        let gap = lastCallbackAt.map { now - $0 } ?? .infinity
        lastCallbackAt = now
        if value == lastDeliveredValue, gap < Self.reappearGap {
 // Same payload, still in the frame: swallow the frame burst.
            return false
        }
        lastDeliveredValue = value
        lastDeliveredAt = now
        return true
    }

 /// Called `idleResetDelay` after a delivery: if no frame callback arrived since,
 /// the QR left the camera, so the same payload may be scanned again later.
    mutating func resetIfCameraIdle(now: TimeInterval) {
        guard let callbackAt = lastCallbackAt, let deliveredAt = lastDeliveredAt else { return }
        guard callbackAt <= deliveredAt else { return }
        lastDeliveredValue = nil
        lastDeliveredAt = nil
    }
}

final class CameraPreviewView: UIView {
    override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }

    var previewLayer: AVCaptureVideoPreviewLayer {
        layer as! AVCaptureVideoPreviewLayer
    }
}
