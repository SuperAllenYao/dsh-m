import SwiftUI
import UIKit

// MARK: - 预览数据模型（DD-05 / DD-07 / AC-14～AC-20）

/// 预览层里一张图的来源。
///
/// 只有两个来源：消息附件（`AttachmentStore`，按附件 id 缓存完整图片）与工作区文件
/// （`WorkspaceImageClient`，每次打开重新 `stat` + 取字节，不缓存）。两源的缓存语义
/// 各自内聚，预览层只按来源取图，不重复实现缓存判断。
enum ImagePreviewItem: Equatable {
    /// 消息附件图：走 `AttachmentStore` 的完整图片（含加载中 / 失败占位）。
    case attachment(ImageRef)
    /// 工作区里的图片文件：走 `WorkspaceImageClient` 的原始字节。
    case file(path: String)

    /// 稳定身份（切换与去重口径）：附件用 `attachmentId`，文件用路径。
    var id: String {
        switch self {
        case .attachment(let ref):
            return "attachment:" + (ref.attachmentId ?? "")
        case .file(let path):
            return "file:" + path
        }
    }

    /// a11y 标识后缀：设计 §6 约定 `image-preview-image-<attachmentId>`；
    /// 文件图没有附件 id，用路径补全（AC-14 / AC-16 两条源都要能定位）。
    var accessibilitySuffix: String {
        switch self {
        case .attachment(let ref):
            return ref.attachmentId ?? ""
        case .file(let path):
            return path
        }
    }
}

/// 一次预览请求 = 该入口的整组图 + 起始下标。
///
/// 组与起点由入口（三处缩略图 / 正文图片文件链接）决定；预览层只在这一组内切图，
/// 到组边界即停，不串到别的行（AC-18）。
struct ImagePreviewRequest: Equatable {
    var items: [ImagePreviewItem]
    var startIndex: Int
}

extension ImagePreviewRequest: Identifiable {
    /// `fullScreenCover(item:)` 需要 `Identifiable`。用「整组身份 + 起点」表示一次打开；
    /// 关闭时 binding 由系统置 `nil`，预览状态随之清空（AC-19）。
    var id: String {
        items.map(\.id).joined(separator: "|") + "#\(startIndex)"
    }
}

extension ImagePreviewRequest {
    /// 三处缩略图调用点共用的构造口径：整行附件图组 + 起始下标。
    ///
    /// 起点越界（理论上不该发生）返回 `nil`，入口保持原行为、不弹空预览。
    init?(attachments images: [ImageRef], startIndex: Int) {
        guard images.indices.contains(startIndex) else { return nil }
        self.init(items: images.map { .attachment($0) }, startIndex: startIndex)
    }
}

// MARK: - 环境动作（缩略图 → 上层承载）

private struct ImagePreviewActionKey: EnvironmentKey {
    static let defaultValue: ((ImagePreviewRequest) -> Void)? = nil
}

extension EnvironmentValues {
    /// 打开全屏图片预览的动作；`nil` = 没人承载（缩略图保持不可点，行为不变）。
    ///
    /// 用环境值而不是单例/通知：缩略图挂在虚拟化行、卡片与工具详情弹层里，
    /// 需要知道「谁来呈现」的只有最近的会话详情（DD-05）。
    var imagePreviewAction: ((ImagePreviewRequest) -> Void)? {
        get { self[ImagePreviewActionKey.self] }
        set { self[ImagePreviewActionKey.self] = newValue }
    }
}

// MARK: - 预览层

/// 图片全屏预览层（DD-07）。全工程首个 `.fullScreenCover` 承载。
///
/// 交互口径对齐设计稿 `#lightbox` / `#lightbox-zoom` / `#swipe-2`：
/// - 1× = 整图等比适配屏内、不裁切；
/// - `MagnifyGesture` 1×–4×；放大态 `DragGesture` 平移，按「图片实际显示尺寸」夹边界；
/// - 双击 1× / 2.4× 切换（当前已放大时双击回 1×）；
/// - 1× 横滑超过阈值切组内上/下一张（组边界停住）；放大态横滑只平移；
/// - 1× 纵向下滑超过阈值关闭；关闭按钮与下滑都退出并清预览状态。
///
/// 不引入 UIKit、不接管导航：呈现与退出完全交给 `.fullScreenCover`，
/// 因此系统边缘返回手势在下层页面被模态层遮住，不会误 pop（DD-07 的取舍）。
struct ImagePreviewView: View {
    /// 缩放上限（AC-17：1×–4×）。
    private static let maxScale: CGFloat = 4
    /// 双击放大档（DEC-06 定的口径，不是任意值）。
    private static let doubleTapScale: CGFloat = 2.4
    /// 「已放大」判定阈值：浮点捏合收尾常在 1.000x 附近，1.01 以上才算放大态
    /// （与设计稿 `#lightbox-zoom` 的 `scale > 1.01` 同口径）。
    private static let zoomedThreshold: CGFloat = 1.01
    /// 1× 横滑切图阈值（设计稿 `#lightbox` 的 `|dx| > 60`）。
    private static let swipeThreshold: CGFloat = 60
    /// 1× 下滑关闭阈值（设计稿 `#lightbox` 的 `dy > 90`）。
    private static let dismissThreshold: CGFloat = 90
    /// 手势提示自动隐藏延时（设计稿 `#lightbox` 的 2.6s）。
    private static let hintAutoHideNanoseconds: UInt64 = 2_600_000_000

    private let request: ImagePreviewRequest
    private let sessionId: String
    @ObservedObject private var attachments: AttachmentStore
    private let link: LinkService

    @Environment(\.dismiss) private var dismiss

    /// 组内当前下标；起点由入口指定（越界自动夹回组内）。
    @State private var index: Int
    /// 当前图的重取次数：>0 只用于「附件重试必须先清 failed」与文件重取（AC-20）。
    @State private var attempt = 0

    @State private var scale: CGFloat = 1
    @State private var offset: CGSize = .zero
    private struct GestureBase: Equatable {
        var scale: CGFloat?
        var offset: CGSize?
    }
    @State private var gestureBase = GestureBase()
    /// 1× 下滑时的跟手位移（松手未过阈值即回零）。
    @State private var pullDownOffset: CGFloat = 0
    @State private var showsHint = true

    /// `.file` 的当前图；切换图片时清空——文件图每次打开重新取，不跨张缓存。
    @State private var fileImage: UIImage?
    /// `.file` 的失败原因（`WorkspaceImageClient.Failure` 的用户可见文案）。
    @State private var fileError: String?

    init(
        request: ImagePreviewRequest,
        sessionId: String,
        attachments: AttachmentStore,
        link: LinkService
    ) {
        self.request = request
        self.sessionId = sessionId
        _attachments = ObservedObject(wrappedValue: attachments)
        self.link = link
        let count = request.items.count
        _index = State(initialValue: count == 0 ? 0 : min(max(request.startIndex, 0), count - 1))
    }

    var body: some View {
        VStack(spacing: 0) {
            topBar
            stage
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black.ignoresSafeArea())
        .statusBarHidden(true)
        // 先声明容器再命名：标识落在预览层自身，关闭/序号/重试等子元素保留自己的标识（DEF-007）。
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("image-preview-layer")
        .task {
            // 手势提示：出现 2.6s 后淡出，不占位、不挡手势。
            try? await Task.sleep(nanoseconds: Self.hintAutoHideNanoseconds)
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.3)) { showsHint = false }
        }
        .task(id: loadKey) {
            await loadCurrent()
        }
    }

    // MARK: 顶部栏（关闭 / 序号）

    private var topBar: some View {
        HStack(spacing: 0) {
            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 34, height: 34)
                    .background(Circle().fill(Color.white.opacity(0.12)))
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("image-preview-close")
            .accessibilityLabel(L10n.t("关闭"))

            Spacer(minLength: 8)

            Text(counterText)
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(Color.white.opacity(0.72))
                .monospacedDigit()
                .accessibilityIdentifier("image-preview-counter")
        }
        .padding(.horizontal, 14)
        .padding(.top, 12)
        .padding(.bottom, 8)
    }

    // MARK: 舞台（图 / 加载中 / 失败）

    private var stage: some View {
        GeometryReader { proxy in
            let container = proxy.size
            ZStack {
                if let image = currentImage {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFit()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .scaleEffect(scale)
                        .offset(displayOffset)
                        .accessibilityIdentifier(imageAccessibilityIdentifier)
                } else if let reason = failureReason {
                    errorState(reason: reason)
                } else {
                    loadingState
                }
            }
            .frame(width: container.width, height: container.height)
            .contentShape(Rectangle())
            // 手势挂在整块舞台上：1× 横滑可从图片外的留白处开始（图片未必填满屏幕）。
            .gesture(magnifyGesture(container: container))
            .simultaneousGesture(dragGesture(container: container))
            .onTapGesture(count: 2) { toggleZoom(container: container) }
            .overlay(alignment: .top) { hintChip }
            .overlay(alignment: .topTrailing) { zoomChip }
        }
    }

    private var loadingState: some View {
        VStack(spacing: 10) {
            ProgressView()
                .tint(.white)
            Text(L10n.t("加载原图…"))
                .font(.system(size: 11))
                .foregroundStyle(Color.white.opacity(0.55))
        }
        .allowsHitTesting(false)
    }

    private func errorState(reason: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 30, weight: .light))
                .foregroundStyle(Color.white.opacity(0.5))
            Text(L10n.t("图片加载失败"))
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Color.white.opacity(0.75))
            Text(reason)
                .font(.system(size: 11))
                .foregroundStyle(Color.white.opacity(0.45))
                .multilineTextAlignment(.center)
            Button {
                retry()
            } label: {
                Text(L10n.t("重试"))
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 6)
                    .background(Capsule().fill(Color.white.opacity(0.12)))
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("image-preview-retry")
        }
        .padding(24)
    }

    private var hintChip: some View {
        Text(L10n.t("双指捏合缩放 · 双击放大 · 下滑关闭"))
            .font(.system(size: 11))
            .foregroundStyle(Color.white.opacity(0.55))
            .padding(.horizontal, 12)
            .padding(.vertical, 5)
            .background(Capsule().fill(Color.white.opacity(0.06)))
            .padding(.top, 8)
            .opacity(showsHint ? 1 : 0)
            .allowsHitTesting(false)
    }

    /// 放大时右上角显示当前倍率（设计稿 `#lightbox-zoom` 的 1.0×/2.4× 提示）。
    @ViewBuilder
    private var zoomChip: some View {
        if scale > Self.zoomedThreshold {
            Text(String(format: "%.1f×", scale))
                .font(Theme.Typography.monoSmall)
                .foregroundStyle(Color.white.opacity(0.6))
                .padding(.top, 6)
                .padding(.trailing, 14)
                .allowsHitTesting(false)
        }
    }

    // MARK: 手势

    private func magnifyGesture(container: CGSize) -> some Gesture {
        MagnifyGesture(minimumScaleDelta: 0.01)
            .onChanged { value in
                if gestureBase.scale == nil { gestureBase.scale = scale }
                let base = gestureBase.scale ?? scale
                scale = min(max(base * value.magnification, 1), Self.maxScale)
            }
            .onEnded { _ in
                gestureBase.scale = nil
                // 捏合收尾可能停在 1.00x 附近：贴回 1× 并清平移，避免半透明边的错觉。
                if scale < Self.zoomedThreshold {
                    scale = 1
                    offset = .zero
                } else {
                    offset = clampedOffset(offset, container: container)
                }
            }
    }

    private func dragGesture(container: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 8)
            .onChanged { value in
                if scale > Self.zoomedThreshold {
                    // 放大态：只平移，并按图片实际显示尺寸夹边界（不出现图片外黑边）。
                    if gestureBase.offset == nil { gestureBase.offset = offset }
                    let base = gestureBase.offset ?? .zero
                    let proposed = CGSize(
                        width: base.width + value.translation.width,
                        height: base.height + value.translation.height
                    )
                    offset = clampedOffset(proposed, container: container)
                } else if value.translation.height > 0 {
                    // 1× 下滑：跟手位移，松手过阈值才关闭。
                    pullDownOffset = value.translation.height
                }
            }
            .onEnded { value in
                if scale > Self.zoomedThreshold {
                    gestureBase.offset = nil
                    offset = clampedOffset(offset, container: container)
                    return
                }
                pullDownOffset = 0
                let translation = value.translation
                if translation.height > Self.dismissThreshold,
                   abs(translation.height) > abs(translation.width) {
                    // 下滑关闭：`.fullScreenCover(item:)` 会在退出时把请求置 nil（AC-19）。
                    dismiss()
                    return
                }
                guard abs(translation.width) > Self.swipeThreshold,
                      abs(translation.width) > abs(translation.height) else { return }
                selectItem(movingBy: translation.width < 0 ? 1 : -1)
            }
    }

    /// 双击切换 1× / 2.4×；当前已放大时双击回 1×（DEC-06）。
    private func toggleZoom(container: CGSize) {
        withAnimation(Theme.Motion.standard) {
            if scale > Self.zoomedThreshold {
                scale = 1
                offset = .zero
                pullDownOffset = 0
            } else {
                scale = Self.doubleTapScale
                offset = clampedOffset(.zero, container: container)
            }
        }
    }

    // MARK: 切图 / 重试

    /// 组内切图：越界不动 = 到组边界停住，不串组（AC-18）。
    private func selectItem(movingBy delta: Int) {
        let target = index + delta
        guard request.items.indices.contains(target) else { return }
        index = target
        attempt = 0
        resetGestureState()
        fileImage = nil
        fileError = nil
    }

    private func resetGestureState() {
        scale = 1
        offset = .zero
        pullDownOffset = 0
        gestureBase = GestureBase()
    }

    private func retry() {
        fileError = nil
        fileImage = nil
        attempt += 1
    }

    // MARK: 数据

    private var currentItem: ImagePreviewItem? {
        request.items.indices.contains(index) ? request.items[index] : nil
    }

    /// `.task(id:)` 的触发键：换图或重试都会重跑加载。
    private var loadKey: String {
        "\(index)#\(attempt)"
    }

    private var counterText: String {
        let total = request.items.count
        guard total > 0 else { return "0 / 0" }
        return "\(min(index + 1, total)) / \(total)"
    }

    private var currentImage: UIImage? {
        guard let currentItem else { return nil }
        switch currentItem {
        case .attachment(let ref):
            return attachments.image(for: ref)
        case .file:
            return fileImage
        }
    }

    /// 失败原因（nil = 没失败，可能仍在加载）。
    private var failureReason: String? {
        guard let currentItem else { return L10n.t("没有可预览的图片") }
        switch currentItem {
        case .attachment(let ref):
            guard let attachmentId = ref.attachmentId else { return L10n.t("附件标识缺失") }
            // 附件失败原因由 `AttachmentStore` 归一成「取不到字节」，文案取设计稿 #image-error。
            return attachments.failed.contains(attachmentId)
                ? L10n.t("网络中断或附件已不存在")
                : nil
        case .file:
            return fileError
        }
    }

    private var imageAccessibilityIdentifier: String {
        "image-preview-image-" + (currentItem?.accessibilitySuffix ?? "")
    }

    private var displayOffset: CGSize {
        // 放大态用拖动平移量；1× 只跟手下滑（横滑不移动画面）。
        scale > Self.zoomedThreshold
            ? offset
            : CGSize(width: 0, height: max(0, pullDownOffset))
    }

    @MainActor
    private func loadCurrent() async {
        guard let currentItem else { return }
        switch currentItem {
        case .attachment(let ref):
            guard ref.attachmentId != nil else { return }
            if attempt > 0 {
                // AC-20 / DD-10：重试先清该附件的失败记录再重新取图；
                // `AttachmentStore.retry` 内部即「failed.remove + ensureLoaded」。
                attachments.retry(ref)
            } else {
                attachments.ensureLoaded(ref)
            }
        case .file(let path):
            await loadFileImage(path: path)
        }
    }

    /// 文件图：每次打开重新 `stat` + 取字节，不缓存（AC-16 / AC-13 同源口径）。
    @MainActor
    private func loadFileImage(path: String) async {
        fileError = nil
        let client = WorkspaceImageClient(link: link)
        do {
            let payload = try await client.load(sessionId: sessionId, path: path)
            guard !Task.isCancelled else { return }
            if let image = UIImage(data: payload.data) {
                fileImage = image
            } else {
                fileError = L10n.t("图片格式无法解码")
            }
        } catch let failure as WorkspaceImageClient.Failure {
            guard !Task.isCancelled, failure != .cancelled else { return }
            fileError = failure.errorDescription ?? L10n.t("图片读取失败")
        } catch {
            guard !Task.isCancelled else { return }
            fileError = L10n.t("图片读取失败")
        }
    }

    // MARK: 边界夹紧

    /// 1× 时图片按等比适配后的实际显示尺寸（点）。
    private func imageDisplaySize(in container: CGSize) -> CGSize {
        guard let image = currentImage,
              image.size.width > 0, image.size.height > 0,
              container.width > 0, container.height > 0 else { return .zero }
        let factor = min(container.width / image.size.width, container.height / image.size.height)
        return CGSize(width: image.size.width * factor, height: image.size.height * factor)
    }

    /// 平移边界：让图片边缘不进入屏幕内、也不越过屏幕边——即最大平移量
    /// `(缩放后显示宽 - 容器宽) / 2`（与设计稿 `clampPan` 同口径，但用图片实际显示
    /// 尺寸而非整个舞台，防止「图片比屏幕窄却可平移出黑边」）。
    private func clampedOffset(_ proposed: CGSize, container: CGSize) -> CGSize {
        let displayed = imageDisplaySize(in: container)
        guard displayed.width > 0, displayed.height > 0 else { return .zero }
        let maxX = max(0, (displayed.width * scale - container.width) / 2)
        let maxY = max(0, (displayed.height * scale - container.height) / 2)
        return CGSize(
            width: min(max(proposed.width, -maxX), maxX),
            height: min(max(proposed.height, -maxY), maxY)
        )
    }
}
