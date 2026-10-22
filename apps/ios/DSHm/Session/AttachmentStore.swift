import Combine
import Foundation
import UIKit

/// Loads and caches image attachment bytes.
///
/// Attachments only carry metadata in events; bytes come from the unary
/// `session/attachment` endpoint (base64) — see protocol §8.2 / ui-baseline §6.
@MainActor
final class AttachmentStore: ObservableObject {
    @Published private(set) var images: [String: UIImage] = [:]
    @Published private(set) var failed: Set<String> = []

    let sessionId: String
    private weak var link: LinkService?
    private var loading: Set<String> = []

    init(sessionId: String) {
        self.sessionId = sessionId
    }

    func attach(link: LinkService) {
        self.link = link
    }

    func image(for ref: ImageRef) -> UIImage? {
        guard let id = ref.attachmentId else { return nil }
        return images[id]
    }

    func ensureLoaded(_ ref: ImageRef) {
        guard let attachmentId = ref.attachmentId else { return }
        guard images[attachmentId] == nil, !loading.contains(attachmentId), !failed.contains(attachmentId) else { return }
        guard let link else { return }
        loading.insert(attachmentId)
        Task { [weak self] in
            guard let self else { return }
            do {
                let result = try await link.attachmentData(sessionId: self.sessionId, attachmentId: attachmentId)
                if let image = UIImage(data: result.data) {
                    self.images[attachmentId] = image
                } else {
                    self.failed.insert(attachmentId)
                }
            } catch {
                self.failed.insert(attachmentId)
            }
            self.loading.remove(attachmentId)
        }
    }
}
