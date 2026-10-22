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
        private var delivered = false

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
            if session.isRunning {
                DispatchQueue.global(qos: .userInitiated).async { self.session.stopRunning() }
            }
        }

        func metadataOutput(_ output: AVCaptureMetadataOutput, didOutput metadataObjects: [AVMetadataObject], from connection: AVCaptureConnection) {
            guard !delivered else { return }
            guard let object = metadataObjects.first as? AVMetadataMachineReadableCodeObject,
                  object.type == .qr,
                  let value = object.stringValue else { return }
            delivered = true
            onCode(value)
        }
    }
}

final class CameraPreviewView: UIView {
    override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }

    var previewLayer: AVCaptureVideoPreviewLayer {
        layer as! AVCaptureVideoPreviewLayer
    }
}
