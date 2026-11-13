import XCTest

final class CompressionFlowTests: XCTestCase {
    @MainActor
    func test30CleanHierarchyAndProgressiveDisclosure() throws {
        try requireFixtureSimulator()
        continueAfterFailure = false
        let app = launchChineseApp()
        for identifier in ["choose-video", "open-photos", "open-files", "open-pdf", "open-organization", "open-archives"] {
            XCTAssertTrue(reveal(app.buttons[identifier], in: app).isHittable, identifier)
        }
        XCTAssertFalse(app.buttons["open-direct-delete"].exists)
        capture("精简首页按用途分类")
        openOrganizationTool("browse-large-videos", in: app)
        XCTAssertEqual(app.buttons["catalog-filters"].value as? String, "大视频")
        app.buttons["catalog-filters"].tap()
        app.buttons["catalog-filter-all"].tap()
        XCTAssertEqual(app.buttons["catalog-filters"].value as? String, "全部")
        app.buttons["catalog-more"].tap()
        app.buttons["筛选与测量说明"].tap()
        XCTAssertTrue(app.navigationBars["视频信息说明"].waitForExistence(timeout: 8))
        app.buttons["完成"].tap()
        capture("选材仅显示当前筛选与排序")
        app.buttons["取消"].tap()
        XCTAssertTrue(app.buttons["open-space-plan"].exists)
        XCTAssertTrue(app.buttons["open-organizer"].exists)
        XCTAssertTrue(app.buttons["open-direct-delete"].exists)
        capture("整理与清理分类页")
        app.navigationBars.buttons["首页"].tap()
        for identifier in ["open-files", "open-pdf"] {
            reveal(app.buttons[identifier], in: app).tap()
            XCTAssertTrue(app.buttons["pick-files"].waitForExistence(timeout: 8))
            XCTAssertTrue(app.buttons["pick-folder"].exists)
            XCTAssertFalse(app.buttons["enqueue-files"].isEnabled)
            app.buttons["取消"].tap()
        }

        app.tabBars.buttons["设置"].tap()
        capture("设置按媒体类型分组")
        app.buttons["video-defaults"].tap()
        let preset = app.buttons["default-video-preset"].value as? String
        XCTAssertNotNil(preset)
        app.terminate()
        app.launch()
        app.tabBars.buttons["设置"].tap()
        app.buttons["video-defaults"].tap()
        XCTAssertEqual(app.buttons["default-video-preset"].value as? String, preset)
        XCTAssertTrue(app.buttons["video-encoding"].exists)
        app.buttons["parameter-help"].tap()
        capture("参数说明按需展开")
        app.navigationBars.buttons["设置"].tap()
        app.buttons["photo-defaults"].tap()
        XCTAssertTrue(app.buttons["default-photo-preset"].exists)
        app.navigationBars.buttons["设置"].tap()
        app.buttons["pdf-defaults"].tap()
        XCTAssertTrue(app.buttons["default-pdf-preset"].exists)

        app.tabBars.buttons["首页"].tap()
        reveal(app.buttons["open-photos"], in: app).tap()
        XCTAssertTrue(app.buttons["筛选照片"].waitForExistence(timeout: 8))
        XCTAssertFalse(app.switches["media-favorites"].exists)
        app.buttons["筛选照片"].tap()
        XCTAssertTrue(app.switches["media-favorites"].waitForExistence(timeout: 3), app.debugDescription)
        app.buttons["筛选照片"].tap()
        let candidates = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'photo-picker-' AND enabled == true"))
        XCTAssertGreaterThanOrEqual(candidates.count, 2, app.debugDescription)
        let first = candidates.element(boundBy: 0)
        let second = candidates.element(boundBy: 1)
        reveal(first, in: app).tap()
        reveal(second, in: app).tap()
        app.buttons["confirm-photos"].tap()
        XCTAssertTrue(app.buttons["intake-selected-items"].waitForExistence(timeout: 8))
        XCTAssertTrue(app.buttons["intake-selected-items"].label.contains("2"))
        XCTAssertTrue(app.buttons["start-intake"].isHittable)
        XCTAssertTrue(app.buttons["queue-intake"].isHittable)
        capture("确认页集中显示本批数量与参数")
        app.buttons["intake-selected-items"].tap()
        capture("展开核对所选素材")
        app.buttons["intake-selected-items"].tap()
        app.navigationBars.buttons["选择照片"].tap()
        XCTAssertEqual(first.value as? String, "已选择")
        XCTAssertEqual(second.value as? String, "已选择")
        app.buttons["confirm-photos"].tap()
        app.buttons["exit-intake"].tap()
        openTasks("视频", in: app)
        capture("任务列表保留名称与当前状态")
        if app.buttons["workspace-task-0"].exists {
            beginSelection(in: app)
            reveal(app.buttons["workspace-task-0"], in: app).tap()
            pick("batch-filter", option: "已结束", in: app)
            XCTAssertTrue(app.staticTexts["batch-selection-count"].label.contains("已选 1 项"))
            pick("workspace-category", option: "照片", in: app)
            XCTAssertFalse(app.staticTexts["batch-selection-count"].exists)
        }
    }

    @MainActor
    func test29RevokedPhotoAccessKeepsExistingTasks() throws {
        try requireFixtureSimulator()
        guard ProcessInfo.processInfo.environment["SIMULATOR_DEVICE_NAME"]?.contains("升级演练") == true else {
            throw XCTSkip("Requires the staged upgrade device with Photos access revoked")
        }
        continueAfterFailure = false
        let app = launchChineseApp()
        app.buttons["choose-video"].tap()
        XCTAssertTrue(app.staticTexts["session-message"].waitForExistence(timeout: 8), app.debugDescription)
        XCTAssertTrue(app.staticTexts["session-message"].label.contains("需要照片库访问权限"))
        XCTAssertFalse(app.navigationBars["选择视频"].exists)
        openTasks("视频", in: app)
        XCTAssertTrue(queueRow(0, status: "已保存", in: app).exists)
        app.tabBars.buttons["设置"].tap()
        app.buttons["photo-access-settings"].tap()
        XCTAssertTrue(reveal(app.staticTexts["当前无法访问照片库"], in: app).exists)
        capture("撤回照片访问后仍保留任务记录")
    }

    @MainActor
    func test27UpgradeKeepsExistingQueuesAndArchive() throws {
        try requireFixtureSimulator()
        guard ProcessInfo.processInfo.environment["SIMULATOR_DEVICE_NAME"]?.contains("升级演练") == true else {
            throw XCTSkip("Requires the staged v0.8.1 installation")
        }
        continueAfterFailure = false
        let app = launchChineseApp()
        openTasks("文件", in: app)
        let original = taskRow(named: "FilePhoto", status: "原件已恢复", in: app)
        XCTAssertTrue(original.waitForExistence(timeout: 10), app.debugDescription)
        reveal(original, in: app).tap()
        XCTAssertTrue(app.staticTexts["file-job-status"].label.contains("原件已恢复"))
        app.navigationBars.buttons["任务"].tap()
        XCTAssertEqual(app.buttons["workspace-category"].value as? String, "文件")
        XCTAssertTrue(original.exists)
        capture("升级后原任务仍可按类别回到原位置")
        app.tabBars.buttons["首页"].tap()
        reveal(app.buttons["open-archives"], in: app).tap()
        XCTAssertTrue(reveal(app.buttons["archive-record-0"], in: app).exists)
        app.navigationBars.buttons["首页"].tap()
        openOrganizationTool("open-space-plan", in: app)
        XCTAssertEqual(app.textFields["space-goal-mb"].value as? String, "1")
        showSpaceScanOptions(in: app)
        reveal(app.buttons["space-exclusions"], in: app).tap()
        XCTAssertTrue(app.staticTexts["旧版忽略样例"].exists)
        capture("升级后保留清单目标和忽略项")
    }

    @MainActor
    func test28LargeTextConfirmationAndAccessibility() throws {
        try requireFixtureSimulator()
        continueAfterFailure = false
        let app = launchChineseApp()
        reveal(app.buttons["open-photos"], in: app).tap()
        let photo = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'photo-picker-' AND enabled == true")).firstMatch
        XCTAssertTrue(app.navigationBars["选择照片"].waitForExistence(timeout: 12), app.debugDescription)
        reveal(photo, in: app).tap()
        XCTAssertEqual(photo.value as? String, "已选择")
        app.buttons["confirm-photos"].tap()
        let start = app.buttons["start-intake"]
        let queue = app.buttons["queue-intake"]
        XCTAssertTrue(start.waitForExistence(timeout: 8))
        XCTAssertTrue(start.isHittable && queue.isHittable, app.debugDescription)
        XCTAssertFalse(start.frame.intersects(queue.frame))
        let parameterLabel = app.staticTexts["parameter-label-照片尺寸"]
        let parameterValue = app.buttons["default-photo-preset"]
        let parameterHelp = app.buttons["parameter-help"]
        reveal(parameterValue, in: app)
        XCTAssertFalse(parameterLabel.frame.intersects(parameterValue.frame), app.debugDescription)
        XCTAssertFalse(parameterValue.frame.intersects(parameterHelp.frame), app.debugDescription)
        try app.performAccessibilityAudit(for: [.sufficientElementDescription, .trait])
        capture("最大辅助字号下可操作的确认页")
        app.buttons["exit-intake"].tap()
        XCTAssertTrue(app.navigationBars["首页"].waitForExistence(timeout: 8))
    }

    @MainActor
    func test26DraftDefaultsAndBatchScope() throws {
        try requireFixtureSimulator()
        continueAfterFailure = false
        let app = launchChineseApp()
        app.tabBars.buttons["设置"].tap()
        app.buttons["video-defaults"].tap()
        pick("default-video-preset", option: "保画质", in: app)
        app.terminate(); app.launch()
        app.tabBars.buttons["设置"].tap()
        app.buttons["video-defaults"].tap()
        XCTAssertEqual(app.buttons["default-video-preset"].value as? String, "保画质")
        app.tabBars.buttons["首页"].tap()
        app.buttons["choose-video"].tap()
        reveal(pickerRow("640 × 360", in: app), in: app).tap()
        app.buttons["confirm-selection"].tap()
        XCTAssertEqual(app.buttons["default-video-preset"].value as? String, "保画质")
        pick("default-video-preset", option: "省空间", in: app)
        app.navigationBars.buttons["选择视频"].tap()
        XCTAssertEqual(pickerRow("640 × 360", in: app).value as? String, "已选择")
        app.buttons["confirm-selection"].tap()
        XCTAssertEqual(app.buttons["default-video-preset"].value as? String, "省空间")
        capture("返回选材保留本批参数")
        app.buttons["exit-intake"].tap()
        openTasks("全部", in: app)
        XCTAssertTrue(app.staticTexts["还没有任务"].exists, app.debugDescription)

        app.tabBars.buttons["首页"].tap()
        app.buttons["choose-video"].tap()
        reveal(pickerRow("640 × 360", in: app), in: app).tap()
        app.buttons["confirm-selection"].tap()
        XCTAssertEqual(app.buttons["default-video-preset"].value as? String, "保画质")
        submitIntake(start: false, in: app)
        XCTAssertTrue(queueRow(0, status: "待压缩", in: app).exists)
        app.tabBars.buttons["首页"].tap()
        app.buttons["choose-video"].tap()
        reveal(pickerRow("1920 × 1080", in: app), in: app).tap()
        app.buttons["confirm-selection"].tap()
        pick("default-video-preset", option: "省空间", in: app)
        submitIntake(start: true, in: app)
        XCTAssertTrue(queueRow(0, status: "待预览和保存", in: app).waitForExistence(timeout: 60), app.debugDescription)
        app.buttons["workspace-batch-scope"].tap()
        XCTAssertTrue(queueRow(0, status: "待压缩", in: app).exists)
        XCTAssertTrue(queueRow(1, status: "待预览和保存", in: app).exists)
        beginSelection(in: app)
        reveal(app.buttons["workspace-task-1"], in: app).tap()
        pick("batch-filter", option: "待开始", in: app)
        XCTAssertTrue(app.staticTexts["batch-selection-count"].label.contains("隐藏 1 项"))
        reveal(app.buttons["batch-select-all"], in: app).tap()
        XCTAssertTrue(app.staticTexts["batch-selection-count"].label.contains("已选 2 项"))
        batchAction(.save, in: app)
        XCTAssertTrue(app.staticTexts["batch-review-count"].label.contains("可处理 1 项"))
        XCTAssertTrue(app.staticTexts["batch-review-count"].label.contains("不适用 1 项"))
        capture("筛选隐藏项仍在实际执行范围中复核")
        app.buttons["返回"].tap()
        pick("workspace-category", option: "照片", in: app)
        XCTAssertFalse(app.staticTexts["batch-selection-count"].exists)
    }

    @MainActor
    func test22SpacePlanGoalDeduplicationAndSeparateReview() throws {
        try requireFixtureSimulator(); continueAfterFailure = false
        let app = launchChineseApp()
        openOrganizationTool("open-space-plan", in: app)
        let goal = app.textFields["space-goal-mb"]
        XCTAssertTrue(goal.waitForExistence(timeout: 10))
        showSpaceScanOptions(in: app)
        reveal(app.buttons["space-exclusions"], in: app).tap()
        let previousIgnored = app.buttons.matching(identifier: "include-space-item").count
        app.buttons["完成"].tap()
        goal.tap()
        goal.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: 7) + "1")
        app.buttons["save-space-goal"].tap()
        XCTAssertEqual(goal.value as? String, "1")
        reveal(app.buttons["scan-space-plan"], in: app).tap()
        let done = app.staticTexts.matching(NSPredicate(format: "identifier == 'space-message' AND label CONTAINS '已检查'")).firstMatch
        XCTAssertTrue(done.waitForExistence(timeout: 35), app.debugDescription)
        reveal(app.buttons["space-action-filter"], in: app).tap()
        app.buttons["重复整理"].tap()
        let group = app.staticTexts["完全重复 · 2 项"]
        reveal(group, in: app)
        XCTAssertTrue(group.exists, app.debugDescription)
        capture("空间目标与重复素材收益只计一次")
        reveal(app.buttons["space-review-0"], in: app).tap()
        XCTAssertTrue(app.buttons["keep-member-0"].waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertFalse(app.buttons["remove-media-selection"].isEnabled)
        app.buttons["keep-member-0"].tap()
        reveal(app.buttons["remove-member-1"], in: app).tap()
        XCTAssertEqual(app.buttons["remove-member-1"].value as? String, "已勾选")
        XCTAssertTrue(app.buttons["remove-media-selection"].isEnabled)
        capture("空间清单进入独立原片复核")
        app.buttons["返回清单"].tap()
        reveal(app.buttons["space-ignore-0"], in: app).tap()
        XCTAssertFalse(group.exists)
        app.terminate(); app.launch()
        openOrganizationTool("open-space-plan", in: app)
        XCTAssertEqual(app.textFields["space-goal-mb"].value as? String, "1")
        showSpaceScanOptions(in: app)
        reveal(app.buttons["space-exclusions"], in: app).tap()
        let ignored = app.buttons.matching(identifier: "include-space-item")
        XCTAssertEqual(ignored.count, previousIgnored + 2)
        ignored.element(boundBy: previousIgnored + 1).tap()
        ignored.element(boundBy: previousIgnored).tap()
        XCTAssertEqual(ignored.count, previousIgnored)
        app.buttons["完成"].tap()
        reveal(app.buttons["scan-space-plan"], in: app).tap()
        XCTAssertTrue(done.waitForExistence(timeout: 35), app.debugDescription)
        XCTAssertTrue(reveal(group, in: app).exists)
        capture("恢复忽略项后清单重新计算")
    }

    @MainActor
    func test23SpacePlanArchiveReviewKeepsOriginalAndSelectsOnlyProposal() throws {
        try requireFixtureSimulator(); continueAfterFailure = false
        let app = launchChineseApp()
        openOrganizationTool("open-space-plan", in: app)
        reveal(app.buttons["scan-space-plan"], in: app).tap()
        let done = app.staticTexts.matching(NSPredicate(format: "identifier == 'space-message' AND label CONTAINS '已检查'")).firstMatch
        XCTAssertTrue(done.waitForExistence(timeout: 35), app.debugDescription)
        reveal(app.buttons["space-action-filter"], in: app).tap()
        app.buttons["归档"].tap()
        reveal(app.buttons["space-review-0"], in: app).tap()
        let destination = app.buttons["archive-choose-destination"]
        XCTAssertTrue(reveal(destination, in: app).isEnabled)
        XCTAssertTrue(destination.label.contains("1 项"))
        XCTAssertFalse(app.buttons["archive-remove"].exists)
        capture("清单仅将该素材带入归档确认")
    }

    @MainActor
    func test24ProfessionalPaywallKeepsFreeVideoEntry() throws {
        try requireFixtureSimulator(); continueAfterFailure = false
        let app = launchChineseApp()
        app.tabBars.buttons["设置"].tap()
        reveal(app.buttons["professional-video-options"], in: app).tap()
        let locked = app.staticTexts.matching(NSPredicate(format: "identifier == 'professional-entitlement' AND label CONTAINS '一次性买断'")).firstMatch
        XCTAssertTrue(locked.waitForExistence(timeout: 12), app.debugDescription)
        XCTAssertTrue(app.buttons["restore-professional-purchase"].exists)
        XCTAssertFalse(app.buttons["apply-professional-video"].exists)
        XCTAssertFalse(app.segmentedControls["professional-rate-mode"].exists)
        capture("专业视频买断入口与恢复购买")
        app.buttons["完成"].tap()
        app.tabBars.buttons["首页"].tap()
        app.buttons["choose-video"].tap()
        XCTAssertTrue(app.navigationBars["选择视频"].waitForExistence(timeout: 12), app.debugDescription)
    }

    @MainActor
    func test25LocalPurchaseUnlocksEditorAndRestoresPreset() throws {
        try requireFixtureSimulator(); continueAfterFailure = false
        let app = launchChineseApp()
        defer { app.terminate() }
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let localSuccess = springboard.alerts.containing(NSPredicate(format: "label CONTAINS 'Environment: Xcode'")).firstMatch
        if localSuccess.exists, localSuccess.buttons["OK"].exists { localSuccess.buttons["OK"].tap() }
        app.tabBars.buttons["设置"].tap()
        reveal(app.buttons["professional-video-options"], in: app).tap()
        let buy = app.buttons["purchase-professional-video"]
        let unlocked = app.staticTexts.matching(NSPredicate(format: "identifier == 'professional-entitlement' AND label CONTAINS '已解锁'")).firstMatch
        if !unlocked.waitForExistence(timeout: 3) {
            guard buy.waitForExistence(timeout: 15) else { throw XCTSkip("Local StoreKit product is unavailable") }
            buy.tap()
            let services = [app, springboard, XCUIApplication(bundleIdentifier: "com.apple.StoreKitUIService")]
            var localSheet: XCUIApplication?
            let deadline = Date().addingTimeInterval(10)
            while localSheet == nil, Date() < deadline {
                localSheet = services.first { $0.staticTexts.matching(NSPredicate(format: "label CONTAINS[c] 'Xcode'")).firstMatch.exists }
                if localSheet == nil { Thread.sleep(forTimeInterval: 0.25) }
            }
            capture("本地买断确认环境")
            guard let localSheet else { throw XCTSkip("Purchase confirmation is not identified as the Xcode test environment") }
            let confirm = localSheet.buttons.matching(NSPredicate(format: "label IN {'Buy', 'Purchase', '购买', '确认购买'}")).firstMatch
            XCTAssertTrue(confirm.exists, localSheet.debugDescription)
            confirm.tap()
            XCTAssertTrue(localSuccess.waitForExistence(timeout: 15), springboard.debugDescription)
            localSuccess.buttons["OK"].tap()
        }
        XCTAssertTrue(unlocked.waitForExistence(timeout: 15), app.debugDescription)
        reveal(app.segmentedControls["professional-rate-mode"], in: app).buttons["目标大小"].tap()
        let size = app.textFields["professional-target-size"]
        reveal(size, in: app).coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.5)).tap()
        size.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: 5) + "5")
        XCTAssertEqual(size.value as? String, "5")
        reveal(app.buttons["save-professional-preset"], in: app).tap()
        let presetName = "UI验收 " + UUID().uuidString.prefix(5)
        app.alerts.textFields.firstMatch.typeText(presetName)
        app.alerts.buttons["保存"].tap()
        let preset = app.buttons.containing(.staticText, identifier: presetName).firstMatch
        XCTAssertTrue(preset.exists)
        capture("本地买断解锁专业参数与预设")
        app.terminate(); app.launch()
        app.tabBars.buttons["设置"].tap()
        reveal(app.buttons["professional-video-options"], in: app).tap()
        XCTAssertTrue(unlocked.waitForExistence(timeout: 12), app.debugDescription)
        XCTAssertTrue(preset.exists)
        reveal(app.buttons["restore-professional-purchase"], in: app).tap()
        let restored = app.staticTexts["已恢复专业视频买断。"]
        if !restored.waitForExistence(timeout: 2) {
            XCTAssertTrue(localSuccess.waitForExistence(timeout: 10), springboard.debugDescription)
            localSuccess.buttons["OK"].tap()
        }
        XCTAssertTrue(restored.waitForExistence(timeout: 15), app.debugDescription)
        reveal(preset, in: app).tap()
        XCTAssertEqual(reveal(size, in: app).value as? String, "5")
        capture("重开后恢复本地买断与预设")
    }

    @MainActor
    func test18ArchiveFilesReconnectAndExportWithoutRemovingLocalOriginals() throws {
        try requireFixtureSimulator(); continueAfterFailure = false
        let app = launchChineseApp()
        reveal(app.buttons["open-archives"], in: app).tap()
        app.buttons["archive-pick-folder"].tap()
        chooseSystemFolder("文件测试素材", in: app)
        reveal(app.buttons["archive-select-sources"], in: app).tap()
        reveal(app.buttons["archive-choose-destination"], in: app).tap()
        chooseSystemFolder("归档验证", in: app)
        XCTAssertTrue(app.alerts.buttons["开始归档"].waitForExistence(timeout: 10), app.debugDescription)
        app.alerts.buttons["开始归档"].tap()
        waitForArchiveRecord(in: app).tap()
        XCTAssertTrue(app.staticTexts["archive-status"].label.contains("本机归档"), app.debugDescription)
        reveal(app.buttons["archive-select-entries"], in: app).tap()
        XCTAssertFalse(app.buttons["archive-remove"].isEnabled)
        capture("本机归档回读核验原件保持")
        reveal(app.buttons["archive-export"], in: app).tap()
        exportSystemFiles(to: "归档恢复验证", in: app)
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "identifier == 'archive-detail-message' AND label CONTAINS '原始文件已导出'")).firstMatch.waitForExistence(timeout: 15), app.debugDescription)
        app.terminate(); app.launch()
        reveal(app.buttons["open-archives"], in: app).tap()
        waitForArchiveRecord(in: app).tap()
        XCTAssertTrue(app.staticTexts["archive-status"].label.contains("待重新核验"))
        app.navigationBars.buttons["原片归档"].tap()
        reveal(app.buttons["archive-connect"], in: app).tap()
        navigateSystemFolder("归档验证", in: app)
        let archive = app.cells.matching(NSPredicate(format: "label CONTAINS 'DisquEZ-归档-'")).firstMatch
        XCTAssertTrue(archive.waitForExistence(timeout: 10), app.debugDescription); archive.tap()
        systemOpenFolder(in: app)
        waitForArchiveRecord(in: app).tap()
        XCTAssertTrue(app.staticTexts["archive-status"].label.contains("本机归档"), app.debugDescription)
        capture("重新连接完整归档后核验")
    }

    @MainActor
    func test19PhotoArchiveRestoreAndRelaunchDoNotCreateAgain() throws {
        try requireFixtureSimulator(); continueAfterFailure = false
        let app = launchChineseApp()
        reveal(app.buttons["open-archives"], in: app).tap(); app.buttons["archive-pick-photos"].tap()
        let photo = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'archive-photo-' AND label CONTAINS 'ArchivePhoto'")).firstMatch
        reveal(photo, in: app).tap()
        app.buttons["archive-confirm-photos"].tap()
        reveal(app.buttons["archive-select-sources"], in: app).tap()
        reveal(app.buttons["archive-choose-destination"], in: app).tap()
        chooseSystemFolder("归档验证", in: app)
        XCTAssertTrue(app.alerts.buttons["开始归档"].waitForExistence(timeout: 10), app.debugDescription)
        app.alerts.buttons["开始归档"].tap()
        waitForArchiveRecord(in: app).tap()
        reveal(app.buttons["archive-restore-0"], in: app).tap()
        app.alerts.buttons["取消"].tap()
        app.buttons["archive-restore-0"].tap(); app.alerts.buttons["恢复原片"].tap()
        let restored = app.staticTexts.matching(NSPredicate(format: "identifier == 'archive-restored-0' AND label CONTAINS '已恢复并核验'")).firstMatch
        XCTAssertTrue(restored.waitForExistence(timeout: 30), app.debugDescription)
        capture("归档原片恢复后回读核验")
        app.terminate(); app.launch(); reveal(app.buttons["open-archives"], in: app).tap()
        reveal(app.buttons["archive-record-0"], in: app).tap()
        XCTAssertTrue(restored.waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertFalse(app.buttons["archive-restore-0"].exists)
        capture("重开后保留恢复结果不重复保存")
    }

    @MainActor
    func test20PDFOptimizeZoomCompareReplaceAndRestore() throws {
        try requireFixtureSimulator(); continueAfterFailure = false
        let app = launchChineseApp()
        reveal(app.buttons["open-pdf"], in: app).tap(); app.buttons["pick-files"].tap()
        navigateSystemFolder("PDF测试素材", in: app)
        let pdf = app.cells.matching(NSPredicate(format: "label BEGINSWITH 'Scan.pdf' OR label BEGINSWITH 'Scan,'")).firstMatch
        XCTAssertTrue(pdf.waitForExistence(timeout: 10), app.debugDescription); pdf.tap()
        if app.buttons["打开"].exists { app.buttons["打开"].tap() }
        XCTAssertTrue(app.buttons["select-visible-files"].waitForExistence(timeout: 12))
        app.buttons["select-visible-files"].tap()
        reveal(app.buttons["enqueue-files"], in: app).tap()
        submitIntake(start: true, in: app)
        let ready = app.buttons.matching(NSPredicate(format: "identifier == 'workspace-task-0' AND label CONTAINS '成品待复核'")).firstMatch
        XCTAssertTrue(ready.waitForExistence(timeout: 40), app.debugDescription); ready.tap()
        XCTAssertTrue(app.buttons["compare-file-pdf"].waitForExistence(timeout: 8)); app.buttons["compare-file-pdf"].tap()
        app.buttons["pdf-next-page"].tap()
        XCTAssertTrue(app.staticTexts["pdf-page-number"].label.contains("2 / 2"))
        app.segmentedControls["pdf-comparison-version"].buttons["原文件"].tap()
        XCTAssertTrue(app.staticTexts["pdf-page-number"].label.contains("2 / 2"))
        app.descendants(matching: .any).matching(identifier: "pdf-reader").firstMatch.pinch(withScale: 1.6, velocity: 1)
        capture("PDF逐页放大对比保留当前页")
        app.buttons["完成"].tap()
        reveal(app.buttons["replace-file-original"], in: app).tap(); app.alerts.buttons["取消"].tap()
        app.buttons["replace-file-original"].tap(); app.alerts.buttons["确认替换"].tap()
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "identifier == 'file-job-status' AND label CONTAINS '已替换'")).firstMatch.waitForExistence(timeout: 20), app.debugDescription)
        app.buttons["restore-file-original"].tap(); app.alerts.buttons["恢复原文件"].tap()
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "identifier == 'file-job-status' AND label CONTAINS '原件已恢复'")).firstMatch.waitForExistence(timeout: 20), app.debugDescription)
        capture("PDF替换后原件完整恢复")
    }

    @MainActor
    func test21PDFBatchProtectsEncryptedSignedAndInteractiveFiles() throws {
        try requireFixtureSimulator(); continueAfterFailure = false
        let app = launchChineseApp()
        reveal(app.buttons["open-pdf"], in: app).tap(); app.buttons["pick-folder"].tap()
        chooseSystemFolder("PDF测试素材", in: app)
        XCTAssertTrue(app.buttons["select-visible-files"].waitForExistence(timeout: 12)); app.buttons["select-visible-files"].tap()
        reveal(app.buttons["enqueue-files"], in: app).tap()
        submitIntake(start: true, in: app)
        for name in ["Encrypted", "Form", "SignatureStructure"] {
            XCTAssertTrue(taskRow(named: name, status: "已跳过", in: app).waitForExistence(timeout: 90), app.debugDescription)
        }
        capture("PDF混合队列保护表单加密与签名")
        beginSelection(in: app)
        reveal(app.buttons["batch-select-all"], in: app).tap()
        batchAction(.export, in: app)
        confirmBatch(in: app)
        exportSystemFiles(to: "PDF导出验证", in: app)
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "identifier == 'workspace-task-message' AND label CONTAINS '系统已完成副本导出'")).firstMatch.waitForExistence(timeout: 20), app.debugDescription)
    }

    @MainActor private func launchChineseApp() -> XCUIApplication {
        let app = XCUIApplication(); app.launchArguments = ["-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN"]; app.launch()
        XCTAssertTrue(app.buttons["choose-video"].waitForExistence(timeout: 12)); return app
    }

    @MainActor private func pick(_ identifier: String, option: String, in app: XCUIApplication) {
        reveal(app.buttons[identifier], in: app).tap()
        let choice = app.buttons[option].firstMatch
        XCTAssertTrue(choice.waitForExistence(timeout: 8), app.debugDescription)
        choice.tap()
    }

    @MainActor private func openTasks(_ category: String, in app: XCUIApplication) {
        app.tabBars.buttons["任务"].tap()
        let picker = app.buttons["workspace-category"]
        XCTAssertTrue(picker.waitForExistence(timeout: 10), app.debugDescription)
        if picker.value as? String != category { pick("workspace-category", option: category, in: app) }
    }

    @MainActor private func openOrganizationTool(_ identifier: String, in app: XCUIApplication) {
        if !app.buttons[identifier].exists {
            reveal(app.buttons["open-organization"], in: app).tap()
        }
        reveal(app.buttons[identifier], in: app).tap()
    }

    @MainActor private func showSpaceScanOptions(in app: XCUIApplication) {
        if !app.buttons["space-exclusions"].exists {
            reveal(app.buttons["扫描范围与排除项"], in: app).tap()
        }
    }

    @MainActor private func beginSelection(in app: XCUIApplication, active: Bool = true) {
        let select = app.buttons["select-workspace-tasks"]
        XCTAssertTrue(select.waitForExistence(timeout: 10), app.debugDescription)
        if select.label != (active ? "完成" : "多选") { select.tap() }
    }

    @MainActor private func confirmBatch(in app: XCUIApplication) {
        let button = app.buttons["confirm-batch-action"]
        XCTAssertTrue(button.waitForExistence(timeout: 8))
        button.tap()
        let final = app.alerts.buttons.matching(NSPredicate(format: "label BEGINSWITH '确认 '")).firstMatch
        if final.waitForExistence(timeout: 2) { final.tap() }
    }

    @MainActor private func submitIntake(start: Bool, in app: XCUIApplication) {
        let action = app.buttons[start ? "start-intake" : "queue-intake"]
        XCTAssertTrue(action.waitForExistence(timeout: 10), app.debugDescription)
        action.tap()
        XCTAssertTrue(app.navigationBars["任务"].waitForExistence(timeout: 15), app.debugDescription)
    }

    @MainActor private func openReadyVideo(in app: XCUIApplication) {
        let ready = queueRow(0, status: "待预览和保存", in: app)
        XCTAssertTrue(ready.waitForExistence(timeout: 90), app.debugDescription)
        reveal(ready, in: app).tap()
    }

    @MainActor private func taskRow(named name: String, status: String, in app: XCUIApplication) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'workspace-task-' AND label CONTAINS %@ AND label CONTAINS %@", name, status)).firstMatch
    }
    @MainActor private func waitForArchiveRecord(in app: XCUIApplication) -> XCUIElement {
        let finished = app.buttons.matching(NSPredicate(format: "identifier == 'archive-record-0' AND enabled == true")).firstMatch
        if !finished.waitForExistence(timeout: 5) {
            app.swipeUp()
            XCTAssertTrue(finished.waitForExistence(timeout: 25), app.debugDescription)
        }
        return reveal(finished, in: app)
    }
    @MainActor private func navigateSystemFolder(_ name: String, in app: XCUIApplication) {
        XCTAssertTrue(app.buttons["浏览"].firstMatch.waitForExistence(timeout: 12), app.debugDescription)
        app.buttons["浏览"].firstMatch.tap()
        for _ in 0..<8 {
            let target = app.cells.matching(NSPredicate(format: "label BEGINSWITH %@", name + ",")).firstMatch
            if target.exists && target.isHittable { target.tap(); return }
            let local = app.cells.matching(NSPredicate(format: "label CONTAINS 'iPhone'")).firstMatch
            if local.exists && local.isHittable { local.tap(); continue }
            let own = app.cells.matching(NSPredicate(format: "label BEGINSWITH 'DisquEZ,'")).firstMatch
            if own.exists && own.isHittable { own.tap(); continue }
            if let back = app.navigationBars.buttons.matching(identifier: "BackButton").allElementsBoundByIndex.last(where: \.isHittable) { back.tap(); continue }
            app.buttons["浏览"].firstMatch.tap()
        }
        XCTFail("System folder not found: \(name)\n\(app.debugDescription)")
    }
    @MainActor private func systemOpenFolder(in app: XCUIApplication) {
        let open = app.buttons.matching(NSPredicate(format: "label IN {'打开', '选取', 'Open'}")).firstMatch
        XCTAssertTrue(open.waitForExistence(timeout: 10), app.debugDescription); open.tap()
    }
    @MainActor private func chooseSystemFolder(_ name: String, in app: XCUIApplication) { navigateSystemFolder(name, in: app); systemOpenFolder(in: app) }
    @MainActor private func exportSystemFiles(to folder: String, in app: XCUIApplication) {
        let destination = app.cells.matching(NSPredicate(format: "label BEGINSWITH %@", folder + ",")).firstMatch
        if destination.waitForExistence(timeout: 6) { destination.tap() }
        else { navigateSystemFolder(folder, in: app) }
        let save = app.buttons.matching(NSPredicate(format: "label IN {'保存', '存储', '导出', 'Save', 'Export'}")).firstMatch
        XCTAssertTrue(save.waitForExistence(timeout: 10), app.debugDescription); save.tap()
    }
    @MainActor
    func test16FilePickerCompressCompareReplaceAndRestore() throws {
        try requireFixtureSimulator()
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN"]
        app.launch()
        XCTAssertTrue(app.buttons["open-files"].waitForExistence(timeout: 12))
        reveal(app.buttons["open-files"], in: app).tap()
        XCTAssertTrue(app.buttons["pick-files"].waitForExistence(timeout: 8))
        app.buttons["pick-files"].tap()
        capture("系统文件选择器")
        let browse = app.buttons["浏览"]
        XCTAssertTrue(browse.waitForExistence(timeout: 10), app.debugDescription)
        browse.tap()
        let local = app.cells.matching(NSPredicate(format: "label CONTAINS 'iPhone'")).firstMatch
        if local.waitForExistence(timeout: 6) { local.tap() }
        let appFolder = app.cells.matching(NSPredicate(format: "label CONTAINS 'DisquEZ'")).firstMatch
        if appFolder.waitForExistence(timeout: 6) { appFolder.tap() }
        let folder = app.cells.matching(NSPredicate(format: "label CONTAINS '文件测试素材'")).firstMatch
        XCTAssertTrue(folder.waitForExistence(timeout: 8), app.debugDescription)
        folder.tap()
        let photo = app.cells.matching(NSPredicate(format: "label CONTAINS 'FilePhoto'")).firstMatch
        XCTAssertTrue(photo.waitForExistence(timeout: 8), app.debugDescription)
        photo.tap()
        if app.buttons["打开"].exists { app.buttons["打开"].tap() }
        let select = app.buttons["select-visible-files"]
        XCTAssertTrue(select.waitForExistence(timeout: 15), app.debugDescription)
        select.tap()
        app.buttons["enqueue-files"].tap()
        submitIntake(start: true, in: app)
        let row = app.buttons.matching(NSPredicate(format: "identifier == 'workspace-task-0' AND label CONTAINS '成品待复核'")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 30), app.debugDescription)
        row.tap()
        XCTAssertTrue(app.buttons["compare-file-photo"].waitForExistence(timeout: 8))
        app.buttons["compare-file-photo"].tap()
        app.scrollViews["photo-zoom"].pinch(withScale: 2, velocity: 1)
        capture("文件图片放大对比")
        app.buttons["完成"].tap()
        app.swipeUp()
        let replace = app.buttons["replace-file-original"]
        XCTAssertTrue(replace.waitForExistence(timeout: 8), app.debugDescription)
        replace.tap()
        app.alerts.buttons["取消"].tap()
        replace.tap()
        app.alerts.buttons["确认替换"].tap()
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "identifier == 'file-job-status' AND label CONTAINS '已替换'")).firstMatch.waitForExistence(timeout: 20), app.debugDescription)
        capture("文件替换后保留恢复副本")
        app.buttons["restore-file-original"].tap()
        app.alerts.buttons["恢复原文件"].tap()
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "identifier == 'file-job-status' AND label CONTAINS '原件已恢复'")).firstMatch.waitForExistence(timeout: 20), app.debugDescription)
        capture("文件原件恢复并核验")
    }

    @MainActor
    func test17FolderBatchCompressionAndSystemCopyExport() throws {
        try requireFixtureSimulator()
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN"]
        app.launch()
        XCTAssertTrue(app.buttons["open-files"].waitForExistence(timeout: 12))
        reveal(app.buttons["open-files"], in: app).tap()
        app.buttons["pick-folder"].tap()
        let browse = app.buttons["浏览"].firstMatch
        XCTAssertTrue(browse.waitForExistence(timeout: 10), app.debugDescription)
        browse.tap()
        let local = app.cells.matching(NSPredicate(format: "label CONTAINS 'iPhone'")).firstMatch
        if local.exists { local.tap() }
        let appFolder = app.cells.matching(NSPredicate(format: "label CONTAINS 'DisquEZ'")).firstMatch
        if appFolder.exists { appFolder.tap() }
        let folder = app.cells.matching(NSPredicate(format: "label CONTAINS '文件测试素材'")).firstMatch
        if folder.exists { folder.tap() }
        capture("系统目录选择")
        let open = app.buttons.matching(NSPredicate(format: "label == '打开' OR label == '选取' OR label == 'Open'")).firstMatch
        XCTAssertTrue(open.waitForExistence(timeout: 8), app.debugDescription)
        open.tap()
        XCTAssertTrue(app.buttons["file-candidate-2"].waitForExistence(timeout: 15), app.debugDescription)
        app.buttons["select-visible-files"].tap()
        reveal(app.buttons["enqueue-files"], in: app).tap()
        XCTAssertTrue(app.buttons["intake-selected-items"].label.contains("2"), app.debugDescription)
        submitIntake(start: true, in: app)
        XCTAssertTrue(taskRow(named: "FileVideo", status: "成品待复核", in: app).waitForExistence(timeout: 65), app.debugDescription)
        XCTAssertTrue(taskRow(named: "FilePhoto", status: "成品待复核", in: app).waitForExistence(timeout: 30), app.debugDescription)
        capture("目录中的媒体完成其他文件保护")
        beginSelection(in: app)
        reveal(app.buttons["batch-select-all"], in: app).tap()
        batchAction(.export, in: app)
        confirmBatch(in: app)
        let destination = app.cells.matching(NSPredicate(format: "label CONTAINS '文件导出验证'")).firstMatch
        XCTAssertTrue(destination.waitForExistence(timeout: 15), app.debugDescription)
        destination.tap()
        capture("系统选择导出位置")
        let save = app.buttons.matching(NSPredicate(format: "label IN {'导出', '存储', '保存', '移动', 'Export', 'Save', 'Move'}")).firstMatch
        XCTAssertTrue(save.waitForExistence(timeout: 10), app.debugDescription)
        save.tap()
        let finished = app.staticTexts.matching(NSPredicate(format: "identifier == 'workspace-task-message' AND label CONTAINS '系统已完成副本导出'")).firstMatch
        XCTAssertTrue(finished.waitForExistence(timeout: 20), app.debugDescription)
        capture("批量导出后原件保留")
    }

    @MainActor
    private func reveal(_ element: XCUIElement, in app: XCUIApplication) -> XCUIElement {
        for _ in 0..<6 {
            if element.exists {
                let y = element.frame.midY
                if y >= 110 && y < app.frame.maxY - 65 && element.isHittable { return element }
                if y < 110 { app.swipeDown(); continue }
            }
            app.swipeUp()
        }
        XCTAssertTrue(element.isHittable, app.debugDescription)
        return element
    }
    @MainActor
    func test11BatchCancelRetrySaveAndDiscardOnlySelectedVideoTasks() throws {
        try requireFixtureSimulator()
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN"]
        app.launch()
        XCTAssertTrue(app.buttons["choose-video"].waitForExistence(timeout: 12))
        app.buttons["choose-video"].tap()
        for size in ["640 × 360", "2560 × 1440", "1920 × 1080"] {
            let row = pickerRow(size, in: app)
            XCTAssertTrue(row.waitForExistence(timeout: 8), app.debugDescription)
            row.tap()
        }
        app.buttons["confirm-selection"].tap()
        submitIntake(start: false, in: app)
        beginSelection(in: app)
        reveal(app.buttons["batch-select-all"], in: app).tap()
        batchAction(.cancel, in: app)
        XCTAssertTrue(app.staticTexts["batch-review-count"].label.contains("可处理 3 项"))
        confirmBatch(in: app)
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "identifier == 'workspace-task-2' AND label CONTAINS '已取消任务'")).firstMatch.waitForExistence(timeout: 8))
        capture("三条视频任务已取消原片保留")
        app.terminate(); app.launch()
        openTasks("视频", in: app)
        beginSelection(in: app)
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "identifier == 'workspace-task-0' AND label CONTAINS '已取消任务'")).firstMatch.waitForExistence(timeout: 8))
        app.buttons["workspace-task-0"].tap()
        batchAction(.retry, in: app)
        confirmBatch(in: app)
        let ready = app.buttons.matching(NSPredicate(format: "identifier == 'workspace-task-0' AND label CONTAINS '待预览和保存'")).firstMatch
        XCTAssertTrue(ready.waitForExistence(timeout: 50), app.debugDescription)
        app.buttons["batch-select-all"].tap()
        batchAction(.save, in: app)
        XCTAssertTrue(app.staticTexts["batch-review-count"].label.contains("可处理 1 项"))
        XCTAssertTrue(app.staticTexts["batch-review-count"].label.contains("不适用 2 项"))
        capture("混合状态只保存一项")
        confirmBatch(in: app)
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "identifier == 'workspace-task-0' AND label CONTAINS '已保存并核验'")).firstMatch.waitForExistence(timeout: 30), app.debugDescription)
        app.buttons["清空选择"].tap()
        app.buttons["workspace-task-1"].tap()
        batchAction(.discard, in: app)
        confirmBatch(in: app)
        XCTAssertFalse(app.buttons["workspace-task-2"].exists)
        capture("只移除所选任务记录")
    }

    @MainActor
    func test12DirectDeleteUncompressedVideoKeepsOtherOriginals() throws {
        try requireFixtureSimulator()
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN"]
        app.launch()
        XCTAssertTrue(app.buttons["choose-video"].waitForExistence(timeout: 12))
        openOrganizationTool("open-direct-delete", in: app)
        let source = pickerRow("1920 × 1080", in: app)
        XCTAssertTrue(source.waitForExistence(timeout: 8))
        source.tap()
        app.buttons["confirm-selection"].tap()
        let remove = app.buttons["confirm-direct-delete"]
        XCTAssertTrue(remove.waitForExistence(timeout: 10), app.debugDescription)
        capture("未压缩原视频直接删除清单")
        remove.tap()
        app.alerts.buttons["取消"].tap()
        XCTAssertTrue(remove.exists)
        remove.tap()
        app.alerts.buttons["移到「最近删除」"].tap()
        confirmSystemRemoval()
        XCTAssertTrue(app.staticTexts["direct-delete-message"].waitForExistence(timeout: 15))
        XCTAssertTrue(app.staticTexts["direct-delete-message"].label.contains("1 条原视频已移到"))
        capture("原视频已直接删除等待系统清理")
        app.buttons["finish-direct-delete"].tap()
        XCTAssertTrue(pickerRow("640 × 360", in: app).waitForExistence(timeout: 12))
        XCTAssertTrue(pickerRow("2560 × 1440", in: app).exists)
        XCTAssertFalse(source.exists)
        app.buttons["取消"].tap()
        openTasks("视频", in: app)
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'workspace-task-' AND label CONTAINS '原片已直接删除'")).firstMatch.waitForExistence(timeout: 10), app.debugDescription)
        capture("任务同步直接删除状态")
    }

    @MainActor
    private func batchAction(_ action: BatchUIAction, in app: XCUIApplication) {
        for _ in 0..<3 where !app.buttons["batch-actions"].isHittable { app.swipeDown() }
        app.buttons["batch-actions"].tap()
        capture("批量操作菜单")
        let button = app.buttons.matching(NSPredicate(format: "identifier == %@ OR label BEGINSWITH %@", "batch-action-\(action.rawValue)", action.title)).firstMatch
        XCTAssertTrue(button.waitForExistence(timeout: 5), app.debugDescription)
        if !button.isHittable { app.swipeUp() }
        button.tap()
        XCTAssertTrue(app.buttons["confirm-batch-action"].waitForExistence(timeout: 8), app.debugDescription)
    }
    private enum BatchUIAction: String {
        case cancel, retry, save, verify, discard, download, pause, replace, deleteOriginal, start, export
        var title: String {
            switch self {
            case .cancel: "取消所选任务"
            case .retry: "重新开始所选任务"
            case .save: "保存所选成品"
            case .verify: "重新核验成品"
            case .discard: "清理任务和 App 内副本"
            case .download: "下载原片并压缩"
            case .pause: "暂停所选任务"
            case .replace: "复核并移除原片"
            case .deleteOriginal: "直接删除原视频"
            case .start: "开始所选任务"
            case .export: "导出所选副本"
            }
        }
    }

    @MainActor
    func test13PhotoBatchDownloadSaveAndReplaceSelectedOriginals() throws {
        try requireFixtureSimulator()
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN"]
        app.launch()
        openTasks("照片", in: app)
        if queueRow(1, status: "已保存", in: app).exists {
            beginSelection(in: app)
            reveal(app.buttons["batch-select-all"], in: app).tap()
            if !queueRow(1, status: "已保存并核验", in: app).exists {
                batchAction(.verify, in: app)
                confirmBatch(in: app)
                XCTAssertTrue(queueRow(1, status: "已保存并核验", in: app).waitForExistence(timeout: 30))
            }
        } else {
            app.tabBars.buttons["首页"].tap()
            XCTAssertTrue(app.buttons["open-photos"].waitForExistence(timeout: 12))
            app.buttons["open-photos"].tap()
            for resolution in ["1600 × 1200", "1500 × 2000"] {
                let row = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'photo-picker-' AND label CONTAINS %@", resolution)).firstMatch
                XCTAssertTrue(row.waitForExistence(timeout: 10), app.debugDescription)
                row.tap()
            }
            app.buttons["confirm-photos"].tap()
            pick("default-photo-preset", option: "更小尺寸", in: app)
            submitIntake(start: false, in: app)
            beginSelection(in: app)
            app.buttons["batch-select-all"].tap()
            batchAction(.download, in: app)
            XCTAssertTrue(app.staticTexts["batch-review-count"].label.contains("可处理 2 项"))
            capture("照片批量取回原片并压缩确认")
            confirmBatch(in: app)
            XCTAssertTrue(app.buttons.matching(NSPredicate(format: "identifier == 'workspace-task-1' AND label CONTAINS '待预览和保存'")).firstMatch.waitForExistence(timeout: 60), app.debugDescription)
            batchAction(.save, in: app)
            confirmBatch(in: app)
            XCTAssertTrue(app.buttons.matching(NSPredicate(format: "identifier == 'workspace-task-1' AND label CONTAINS '已保存并核验'")).firstMatch.waitForExistence(timeout: 40), app.debugDescription)
        }
        batchAction(.replace, in: app)
        XCTAssertTrue(app.staticTexts["batch-review-count"].label.contains("可处理 2 项"))
        let originals = app.buttons.matching(identifier: "workspace-check-original")
        for index in 0..<2 {
            let original = originals.element(boundBy: index)
            XCTAssertEqual(original.value as? String, "未勾选")
            reveal(original, in: app).tap()
            XCTAssertEqual(original.value as? String, "已勾选")
        }
        XCTAssertTrue(app.buttons["confirm-batch-action"].isEnabled)
        capture("只移除核验通过的两张原片")
        confirmBatch(in: app)
        confirmSystemRemoval()
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "identifier == 'workspace-task-1' AND label CONTAINS '原片待清理'")).firstMatch.waitForExistence(timeout: 25), app.debugDescription)
        capture("照片原片批量进入最近删除")
    }

    @MainActor
    func test14BatchDirectDeletionRequiresSeparateConfirmation() throws {
        try requireFixtureSimulator()
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN"]
        app.launch()
        openTasks("视频", in: app)
        beginSelection(in: app)
        app.buttons["workspace-task-0"].tap()
        batchAction(.deleteOriginal, in: app)
        XCTAssertTrue(app.staticTexts["batch-review-count"].label.contains("可处理 1 项"))
        confirmBatch(in: app)
        let remove = app.buttons["confirm-direct-delete"]
        XCTAssertTrue(remove.waitForExistence(timeout: 12), app.debugDescription)
        capture("从批量任务进入独立直接删除确认")
        remove.tap()
        app.alerts.buttons["取消"].tap()
        XCTAssertTrue(remove.exists)
        app.buttons["finish-direct-delete"].tap()
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "identifier == 'workspace-task-0' AND label CONTAINS '已保存'")).firstMatch.waitForExistence(timeout: 10))
    }

    @MainActor
    func test15PauseAndCancelAnActiveSelectedVideo() throws {
        try requireFixtureSimulator()
        continueAfterFailure = false
        let app = launchChineseApp()
        app.buttons["choose-video"].tap()
        let source = pickerRow("2560 × 1440", in: app)
        XCTAssertTrue(source.waitForExistence(timeout: 10))
        reveal(source, in: app).tap()
        app.buttons["confirm-selection"].tap()
        submitIntake(start: false, in: app)
        beginSelection(in: app)
        reveal(app.buttons["batch-select-all"], in: app).tap()
        batchAction(.start, in: app)
        confirmBatch(in: app)
        XCTAssertTrue(queueRow(0, status: "正在压缩", in: app).waitForExistence(timeout: 10))
        batchAction(.pause, in: app)
        confirmBatch(in: app)
        XCTAssertTrue(queueRow(0, status: "待压缩", in: app).waitForExistence(timeout: 15), app.debugDescription)
        capture("只暂停正在处理的所选视频")
        batchAction(.start, in: app)
        confirmBatch(in: app)
        XCTAssertTrue(queueRow(0, status: "正在压缩", in: app).waitForExistence(timeout: 10))
        batchAction(.cancel, in: app)
        confirmBatch(in: app)
        XCTAssertTrue(queueRow(0, status: "已取消任务", in: app).waitForExistence(timeout: 15), app.debugDescription)
        capture("取消当前任务保留原片")
    }

    @MainActor
    func test01RequestFullPhotoAccess() throws {
        try requireFixtureSimulator()
        continueAfterFailure = false
        addUIInterruptionMonitor(withDescription: "Photos access in the fixture simulator") { alert in
            let allow = self.photoPermissionButton(in: alert)
            guard allow.exists else { return false }
            allow.tap()
            return true
        }
        let app = XCUIApplication()
        app.launchArguments = ["-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN"]
        app.launch()
        let choose = app.buttons["choose-video"]
        XCTAssertTrue(choose.waitForExistence(timeout: 10))
        choose.tap()
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let alert = springboard.alerts.firstMatch
        let picker = app.navigationBars["选择视频"]
        for _ in 0..<3 where !picker.exists {
            guard alert.waitForExistence(timeout: 5) else { break }
            let allow = photoPermissionButton(in: alert)
            XCTAssertTrue(allow.exists, alert.debugDescription)
            allow.tap()
        }
        XCTAssertTrue(picker.waitForExistence(timeout: 10), app.debugDescription)
        capture("照片库授权后选片")
    }

    @MainActor
    private func photoPermissionButton(in alert: XCUIElement) -> XCUIElement {
        alert.buttons.matching(NSPredicate(format: "label CONTAINS '完全访问' OR label CONTAINS[c] 'full access' OR label == '允许' OR label == 'Allow'")).firstMatch
    }

    @MainActor
    func test07PhotoBatchCompressionZoomAndVerifiedCopies() throws {
        try requireFixtureSimulator()
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN"]
        app.launch()
        XCTAssertTrue(app.buttons["open-photos"].waitForExistence(timeout: 10))
        app.buttons["open-photos"].tap()
        let jpeg = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'photo-picker-' AND label CONTAINS '1600 × 1200'")).firstMatch
        let heic = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'photo-picker-' AND (label CONTAINS '1500 × 2000' OR label CONTAINS '2000 × 1500')")).firstMatch
        XCTAssertTrue(jpeg.waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertTrue(heic.exists, app.debugDescription)
        jpeg.tap(); heic.tap()
        XCTAssertTrue(app.buttons["confirm-photos"].label.contains("2"))
        capture("照片多选和保护说明")
        app.buttons["confirm-photos"].tap()
        pick("default-photo-preset", option: "更小尺寸", in: app)
        submitIntake(start: true, in: app)
        XCTAssertTrue(queueRow(0, status: "待预览和保存", in: app).waitForExistence(timeout: 60), app.debugDescription)
        XCTAssertTrue(queueRow(1, status: "待预览和保存", in: app).waitForExistence(timeout: 60), app.debugDescription)
        app.buttons["workspace-task-0"].tap()
        XCTAssertTrue(app.buttons["compare-photos"].waitForExistence(timeout: 10))
        app.buttons["compare-photos"].tap()
        let zoom = app.scrollViews["photo-zoom"]
        XCTAssertTrue(zoom.waitForExistence(timeout: 10), app.debugDescription)
        zoom.pinch(withScale: 2, velocity: 1)
        app.segmentedControls.buttons["原片"].tap()
        capture("照片原片放大对比")
        app.buttons["完成"].tap()
        app.navigationBars.buttons.element(boundBy: 0).tap()
        beginSelection(in: app)
        reveal(app.buttons["batch-select-all"], in: app).tap()
        batchAction(.save, in: app)
        confirmBatch(in: app)
        let verified = NSPredicate(format: "label CONTAINS '已保存并核验'")
        XCTAssertTrue(app.buttons.matching(identifier: "workspace-task-0").matching(verified).firstMatch.waitForExistence(timeout: 40), app.debugDescription)
        XCTAssertTrue(app.buttons.matching(identifier: "workspace-task-1").matching(verified).firstMatch.exists)
        capture("照片批量保存并核验")
        beginSelection(in: app, active: false)
        app.buttons["workspace-task-0"].tap()
        app.swipeUp()
        XCTAssertTrue(app.buttons["replace-photo"].waitForExistence(timeout: 8), app.debugDescription)
        app.buttons["replace-photo"].tap()
        app.alerts.buttons["取消"].tap()
        app.buttons["keep-photos"].tap()
        XCTAssertTrue(app.staticTexts["已保留原片和压缩件。"].waitForExistence(timeout: 8))
    }

    @MainActor
    func test08OrganizerReviewsSimilarAndRemovesOnlyCheckedDuplicate() throws {
        try requireFixtureSimulator()
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN"]
        app.launch()
        openOrganizationTool("open-organizer", in: app)
        let scan = app.buttons["scan-media"]
        XCTAssertTrue(scan.waitForExistence(timeout: 10))
        scan.tap()
        let exact = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'media-group-' AND label CONTAINS '完全重复'")).firstMatch
        let similar = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'media-group-' AND label CONTAINS '可能相似'")).firstMatch
        XCTAssertTrue(exact.waitForExistence(timeout: 90), app.debugDescription)
        XCTAssertTrue(similar.exists, app.debugDescription)
        capture("重复与相似分组")
        if !similar.isHittable { app.swipeUp() }
        similar.tap()
        let remove = app.buttons["remove-media-selection"]
        XCTAssertTrue(remove.waitForExistence(timeout: 8))
        XCTAssertFalse(remove.isEnabled)
        app.buttons["keep-member-0"].tap()
        app.buttons["remove-member-1"].tap()
        XCTAssertTrue(remove.isEnabled)
        capture("相似照片逐张复核")
        remove.tap()
        app.alerts.buttons["取消"].tap()
        app.navigationBars.buttons.element(boundBy: 0).tap()
        if !exact.isHittable { app.swipeDown() }
        exact.tap()
        XCTAssertTrue(remove.waitForExistence(timeout: 8))
        XCTAssertFalse(remove.isEnabled)
        app.buttons["keep-member-0"].tap()
        XCTAssertFalse(remove.isEnabled)
        app.buttons["remove-member-1"].tap()
        XCTAssertEqual(app.buttons["remove-member-1"].value as? String, "已勾选")
        XCTAssertTrue(remove.isEnabled)
        capture("完全重复项只勾选一件")
        remove.tap()
        app.alerts.buttons["移到「最近删除」"].tap()
        confirmSystemRemoval()
        let message = app.staticTexts.matching(NSPredicate(format: "label CONTAINS '1 项原件已移到'")).firstMatch
        XCTAssertTrue(message.waitForExistence(timeout: 30), app.debugDescription)
        capture("重复项移除后的状态")
    }

    @MainActor
    func test09PhotoReplacementRechecksAfterRelaunch() throws {
        try requireFixtureSimulator()
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN"]
        app.launch()
        XCTAssertTrue(app.buttons["open-photos"].waitForExistence(timeout: 10))
        openTasks("照片", in: app)
        let pending = app.buttons["workspace-task-1"]
        XCTAssertTrue(pending.waitForExistence(timeout: 10))
        pending.tap()
        app.swipeUp()
        XCTAssertFalse(app.buttons["replace-photo"].exists)
        let verify = app.buttons["verify-photo"]
        XCTAssertTrue(verify.waitForExistence(timeout: 10), app.debugDescription)
        verify.tap()
        XCTAssertTrue(app.buttons["replace-photo"].waitForExistence(timeout: 30), app.debugDescription)
        app.buttons["replace-photo"].tap()
        app.alerts.buttons["移到「最近删除」"].tap()
        confirmSystemRemoval()
        let removed = app.staticTexts.matching(NSPredicate(format: "label CONTAINS '原片已移到「最近删除」。压缩件'")).firstMatch
        XCTAssertTrue(removed.waitForExistence(timeout: 30), app.debugDescription)
        capture("照片替换后原片待清理")
    }

    @MainActor
    func test10OrganizerFilterChangesInvalidatePreviousGroups() throws {
        try requireFixtureSimulator()
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN"]
        app.launch()
        openOrganizationTool("open-organizer", in: app)
        let scan = app.buttons["scan-media"]
        XCTAssertTrue(scan.waitForExistence(timeout: 10))
        scan.tap()
        let similar = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'media-group-' AND label CONTAINS '可能相似'")).firstMatch
        XCTAssertTrue(similar.waitForExistence(timeout: 90), app.debugDescription)
        if !similar.isHittable { app.swipeUp() }
        similar.tap()
        app.buttons["keep-member-0"].tap()
        app.buttons["remove-member-1"].tap()
        capture("相似项对齐与选中颜色")
        app.navigationBars.buttons.element(boundBy: 0).tap()
        app.swipeDown()
        app.buttons["扫描范围与说明"].tap()
        app.switches["media-favorites"].tap()
        XCTAssertFalse(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'media-group-'")).firstMatch.exists)
        XCTAssertTrue(app.staticTexts["organizer-message"].label.contains("筛选范围已变化"))
        app.switches["media-date-range"].tap()
        XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "media-start-date").firstMatch.exists)
        XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "media-end-date").firstMatch.exists)
        app.switches["media-date-range"].tap()
        app.buttons["media-kind"].tap()
        app.buttons["录屏"].tap()
        XCTAssertTrue(app.staticTexts["media-filter-count"].label.contains("0"))
        capture("收藏录屏和日期筛选")
    }

    @MainActor
    func test05BackgroundInterruptionAndForegroundRetry() throws {
        try requireFixtureSimulator()
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN"]
        app.launch()
        XCTAssertTrue(app.buttons["choose-video"].waitForExistence(timeout: 10))
        app.buttons["choose-video"].tap()
        let video = pickerRow("2560 × 1440", in: app)
        XCTAssertTrue(video.waitForExistence(timeout: 10))
        video.tap()
        app.buttons["confirm-selection"].tap()
        submitIntake(start: false, in: app)
        reveal(app.buttons["workspace-task-0"], in: app).tap()
        let start = app.buttons["compress-video"]
        XCTAssertTrue(start.waitForExistence(timeout: 10))
        start.tap()
        let pause = app.buttons["cancel-compression"]
        XCTAssertTrue(pause.waitForExistence(timeout: 10))
        pause.tap()
        XCTAssertTrue(start.waitForExistence(timeout: 15), app.debugDescription)
        capture("取消编码后可重试")

        start.tap()
        XCTAssertTrue(app.staticTexts["compression-progress"].waitForExistence(timeout: 10))
        let granted = app.staticTexts["background-compression"].waitForExistence(timeout: 2)
        capture(granted ? "系统已批准后台压缩" : "前台压缩回退提示")
        XCUIDevice.shared.press(.home)
        let delay = expectation(description: "Let the scene enter background")
        delay.isInverted = true
        wait(for: [delay], timeout: 3)
        app.activate()
        if !granted {
            XCTAssertTrue(start.waitForExistence(timeout: 15), app.debugDescription)
            capture("后台中断后可重试")
            start.tap()
        }
        XCTAssertTrue(app.buttons["save-copy"].waitForExistence(timeout: 120), app.debugDescription)
        XCTAssertTrue(app.staticTexts["size-savings"].exists)
        XCTAssertFalse(app.buttons["replace-original"].exists)
        capture("长任务成品待用户复核")
    }

    @MainActor
    func test06RecoveredDownloadRequiresTapAndUsesPhotoKit() throws {
        try requireFixtureSimulator()
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN"]
        app.launch()
        // Uses a synthetic video's interrupted-download journal, not an actual iCloud transfer.
        openTasks("视频", in: app)
        pick("batch-filter", option: "待下载", in: app)
        reveal(app.buttons["workspace-task-0"], in: app).tap()
        let download = app.buttons["download-original"]
        XCTAssertTrue(download.waitForExistence(timeout: 8), app.debugDescription)
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS '原片大小待下载后核对'")).firstMatch.exists)
        XCTAssertFalse(app.staticTexts["download-progress"].exists)
        capture("恢复下载任务和空间说明")
        app.segmentedControls.buttons["省空间"].tap()
        if !download.isHittable { app.swipeUp() }
        XCTAssertTrue(download.isHittable)
        download.tap()
        XCTAssertTrue(app.buttons["save-copy"].waitForExistence(timeout: 120), app.debugDescription)
        app.swipeUp()
        app.buttons["save-copy"].tap()
        XCTAssertTrue(app.staticTexts["verified-copy"].waitForExistence(timeout: 30), app.debugDescription)
        XCTAssertTrue(app.buttons["keep-both"].exists)
        capture("显式取回素材后保存并核验")
        app.buttons["keep-both"].tap()
    }

    @MainActor
    func test02BatchResumesAndRemovesOnlyCheckedOriginal() throws {
        try requireFixtureSimulator()
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN"]
        app.launch()
        let choose = app.buttons["choose-video"]
        XCTAssertTrue(choose.waitForExistence(timeout: 15))
        XCTAssertFalse(app.staticTexts["queue-count"].exists, "Run the batch flow in a fresh fixture installation")
        choose.tap()
        let first = pickerRow("640 × 360", in: app)
        let second = pickerRow("2560 × 1440", in: app)
        XCTAssertTrue(first.waitForExistence(timeout: 8), app.debugDescription)
        XCTAssertTrue(second.waitForExistence(timeout: 8), app.debugDescription)
        first.tap()
        second.tap()
        app.buttons["confirm-selection"].tap()
        submitIntake(start: true, in: app)
        XCTAssertTrue(queueRow(0, status: "待预览和保存", in: app).waitForExistence(timeout: 50), app.debugDescription)
        XCTAssertTrue(queueRow(1, status: "正在压缩", in: app).waitForExistence(timeout: 8), app.debugDescription)
        app.terminate(); app.launch()
        openTasks("视频", in: app)
        XCTAssertTrue(queueRow(0, status: "待预览和保存", in: app).waitForExistence(timeout: 12), app.debugDescription)
        XCTAssertTrue(queueRow(1, status: "待压缩", in: app).exists, app.debugDescription)
        capture("重开后保留已完成项")
        beginSelection(in: app)
        reveal(app.buttons["workspace-task-1"], in: app).tap()
        batchAction(.start, in: app)
        confirmBatch(in: app)
        XCTAssertTrue(queueRow(1, status: "待预览和保存", in: app).waitForExistence(timeout: 90), app.debugDescription)
        reveal(app.buttons["batch-select-all"], in: app).tap()
        batchAction(.save, in: app)
        confirmBatch(in: app)
        XCTAssertTrue(queueRow(1, status: "已保存并核验", in: app).waitForExistence(timeout: 40))
        batchAction(.replace, in: app)
        let remove = app.buttons["confirm-batch-action"]
        XCTAssertFalse(remove.isEnabled)
        app.buttons.matching(identifier: "workspace-check-original").firstMatch.tap()
        XCTAssertTrue(remove.isEnabled && remove.label.contains("1"), app.debugDescription)
        capture("复核清单只勾选一条")
        remove.tap()
        app.alerts.buttons["取消"].tap()
        confirmBatch(in: app)
        confirmSystemRemoval()
        XCTAssertTrue(queueRow(0, status: "原片待清理", in: app).waitForExistence(timeout: 20), app.debugDescription)
        XCTAssertTrue(queueRow(1, status: "已保存并核验", in: app).exists, app.debugDescription)
        capture("只移除勾选项")
    }

    @MainActor
    func test03CatalogFiltersAndMeasuresLocalVideos() throws {
        try requireFixtureSimulator()
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN"]
        app.launch()
        reveal(app.buttons["open-organization"], in: app).tap()
        let browse = app.buttons["browse-large-videos"]
        XCTAssertTrue(browse.waitForExistence(timeout: 10))
        XCTAssertFalse(app.staticTexts["queue-count"].exists, "Use a fresh installation and the catalog fixtures")
        reveal(browse, in: app).tap()

        let sort = app.buttons["catalog-sort"]
        XCTAssertTrue(sort.waitForExistence(timeout: 10))
        XCTAssertEqual(sort.value as? String, "文件大小")
        let large = pickerRow("3840 × 2160", in: app)
        XCTAssertTrue(large.waitForExistence(timeout: 10), app.debugDescription)
        if #unavailable(iOS 27.0) {
            XCTAssertTrue(app.staticTexts["catalog-section-unknownSize"].exists)
            XCTAssertTrue(large.label.contains("文件大小未知"))
            capture("大视频大小待测")
        }
        app.buttons["catalog-more"].tap()
        app.buttons["measure-catalog"].tap()
        XCTAssertTrue(app.staticTexts["catalog-section-knownSize"].waitForExistence(timeout: 25), app.debugDescription)
        XCTAssertFalse(large.label.contains("文件大小未知"))
        XCTAssertTrue(large.label.contains("文件大小"))
        XCTAssertFalse(pickerRow("320 × 240", in: app).exists)
        capture("测量后找到大视频")
        app.buttons["取消"].tap()
        XCTAssertTrue(browse.waitForExistence(timeout: 5))
        capture("首页大视频预览")

        reveal(browse, in: app).tap()
        XCTAssertTrue(large.waitForExistence(timeout: 10))
        large.tap()
        app.buttons["catalog-filters"].tap()
        app.buttons["catalog-filter-long"].tap()
        XCTAssertTrue(pickerRow("320 × 240", in: app).waitForExistence(timeout: 5))
        XCTAssertFalse(large.exists)
        app.buttons["catalog-filters"].tap()
        app.buttons["catalog-filter-fourK"].tap()
        XCTAssertTrue(large.waitForExistence(timeout: 5))
        XCTAssertEqual(large.value as? String, "已选择")
        app.buttons["catalog-filters"].tap()
        app.buttons["catalog-filter-highFrameRate"].tap()
        let fast = pickerRow("960 × 540", in: app)
        XCTAssertTrue(fast.waitForExistence(timeout: 8), app.debugDescription)
        XCTAssertTrue(fast.label.contains("960 × 540"), fast.label)
        XCTAssertFalse(large.exists)
        fast.tap()
        capture("普通 60 fps 命中高帧率")

        app.buttons["catalog-filters"].tap()
        app.buttons["catalog-filter-screenRecording"].tap()
        XCTAssertTrue(app.staticTexts["没有符合条件的视频"].waitForExistence(timeout: 5))
        app.buttons["catalog-filters"].tap()
        app.buttons["catalog-filter-all"].tap()
        sort.tap()
        let sortSavings = app.buttons.matching(NSPredicate(format: "identifier == 'catalog-sort-savings' OR label == '预计收益'")).firstMatch
        XCTAssertTrue(sortSavings.waitForExistence(timeout: 5), app.debugDescription)
        sortSavings.tap()
        XCTAssertEqual(sort.value as? String, "预计收益")
        let first = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'video-row-'")).firstMatch
        XCTAssertTrue(first.label.contains("3840 × 2160"), first.label)
        capture("按均衡档预计收益排序")
        let add = app.buttons["confirm-selection"]
        XCTAssertTrue(add.label.contains("2"), add.label)
        add.tap()
        XCTAssertTrue(app.buttons["intake-selected-items"].waitForExistence(timeout: 8))
        XCTAssertTrue(app.buttons["intake-selected-items"].label.contains("2"))
        submitIntake(start: false, in: app)
        XCTAssertTrue(queueRow(1, status: "待压缩", in: app).waitForExistence(timeout: 10))
    }

    @MainActor
    func test04HDRAndCompatibilityExportKeepTheOriginals() throws {
        try requireFixtureSimulator()
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN"]
        app.launch()
        let choose = app.buttons["choose-video"]
        XCTAssertTrue(choose.waitForExistence(timeout: 12))
        choose.tap()
        app.buttons["catalog-more"].tap()
        let measure = app.buttons["measure-catalog"]
        XCTAssertTrue(measure.waitForExistence(timeout: 10))
        XCTAssertTrue(measure.isEnabled)
        measure.tap()

        app.buttons["catalog-more"].tap()
        app.buttons["catalog-details"].tap()
        let dolby = pickerRow("Dolby Vision 8.4", in: app)
        XCTAssertTrue(dolby.waitForExistence(timeout: 15), app.debugDescription)
        dolby.tap()
        app.buttons["confirm-selection"].tap()
        pick("default-video-preset", option: "省空间", in: app)
        submitIntake(start: true, in: app)
        openReadyVideo(in: app)
        verifyCopy("HEVC / MOV · HDR · Dolby Vision 8.4", attachment: "Dolby Vision 副本", in: app)

        app.tabBars.buttons["首页"].tap()
        XCTAssertTrue(choose.waitForExistence(timeout: 10))
        choose.tap()
        let hlg = pickerRow("HDR · HLG", in: app)
        XCTAssertTrue(hlg.waitForExistence(timeout: 10), app.debugDescription)
        hlg.tap()
        app.buttons["confirm-selection"].tap()
        let format = app.buttons["video-encoding"]
        XCTAssertTrue(format.waitForExistence(timeout: 8), app.debugDescription)
        format.tap()
        let h264 = app.buttons["H.264 兼容"].firstMatch
        XCTAssertTrue(h264.waitForExistence(timeout: 5), app.debugDescription)
        h264.tap()
        pick("default-video-preset", option: "省空间", in: app)
        submitIntake(start: true, in: app)
        openReadyVideo(in: app)
        verifyCopy("H.264 / MP4 · SDR", attachment: "H.264 兼容副本", in: app)
        XCTAssertFalse(app.buttons["review-removals"].exists, app.debugDescription)
    }

    @MainActor
    private func verifyCopy(_ format: String, attachment: String, in app: XCUIApplication) {
        let save = app.buttons["save-copy"]
        XCTAssertTrue(save.waitForExistence(timeout: 75), app.debugDescription)
        XCTAssertEqual(save.label, "保存副本")
        XCTAssertTrue(app.descendants(matching: .any)
            .matching(NSPredicate(format: "label CONTAINS %@", format)).firstMatch.exists, app.debugDescription)
        app.segmentedControls.buttons["原片"].tap()
        app.segmentedControls.buttons["压缩件"].tap()
        capture(attachment)
        if !save.isHittable { app.swipeUp() }
        save.tap()
        XCTAssertTrue(app.staticTexts["verified-copy"].waitForExistence(timeout: 25), app.debugDescription)
        XCTAssertFalse(app.buttons["replace-original"].exists)
        let keep = app.buttons["keep-both"]
        if !keep.isHittable { app.swipeUp() }
        keep.tap()
    }

    @MainActor
    func testCompressPreviewSaveAndConfirmReplacement() throws {
        try requireFixtureSimulator()
        continueAfterFailure = false
        let app = launchChineseApp()
        openTasks("视频", in: app)
        let ready = taskRow(named: "视频", status: "待预览和保存", in: app)
        if ready.exists {
            reveal(ready, in: app).tap()
        } else {
            app.tabBars.buttons["首页"].tap()
            app.buttons["choose-video"].tap()
            let video = pickerRow("1920 × 1080", in: app)
            guard video.waitForExistence(timeout: 10) else {
                throw XCTSkip("Import the generated UIFixture.mov into this fixture simulator before the full flow test")
            }
            reveal(video, in: app).tap()
            app.buttons["confirm-selection"].tap()
            submitIntake(start: true, in: app)
            openReadyVideo(in: app)
        }
        let save = app.buttons["save-copy"]
        XCTAssertTrue(save.waitForExistence(timeout: 60), app.debugDescription)
        app.segmentedControls.buttons["原片"].tap()
        app.segmentedControls.buttons["压缩件"].tap()
        save.tap()
        XCTAssertTrue(app.staticTexts["verified-copy"].waitForExistence(timeout: 20), app.debugDescription)
        capture("压缩件保存并核验")
        let replace = app.buttons["replace-original"]
        if !replace.isHittable { app.swipeUp() }
        XCTAssertTrue(replace.waitForExistence(timeout: 5))
        replace.tap()
        let cancel = app.buttons["取消"].firstMatch
        XCTAssertTrue(cancel.waitForExistence(timeout: 5))
        cancel.tap()
        XCTAssertTrue(replace.exists)
        replace.tap()
        app.buttons["移到「最近删除」"].tap()
        confirmSystemRemoval()
        XCTAssertTrue(app.staticTexts["original-in-recently-deleted"].waitForExistence(timeout: 15), app.debugDescription)
        capture("原片进入最近删除")
        app.buttons["完成"].tap()
        XCTAssertTrue(app.navigationBars["任务"].waitForExistence(timeout: 5))
    }

    @MainActor
    private func pickerRow(_ resolution: String, in app: XCUIApplication) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'video-row-' AND label CONTAINS %@", resolution)).firstMatch
    }

    @MainActor
    private func queueRow(_ index: Int, status: String, in app: XCUIApplication) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "identifier == %@ AND label CONTAINS %@", "workspace-task-\(index)", status)).firstMatch
    }

    @MainActor
    private func confirmSystemRemoval() {
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let systemAlert = springboard.alerts.firstMatch
        XCTAssertTrue(systemAlert.waitForExistence(timeout: 12), springboard.debugDescription)
        let deletion = systemAlert.buttons.matching(NSPredicate(format: "label CONTAINS 'Delete' OR label CONTAINS '删除'")).firstMatch
        XCTAssertTrue(deletion.exists, systemAlert.debugDescription)
        deletion.tap()
    }

    @MainActor
    private func capture(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func requireFixtureSimulator() throws {
        guard ProcessInfo.processInfo.environment["SIMULATOR_DEVICE_NAME"]?.hasPrefix("DisquEZ") == true else {
            throw XCTSkip("Photo library UI tests require a dedicated simulator named DisquEZ…")
        }
    }
}
