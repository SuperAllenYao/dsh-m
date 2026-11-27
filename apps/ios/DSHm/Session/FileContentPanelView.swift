import SwiftUI
import UIKit

/// 文件内容面板（DD-03 / DD-04 / DD-10；AC-04～AC-13 的可见载体）。
///
/// - 面板头：文件名 / 路径 / `语言 · 大小 · 只读`；总行数只在 `eof` 后追加「共 N 行」。
/// - 正文：逐行带绝对行号（等宽、行号列、横向可滚），只读、无编辑入口。
/// - 提示条：非 `eof` 显示「已加载 N 行」+「加载更多（300 行/次）」；`eof` 后显示「共 N 行」并撤掉按钮。
/// - 二进制 / 行太长 / 版本不支持 / 错误态各自成屏；错误态给原因 + 「重试」，
///   重试仍失败由 `FileContentFailure.displayReason` 追加「仍然读取失败」。
/// - 每次打开新建 `FileContentLoader`、关闭即释放，内容不缓存（AC-12、AC-13）。
/// - 展开 / 收起走抓柄拖拽（需求 §3、DD-04），不提供独立的展开按钮。
///
/// 承载方式：由 `SessionDetailSheet.file(path:)` 经共享弹层（`BottomSheetLayer`）呈现；
/// 面板只声明「初始高度 60%」这一 opt-in 偏好，默认不声明的其它弹层保持现状（DD-04）。
struct FileContentPanelView: View {
    let sessionId: String
    let path: String
    let link: LinkService

    @StateObject private var loader: FileContentLoader

    /// 面板初始高度占屏幕高度的比例（DD-04 的 opt-in；默认 nil 的弹层维持现状）。
    static let initialHeightFraction: CGFloat = 0.6

    init(sessionId: String, path: String, link: LinkService) {
        self.sessionId = sessionId
        self.path = path
        self.link = link
        _loader = StateObject(
            wrappedValue: FileContentLoader(sessionId: sessionId, path: path, link: link)
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Rectangle()
                .fill(Theme.Palette.border)
                .frame(height: 1)
            content
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Theme.Palette.surfaceRaised)
        // 先声明容器再命名：标识落在容器自身，避免容器标识下发覆盖子元素自己的标识（DEF-007）。
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("file-content-sheet")
        .sheetResizable()
        .sheetInitialHeightFraction(Self.initialHeightFraction)
        .task { await loader.start() }
    }

    // MARK: - 面板头

    private var header: some View {
        HStack(alignment: .top, spacing: Theme.Spacing.xs) {
            Image(systemName: "doc.text")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Theme.Palette.accent)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 2) {
                Text(loader.metadata.fileName)
                    .font(Theme.Typography.cardTitle)
                    .foregroundStyle(Theme.Palette.textPrimary)
                    .lineLimit(1)
                Text(loader.metadata.path)
                    .font(Theme.Typography.monoSmall)
                    .foregroundStyle(Theme.Palette.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .accessibilityLabel(loader.metadata.path)
                    .accessibilityIdentifier("file-content-path")
                Text(metaLine)
                    .font(Theme.Typography.label)
                    .foregroundStyle(Theme.Palette.textTertiary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, Theme.Spacing.m)
        .padding(.vertical, Theme.Spacing.s)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// `语言 · 大小 · 只读`；大小未知时省略；总行数只在 `eof` 后出现（DD-03）。
    private var metaLine: String {
        var parts: [String] = [Self.languageLabel(forExtension: loader.metadata.fileExtension)]
        if let byteCount = loader.metadata.byteCount {
            parts.append(Self.byteCountText(byteCount))
        }
        parts.append(L10n.t("只读"))
        if let totalLines = loader.state.textValue?.totalLines {
            parts.append(L10n.f("共 %lld 行", totalLines))
        }
        return parts.joined(separator: " · ")
    }

    // MARK: - 状态分发

    @ViewBuilder
    private var content: some View {
        switch loader.state {
        case .loading:
            loadingState
        case .text(let text):
            textState(text)
        case .binary(let binary):
            binaryState(binary)
        case .large:
            terminalState(
                icon: "ruler",
                title: L10n.t("文件行太长，无法继续加载"),
                detail: L10n.t("这一页有超长行，桌面端无法按文本返回。")
            )
        case .unsupported:
            terminalState(
                icon: "desktopcomputer",
                title: L10n.t("桌面端版本不支持查看文件"),
                detail: L10n.t("请升级桌面端后再试；其它功能不受影响。")
            )
        case .error(let failure):
            errorState(failure)
        }
    }

    private var loadingState: some View {
        VStack(spacing: Theme.Spacing.xs) {
            ProgressView()
                .tint(Theme.Palette.accent)
            Text(L10n.t("正在读取文件…"))
                .font(Theme.Typography.callout)
                .foregroundStyle(Theme.Palette.textSecondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - 文本态

    private func textState(_ text: FileContentText) -> some View {
        VStack(spacing: 0) {
            loadMoreBar(text)
            codeScroll(text)
        }
    }

    /// 「加载更多」提示条：已加载行数 + 按钮；`eof` 后显示总数并撤掉按钮（AC-09）。
    /// 「加载更多」失败时保留已加载行，改为失败原因 + 「重试」（§5 第 3 条）。
    @ViewBuilder
    private func loadMoreBar(_ text: FileContentText) -> some View {
        HStack(spacing: Theme.Spacing.xs) {
            if let failure = text.loadMoreFailure {
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Theme.Palette.danger)
                Text(failure.displayReason)
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.Palette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: Theme.Spacing.xs)
                retryControl
            } else if let totalLines = text.totalLines {
                Text(L10n.t("已到文件末尾"))
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.Palette.textTertiary)
                Text(L10n.f("共 %lld 行", totalLines))
                    .font(Theme.Typography.captionMedium)
                    .foregroundStyle(Theme.Palette.textSecondary)
                    .accessibilityIdentifier("file-content-end")
                Spacer(minLength: 0)
            } else {
                Text(L10n.f("已加载 %lld 行", text.loadedLines))
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.Palette.textSecondary)
                Spacer(minLength: Theme.Spacing.xs)
                Button {
                    Task { await loader.loadMore() }
                } label: {
                    HStack(spacing: Theme.Spacing.xxs) {
                        if text.isLoadingMore {
                            ProgressView()
                                .controlSize(.mini)
                                .tint(Theme.Palette.accent)
                        }
                        Text(L10n.f("加载更多（%lld 行/次）", FileContentLoader.pageLines))
                            .font(Theme.Typography.label)
                            .foregroundStyle(Theme.Palette.accent)
                    }
                }
                .buttonStyle(.plain)
                .disabled(!loader.canLoadMore)
                .accessibilityIdentifier("file-content-load-more")
            }
        }
        .padding(.horizontal, Theme.Spacing.m)
        .padding(.vertical, Theme.Spacing.xs)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.Palette.accentSoft)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Theme.Palette.accentBorder)
                .frame(height: 1)
        }
        .contentShape(Rectangle())
        .onTapGesture {
            // 提示条整条可点只是便捷区（呈现级取舍）：验收入口是条内的
            // `file-content-load-more` 按钮，容器只带 `load-more-bar` 标识，避免自动化
            // 把两个都像「加载更多」的标识点错；重复触发由 loader 的
            // 「正在加载 / 已到 eof」守卫吞掉，不会重复请求。
            guard text.canLoadMore else { return }
            Task { await loader.loadMore() }
        }
        // 提示条是容器：先声明容器再命名，条内「加载更多」按钮保留自己的标识（DEF-007）。
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("load-more-bar")
    }

    private func codeScroll(_ text: FileContentText) -> some View {
        // DEF-008：两轴 ScrollView 的横向可滚范围来自 LazyVStack 的**布局宽**，而它只按
        // 已经 realized 的行算——首屏没有长行时横向范围停在「短行宽」，之后滑到长行处，
        // 长行被 `fixedSize` 撑出 14k+ 的绘制宽，但可滚内容并没有跟着变宽，横滑无效、
        // 行尾不可达（实测 deltaX=0）。这里改为按**已加载数据**算一个显式内容宽度：
        // 最宽一行 + 行号列 + 行内边距，长行在数据里就生效，与是否 realized 无关；
        // LazyVStack 仍按行懒加载，大文件分页加载不物化全部行（性能红线不变）。
        ScrollView([.horizontal, .vertical], showsIndicators: true) {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(text.lines.indices, id: \.self) { index in
                    codeLine(number: index + 1, source: text.lines[index])
                }
            }
            .padding(.vertical, Theme.Spacing.xxs)
            .frame(width: measuredContentWidth > 0 ? measuredContentWidth : nil, alignment: .leading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Theme.Palette.codeBackground)
        .onAppear { measureContentWidth(text) }
        .onChange(of: text.lines.count) { _, _ in measureContentWidth(text) }
    }

    /// 正文行的横向排版常量：渲染与「最宽一行」测量共用同一组数字。
    private enum CodeLineLayout {
        /// 行号列最小宽度（4 位以内的行号都由它兜底）。
        static let gutterMinWidth: CGFloat = 28
        /// 行内左右内边距（各一份）+ 行号与正文间距（一份）。
        static let rowHorizontalInsets = Theme.Spacing.m * 2 + Theme.Spacing.xs
        static let gutterFontSize: CGFloat = 11
        static let textFontSize: CGFloat = 12
        /// 内容宽度补偿：文本测量与 SwiftUI 排版的亚像素差，宁可略宽也不让行尾被裁。
        static let contentWidthSlack: CGFloat = 4
    }

    private static let textUIFont = UIFont.monospacedSystemFont(
        ofSize: CodeLineLayout.textFontSize, weight: .regular
    )
    private static let gutterUIFont = UIFont.monospacedSystemFont(
        ofSize: CodeLineLayout.gutterFontSize, weight: .regular
    )

    /// 已测量到的「最宽一行」渲染宽度（含行号列与行内边距）；分页追加时增量更新。
    @State private var measuredContentWidth: CGFloat = 0
    @State private var measuredLineCount = 0
    @State private var measuredGutterWidth: CGFloat = 0

    /// 增量测量：只量新增行（「加载更多」300 行 = O(300) 次文本测量），已测部分不重扫。
    /// 行号列按当前最大行号的实测宽度统一取（各行行号都 ≤ 它，只会略宽，不会裁字）。
    private func measureContentWidth(_ text: FileContentText) {
        let total = text.lines.count
        if total < measuredLineCount {
            // 重试/重开导致行数回退：清空重测。
            measuredContentWidth = 0
            measuredLineCount = 0
            measuredGutterWidth = 0
        }
        let gutter = Self.gutterWidth(lineCount: max(total, 1))
        if gutter > measuredGutterWidth {
            measuredContentWidth += gutter - measuredGutterWidth
            measuredGutterWidth = gutter
        }
        guard measuredLineCount < total else { return }
        var widest = measuredContentWidth
        for index in measuredLineCount..<total {
            widest = max(widest, Self.lineContentWidth(text.lines[index], gutter: gutter))
        }
        measuredContentWidth = widest + CodeLineLayout.contentWidthSlack
        measuredLineCount = total
    }

    private static func lineContentWidth(_ source: String, gutter: CGFloat) -> CGFloat {
        // 制表符没有公开的渲染宽度口径，按 4 空格计入（宁可略宽）。
        let measured = source.isEmpty ? " " : source.replacingOccurrences(of: "\t", with: "    ")
        let textWidth = (measured as NSString).size(withAttributes: [.font: textUIFont]).width
        return CodeLineLayout.rowHorizontalInsets + gutter + ceil(textWidth)
    }

    private static func gutterWidth(lineCount: Int) -> CGFloat {
        let digits = "\(max(lineCount, 1))"
        let width = (digits as NSString).size(withAttributes: [.font: gutterUIFont]).width
        return max(CodeLineLayout.gutterMinWidth, ceil(width))
    }

    /// 一行正文：行号列 + 源码；`fixedSize(horizontal:)` 让长行不被折行，交给横向滚动。
    private func codeLine(number: Int, source: String) -> some View {
        HStack(alignment: .top, spacing: Theme.Spacing.xs) {
            Text(String(number))
                .font(Theme.Typography.diffGutter)
                .foregroundStyle(Theme.Palette.textTertiary)
                .frame(minWidth: CodeLineLayout.gutterMinWidth, alignment: .trailing)
            Text(source.isEmpty ? " " : source)
                .font(Theme.Typography.mono)
                .foregroundStyle(Theme.Palette.textPrimary)
                .fixedSize(horizontal: true, vertical: false)
        }
        .padding(.horizontal, Theme.Spacing.m)
        .padding(.vertical, 1)
        .accessibilityIdentifier("file-content-line-\(number)")
    }

    // MARK: - 二进制 / 终态

    /// 二进制态（AC-10）：大小 + 类型 + 「二进制文件不能按文本预览」。
    private func binaryState(_ binary: FileContentBinary) -> some View {
        VStack(spacing: Theme.Spacing.xs) {
            Image(systemName: "doc.zipper")
                .font(.system(size: 28, weight: .regular))
                .foregroundStyle(Theme.Palette.textTertiary)
            Text(L10n.t("二进制文件不能按文本预览"))
                .font(Theme.Typography.cardTitle)
                .foregroundStyle(Theme.Palette.textPrimary)
                .multilineTextAlignment(.center)
            Text(binaryDetail(binary))
                .font(Theme.Typography.caption)
                .foregroundStyle(Theme.Palette.textSecondary)
                .multilineTextAlignment(.center)
            Text(L10n.t("图片文件请用链接直接打开（会进全屏预览）。"))
                .font(Theme.Typography.label)
                .foregroundStyle(Theme.Palette.textTertiary)
                .multilineTextAlignment(.center)
        }
        .padding(.horizontal, Theme.Spacing.l)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityIdentifier("file-content-binary")
    }

    private func binaryDetail(_ binary: FileContentBinary) -> String {
        var parts: [String] = [binary.typeLabel]
        if let byteCount = binary.byteCount {
            parts.insert(Self.byteCountText(byteCount), at: 0)
        }
        return parts.joined(separator: " · ")
    }

    /// 不可重试的终态（行太长 / 桌面端版本不支持）。
    private func terminalState(icon: String, title: String, detail: String) -> some View {
        VStack(spacing: Theme.Spacing.xs) {
            Image(systemName: icon)
                .font(.system(size: 28, weight: .regular))
                .foregroundStyle(Theme.Palette.textTertiary)
            Text(title)
                .font(Theme.Typography.cardTitle)
                .foregroundStyle(Theme.Palette.textPrimary)
                .multilineTextAlignment(.center)
            Text(detail)
                .font(Theme.Typography.caption)
                .foregroundStyle(Theme.Palette.textSecondary)
                .multilineTextAlignment(.center)
        }
        .padding(.horizontal, Theme.Spacing.l)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - 错误态

    /// 错误态（AC-11）：失败原因 + 「重试」；重试仍失败时追加「仍然读取失败」。
    private func errorState(_ failure: FileContentFailure) -> some View {
        VStack(spacing: Theme.Spacing.xs) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 28, weight: .regular))
                .foregroundStyle(Theme.Palette.danger)
            Text(L10n.t("读取失败"))
                .font(Theme.Typography.cardTitle)
                .foregroundStyle(Theme.Palette.textPrimary)
            Text(failure.displayReason)
                .font(Theme.Typography.caption)
                .foregroundStyle(Theme.Palette.textSecondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            Text(loader.metadata.path)
                .font(Theme.Typography.monoSmall)
                .foregroundStyle(Theme.Palette.textTertiary)
                .lineLimit(2)
                .truncationMode(.middle)
                .multilineTextAlignment(.center)
            retryControl
                .padding(.top, Theme.Spacing.xxs)
        }
        .padding(.horizontal, Theme.Spacing.l)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // 错误态是容器：先声明容器再命名，「重试」按钮保留自己的标识（DEF-007）。
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("file-content-error")
    }

    private var retryControl: some View {
        Button {
            Task { await loader.retry() }
        } label: {
            Text(L10n.t("重试"))
                .font(Theme.Typography.label)
                .foregroundStyle(Theme.Palette.accentInk)
                .padding(.horizontal, Theme.Spacing.s)
                .padding(.vertical, Theme.Spacing.xxs)
                .background(Theme.Palette.accent, in: Capsule(style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(!loader.canRetry)
        .accessibilityIdentifier("file-content-retry")
    }

    // MARK: - 展示helper

    /// 字节数文案：`B` / `KB` / `MB`，整单位不带小数（820 KB），MB 保留一位（1.0 MB）。
    static func byteCountText(_ byteCount: Int) -> String {
        guard byteCount >= 1024 else { return L10n.f("%lld B", byteCount) }
        let kilobytes = Double(byteCount) / 1024
        if kilobytes < 1024 {
            if kilobytes == kilobytes.rounded() {
                return L10n.f("%lld KB", Int(kilobytes))
            }
            return String(format: "%.1f KB", kilobytes)
        }
        return String(format: "%.1f MB", kilobytes / 1024)
    }

    /// 面板头的语言/类型标签：常见扩展名给可读语言名，其余回退大写的扩展名。
    static func languageLabel(forExtension fileExtension: String?) -> String {
        guard let ext = fileExtension, !ext.isEmpty else { return L10n.t("文本") }
        switch ext {
        case "swift": return "Swift"
        case "m", "mm": return "Objective-C"
        case "h", "c": return "C"
        case "cpp", "cc", "hpp": return "C++"
        case "md", "markdown": return "Markdown"
        case "json": return "JSON"
        case "yaml", "yml": return "YAML"
        case "toml": return "TOML"
        case "xml": return "XML"
        case "html", "htm": return "HTML"
        case "css": return "CSS"
        case "js", "mjs", "cjs": return "JavaScript"
        case "ts", "tsx", "jsx": return "TypeScript"
        case "py": return "Python"
        case "go": return "Go"
        case "rs": return "Rust"
        case "java": return "Java"
        case "kt", "kts": return "Kotlin"
        case "rb": return "Ruby"
        case "php": return "PHP"
        case "sh", "zsh", "bash": return "Shell"
        case "sql": return "SQL"
        case "log": return "Log"
        case "txt": return L10n.t("文本")
        case "csv": return "CSV"
        case "ini", "conf", "config": return L10n.t("配置")
        case "pdf": return "PDF"
        default: return ext.uppercased()
        }
    }
}
