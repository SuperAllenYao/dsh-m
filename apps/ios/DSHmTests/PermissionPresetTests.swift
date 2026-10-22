import XCTest
@testable import DSHm

/// M5: session permission preset — wire decoding (catalog + `POST /session/permission`
/// response), the plugin error-code → localized text mapping and the
/// `SessionViewModel` switch state machine (no socket: injected seams).
final class PermissionPresetTests: XCTestCase {

    // MARK: - Catalog decoding (`permissionPresets/catalog`)

    func testCatalogDecodesOptionsWithDescriptions() throws {
        let catalog = try TestJSON.value("""
        {"options":[
            {"value":"read-only","name":"只读","description":"只能读"},
            {"value":"workspace-write","name":"工作区可写","description":"工作区内可写"}
        ],"defaultPreset":"read-only"}
        """).decode(PermissionPresetCatalog.self)
        XCTAssertEqual(catalog.options.map(\.value), ["read-only", "workspace-write"])
        XCTAssertEqual(catalog.options.map(\.name), ["只读", "工作区可写"])
        XCTAssertEqual(catalog.options.first?.description, "只能读")
        XCTAssertEqual(catalog.defaultPreset, "read-only")
    }

    func testCatalogToleratesMissingDescriptionAndNullDefault() throws {
        let catalog = try TestJSON.value("""
        {"options":[
            {"value":"read-only","name":"只读"},
            {"value":"danger-full-access","name":"完全访问","description":null}
        ],"defaultPreset":null}
        """).decode(PermissionPresetCatalog.self)
        XCTAssertEqual(catalog.options.count, 2)
        XCTAssertNil(catalog.options[0].description)
        XCTAssertNil(catalog.options[1].description)
        XCTAssertNil(catalog.defaultPreset)
    }

    func testCatalogFallsBackToValueWhenNameMissing() throws {
        let catalog = try TestJSON.value("""
        {"options":[{"value":"read-only"}]}
        """).decode(PermissionPresetCatalog.self)
        XCTAssertEqual(catalog.options.first?.name, "read-only")
        XCTAssertNil(catalog.options.first?.description)
    }

    func testCatalogWithoutOptionsDecodesToEmpty() throws {
        let catalog = try TestJSON.value("{}").decode(PermissionPresetCatalog.self)
        XCTAssertTrue(catalog.options.isEmpty)
        XCTAssertNil(catalog.defaultPreset)
    }

    // MARK: - `POST /session/permission` 200 body

    func testUpdateDecodesContractBody() throws {
        let update = try TestJSON.value("""
        {"ok":true,"sessionId":"session-1","preset":"workspace-write",
         "previous":"read-only",
         "catalog":{"options":[
            {"value":"read-only","name":"只读","description":"只能读"},
            {"value":"workspace-write","name":"工作区可写"}
         ],"defaultPreset":"read-only"}}
        """).decode(SessionPermissionUpdate.self)
        XCTAssertTrue(update.ok)
        XCTAssertEqual(update.sessionId, "session-1")
        XCTAssertEqual(update.preset, "workspace-write")
        XCTAssertEqual(update.previous, "read-only")
        XCTAssertEqual(update.catalog.options.map(\.value), ["read-only", "workspace-write"])
        XCTAssertEqual(update.catalog.defaultPreset, "read-only")
    }

    func testUpdateToleratesMissingCatalogAndPrevious() throws {
        let update = try TestJSON.value("""
        {"ok":true,"preset":"read-only"}
        """).decode(SessionPermissionUpdate.self)
        XCTAssertTrue(update.ok)
        XCTAssertEqual(update.preset, "read-only")
        XCTAssertTrue(update.catalog.options.isEmpty)
        XCTAssertNil(update.previous)
    }

    // MARK: - Error code mapping

    func testErrorTextForAuthCodes() {
        for code in ["auth/required", "auth/invalid", "auth/token-expired"] {
            XCTAssertEqual(
                PermissionSwitchErrorText.message(forCode: code),
                L10n.t("设备认证已失效，请重新配对后重试"),
                code
            )
        }
        XCTAssertEqual(
            PermissionSwitchErrorText.message(forCode: "auth/revoked"),
            L10n.t("设备已被撤销，请重新配对")
        )
    }

    func testErrorTextForPermissionCodes() {
        XCTAssertEqual(
            PermissionSwitchErrorText.message(forCode: "permission/bad-request"),
            L10n.t("权限切换请求被拒绝（参数非法）")
        )
        XCTAssertEqual(
            PermissionSwitchErrorText.message(forCode: "permission/session-not-found"),
            L10n.t("会话不存在或已结束，请返回列表刷新")
        )
        XCTAssertEqual(
            PermissionSwitchErrorText.message(forCode: "permission/preset-unavailable"),
            L10n.t("该权限预设当前不可用")
        )
        XCTAssertEqual(
            PermissionSwitchErrorText.message(forCode: "permission/host-unavailable"),
            L10n.t("桌面端未就绪，请稍后重试")
        )
    }

    func testKnownCodeIgnoresHostMessage() {
        // Known codes always read the same in the App, even when the host adds a
        // message (the plugin's raw text may be developer-facing).
        XCTAssertEqual(
            PermissionSwitchErrorText.message(forCode: "permission/preset-unavailable", serverMessage: "raw"),
            L10n.t("该权限预设当前不可用")
        )
    }

    func testPermissionFailedUsesHostMessageThenFallback() {
        XCTAssertEqual(
            PermissionSwitchErrorText.message(forCode: "permission/failed", serverMessage: "host said no"),
            "host said no"
        )
        XCTAssertEqual(
            PermissionSwitchErrorText.message(forCode: "permission/failed", serverMessage: "  "),
            L10n.t("权限切换失败，请重试")
        )
        XCTAssertEqual(
            PermissionSwitchErrorText.message(forCode: "unknown/code"),
            L10n.t("权限切换失败，请重试")
        )
    }

    func testErrorTextForLinkErrorSurface() {
        XCTAssertEqual(
            PermissionSwitchErrorText.message(
                for: LinkError.remote(RemoteError(code: "permission/host-unavailable", message: ""))
            ),
            L10n.t("桌面端未就绪，请稍后重试")
        )
        XCTAssertEqual(
            PermissionSwitchErrorText.message(for: LinkError.notConnected),
            L10n.t("连接未就绪")
        )
    }

    // MARK: - ViewModel: catalog load

    @MainActor
    func testCatalogLoadPopulatesOptionsAndClearsError() async {
        let viewModel = SessionViewModel(sessionId: "s-perm")
        let expected = PermissionPresetCatalog(
            options: [
                PermissionPresetOption(value: "read-only", name: "只读", description: "只能读"),
                PermissionPresetOption(value: "workspace-write", name: "工作区可写"),
            ],
            defaultPreset: "read-only"
        )
        viewModel.permissionCatalogLoader = { expected }

        await viewModel.loadPermissionCatalogIfNeeded()

        XCTAssertEqual(viewModel.presetOptions, expected.options)
        XCTAssertEqual(viewModel.presetDefault, "read-only")
        XCTAssertNil(viewModel.permissionSwitchError)
        XCTAssertFalse(viewModel.permissionCatalogLoading)
    }

    @MainActor
    func testCatalogLoadIsLazyAfterSuccess() async {
        let viewModel = SessionViewModel(sessionId: "s-perm")
        var calls = 0
        viewModel.permissionCatalogLoader = {
            calls += 1
            return PermissionPresetCatalog(options: [])
        }

        await viewModel.loadPermissionCatalogIfNeeded()
        await viewModel.loadPermissionCatalogIfNeeded()

        XCTAssertEqual(calls, 1, "a successful catalog load is cached for the detail")
    }

    @MainActor
    func testCatalogLoadFailureStaysRetryable() async {
        let viewModel = SessionViewModel(sessionId: "s-perm")
        var attempts = 0
        viewModel.permissionCatalogLoader = {
            attempts += 1
            if attempts == 1 { throw LinkError.httpStatus(500, "boom") }
            return PermissionPresetCatalog(
                options: [PermissionPresetOption(value: "read-only", name: "只读")],
                defaultPreset: nil
            )
        }

        await viewModel.loadPermissionCatalogIfNeeded()
        XCTAssertEqual(viewModel.permissionSwitchError, L10n.f("HTTP %lld: %@", 500, "boom"))
        XCTAssertTrue(viewModel.presetOptions.isEmpty)

        // The failed load is not cached: re-opening the sheet retries.
        await viewModel.loadPermissionCatalogIfNeeded()
        XCTAssertEqual(attempts, 2)
        XCTAssertEqual(viewModel.presetOptions.map(\.value), ["read-only"])
        XCTAssertNil(viewModel.permissionSwitchError)
    }

    @MainActor
    func testCatalogLoadWithoutLinkReportsNotConnected() async {
        let viewModel = SessionViewModel(sessionId: "s-perm")
        await viewModel.loadPermissionCatalogIfNeeded()
        XCTAssertEqual(viewModel.permissionSwitchError, L10n.t("连接未就绪"))
    }

    // MARK: - ViewModel: preset switch

    @MainActor
    func testSwitchSuccessUpdatesPermissionsOptimistically() async {
        let viewModel = SessionViewModel(sessionId: "s-perm")
        let catalog = PermissionPresetCatalog(
            options: [
                PermissionPresetOption(value: "read-only", name: "只读"),
                PermissionPresetOption(value: "workspace-write", name: "工作区可写"),
            ],
            defaultPreset: "read-only"
        )
        viewModel.permissionCatalogLoader = { catalog }
        await viewModel.loadPermissionCatalogIfNeeded()
        XCTAssertNil(viewModel.permissionsValue)

        viewModel.permissionSwitcher = { preset in
            SessionPermissionUpdate(
                ok: true,
                sessionId: "s-perm",
                preset: preset,
                previous: "read-only",
                catalog: catalog
            )
        }
        await viewModel.switchPermissionPreset("workspace-write")

        XCTAssertEqual(viewModel.permissionsValue, "workspace-write")
        XCTAssertEqual(viewModel.presetOptions, catalog.options)
        XCTAssertNil(viewModel.permissionSwitchError)
        XCTAssertFalse(viewModel.permissionSwitching)
    }

    @MainActor
    func testSwitchSuccessRefreshesCatalogFromResponse() async {
        let viewModel = SessionViewModel(sessionId: "s-perm")
        viewModel.permissionSwitcher = { preset in
            SessionPermissionUpdate(
                sessionId: "s-perm",
                preset: preset,
                catalog: PermissionPresetCatalog(
                    options: [
                        PermissionPresetOption(value: "read-only", name: "只读"),
                        PermissionPresetOption(value: "danger-full-access", name: "完全访问", description: "任意路径"),
                    ],
                    defaultPreset: "read-only"
                )
            )
        }

        await viewModel.switchPermissionPreset("danger-full-access")

        XCTAssertEqual(viewModel.permissionsValue, "danger-full-access")
        XCTAssertEqual(viewModel.presetOptions.map(\.value), ["read-only", "danger-full-access"])
        XCTAssertEqual(viewModel.presetOptions.last?.description, "任意路径")
        XCTAssertEqual(viewModel.presetDefault, "read-only")
    }

    @MainActor
    func testSwitchFailureKeepsSelectionAndShowsMappedError() async {
        let viewModel = SessionViewModel(sessionId: "s-perm")
        viewModel.permissionSwitcher = { _ in
            throw LinkError.remote(RemoteError(code: "permission/preset-unavailable", message: "nope"))
        }

        await viewModel.switchPermissionPreset("danger-full-access")

        XCTAssertNil(viewModel.permissionsValue)
        XCTAssertEqual(viewModel.permissionSwitchError, L10n.t("该权限预设当前不可用"))
        XCTAssertFalse(viewModel.permissionSwitching)
    }

    @MainActor
    func testSwitchFailureForRevokedDeviceAsksForRepair() async {
        let viewModel = SessionViewModel(sessionId: "s-perm")
        viewModel.permissionSwitcher = { _ in
            throw LinkError.remote(
                RemoteError(code: "auth/revoked", message: L10n.t("设备已被撤销，请重新配对"))
            )
        }

        await viewModel.switchPermissionPreset("read-only")

        XCTAssertEqual(viewModel.permissionSwitchError, L10n.t("设备已被撤销，请重新配对"))
    }

    @MainActor
    func testSwitchClearsPreviousErrorOnNextAttempt() async {
        let viewModel = SessionViewModel(sessionId: "s-perm")
        var attempts = 0
        viewModel.permissionSwitcher = { preset in
            attempts += 1
            if attempts == 1 { throw LinkError.timeout("session/permission") }
            return SessionPermissionUpdate(sessionId: "s-perm", preset: preset)
        }

        await viewModel.switchPermissionPreset("read-only")
        XCTAssertNotNil(viewModel.permissionSwitchError)

        await viewModel.switchPermissionPreset("read-only")
        XCTAssertNil(viewModel.permissionSwitchError)
        XCTAssertEqual(viewModel.permissionsValue, "read-only")
    }

    @MainActor
    func testSwitchWithoutLinkReportsNotConnected() async {
        let viewModel = SessionViewModel(sessionId: "s-perm")
        await viewModel.switchPermissionPreset("read-only")
        XCTAssertEqual(viewModel.permissionSwitchError, L10n.t("连接未就绪"))
        XCTAssertNil(viewModel.permissionsValue)
    }

    @MainActor
    func testSelectionFallsBackToDefaultUntilSessionValueLands() async {
        let viewModel = SessionViewModel(sessionId: "s-perm")
        viewModel.permissionCatalogLoader = {
            PermissionPresetCatalog(
                options: [
                    PermissionPresetOption(value: "read-only", name: "只读"),
                    PermissionPresetOption(value: "workspace-write", name: "工作区可写"),
                ],
                defaultPreset: "read-only"
            )
        }
        await viewModel.loadPermissionCatalogIfNeeded()

        XCTAssertTrue(viewModel.isPermissionPresetSelected("read-only"))
        XCTAssertFalse(viewModel.isPermissionPresetSelected("workspace-write"))

        viewModel.permissionSwitcher = { preset in
            SessionPermissionUpdate(sessionId: "s-perm", preset: preset)
        }
        await viewModel.switchPermissionPreset("workspace-write")

        XCTAssertFalse(viewModel.isPermissionPresetSelected("read-only"))
        XCTAssertTrue(viewModel.isPermissionPresetSelected("workspace-write"))
    }
}
