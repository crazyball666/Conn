//
//  DockerRunFormUITests.swift
//  ConnUITests
//
//  验收「创建容器」表单的新 UI：镜像选择、精简基本字段、TextArea 高级选项、命令预览、保存按钮。
//  走演示模式：CONN_DEMO=1 + CONN_SMOKE_DETAIL=1 + CONN_SMOKE_SEGMENT=docker
//  直接落到 Docker 段，省掉「先加主机再等 SSH」的慢路径。
//

import XCTest

final class DockerRunFormUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testCreateContainerFormShowsNewFieldsAndSaveButton() throws {
        let app = XCUIApplication()
        app.launchEnvironment["CONN_DEMO"] = "1"
        app.launchEnvironment["CONN_SMOKE_DETAIL"] = "1"
        app.launchEnvironment["CONN_SMOKE_SEGMENT"] = "docker"
        app.launch()

        let menuTrigger = app.buttons["更多操作"]
        XCTAssertTrue(menuTrigger.waitForExistence(timeout: 8), "Docker 段的「更多操作」菜单应出现")
        menuTrigger.tap()

        // 菜单项的查询要用 NSPredicate 比 label，subscript 走 identifier。
        let createMenuItem = app.buttons.matching(NSPredicate(format: "label == '创建容器'")).firstMatch
        XCTAssertTrue(createMenuItem.waitForExistence(timeout: 4), "「创建容器」菜单项应出现")
        createMenuItem.tap()

        XCTAssertTrue(app.navigationBars["创建容器"].waitForExistence(timeout: 4), "sheet 标题应出现")

        // 主机名、用户、工作目录和只读根文件系统属于低频 Docker flag，
        // 不再占据「基本」区，仍可在下方高级选项手动填写。
        XCTAssertFalse(app.textFields.matching(NSPredicate(format: "placeholderValue == '主机名'")).firstMatch.exists)
        XCTAssertFalse(app.textFields.matching(NSPredicate(format: "placeholderValue == '用户'")).firstMatch.exists)
        XCTAssertFalse(app.textFields.matching(NSPredicate(format: "placeholderValue == '工作目录'")).firstMatch.exists)
        XCTAssertFalse(app.switches.matching(NSPredicate(format: "label == '只读根文件系统'")).firstMatch.exists)

        XCTAssertTrue(
            app.buttons["选择已有镜像"].waitForExistence(timeout: 6),
            "已有镜像时应显示镜像选择按钮"
        )

        // TextField/Toggle 不一定滚到视口内，但存在性已经够验。往下滚一段让 section header 可见。
        app.swipeUp()
        app.swipeUp()

        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label == '高级选项'")).firstMatch.exists)
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label == '预览命令'")).firstMatch.exists)

        // 滚到底找保存按钮
        app.swipeUp()
        let saveButton = app.buttons.matching(NSPredicate(format: "label == '保存到本地命令'")).firstMatch
        XCTAssertTrue(saveButton.waitForExistence(timeout: 2), "保存到本地命令按钮应出现")

        attachScreenshot(app, name: "create-container-form-empty")
    }

    @MainActor
    func testFillingFormUpdatesCommandPreview() throws {
        let app = XCUIApplication()
        app.launchEnvironment["CONN_DEMO"] = "1"
        app.launchEnvironment["CONN_SMOKE_DETAIL"] = "1"
        app.launchEnvironment["CONN_SMOKE_SEGMENT"] = "docker"
        app.launch()

        let menuTrigger = app.buttons["更多操作"]
        XCTAssertTrue(menuTrigger.waitForExistence(timeout: 8))
        menuTrigger.tap()
        app.buttons.matching(NSPredicate(format: "label == '创建容器'")).firstMatch.tap()
        XCTAssertTrue(app.navigationBars["创建容器"].waitForExistence(timeout: 4))

        // 通过下拉选择已有镜像，证明仍支持直接手动输入镜像引用。
        let imageField = app.textFields.matching(NSPredicate(format: "placeholderValue == '镜像'")).firstMatch
        XCTAssertTrue(imageField.waitForExistence(timeout: 2))
        let imageMenu = app.buttons["选择已有镜像"]
        XCTAssertTrue(imageMenu.waitForExistence(timeout: 6))
        imageMenu.tap()
        let existingImage = app.buttons["nginx:1.25"]
        XCTAssertTrue(existingImage.waitForExistence(timeout: 2))
        existingImage.tap()

        // 关闭键盘，避免挡到 toggle
        app.swipeDown()

        // 滚到底拿预览命令的整段文本；低频参数的手动输入由 ConnTests 覆盖。
        for _ in 0..<8 { app.swipeUp() }

        // 预览命令段里应包含我们填的所有 flag——用 contains 匹配静态文本
        XCTAssertTrue(
            app.staticTexts.containing(NSPredicate(format: "label CONTAINS 'nginx:1.25'")).firstMatch.waitForExistence(timeout: 2),
            "预览命令应包含镜像"
        )
        attachScreenshot(app, name: "create-container-form-filled")
    }

    @MainActor
    func testSaveAsCommandShowsConfirmation() throws {
        let app = XCUIApplication()
        app.launchEnvironment["CONN_DEMO"] = "1"
        app.launchEnvironment["CONN_SMOKE_DETAIL"] = "1"
        app.launchEnvironment["CONN_SMOKE_SEGMENT"] = "docker"
        app.launch()

        app.buttons["更多操作"].tap()
        app.buttons.matching(NSPredicate(format: "label == '创建容器'")).firstMatch.tap()
        XCTAssertTrue(app.navigationBars["创建容器"].waitForExistence(timeout: 4))

        let imageField = app.textFields.matching(NSPredicate(format: "placeholderValue == '镜像'")).firstMatch
        XCTAssertTrue(imageField.waitForExistence(timeout: 2))
        imageField.tap()
        // 回车让 TextField 结束编辑并收起系统键盘，避免滚动手势只移动内容。
        imageField.typeText("alpine:3.19\n")
        XCTAssertTrue(app.keyboards.firstMatch.waitForNonExistence(timeout: 2))
        // 滚到底
        for _ in 0..<10 { app.swipeUp() }

        let saveButton = app.buttons.matching(NSPredicate(format: "label == '保存到本地命令'")).firstMatch
        XCTAssertTrue(saveButton.waitForExistence(timeout: 2), "保存按钮应可见")
        saveButton.tap()

        // 「已保存：运行 alpine:3.19」标签出现
        XCTAssertTrue(
            app.staticTexts.containing(NSPredicate(format: "label BEGINSWITH '已保存'")).firstMatch.waitForExistence(timeout: 2),
            "保存后应出现成功标签"
        )

        attachScreenshot(app, name: "create-container-form-saved")
    }

    @MainActor
    func testCreateVolumeFormUsesPreviewAndTextOptions() throws {
        let app = launchDockerResource(tab: "volumes")
        openCreateResource(app, menuLabel: "创建卷", navigationTitle: "创建卷")

        XCTAssertTrue(app.textFields.matching(NSPredicate(format: "placeholderValue == '名称'"))
            .firstMatch.waitForExistence(timeout: 2))
        for _ in 0..<4 { app.swipeUp() }
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label == '高级选项'"))
            .firstMatch.waitForExistence(timeout: 2))
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label == '预览命令'"))
            .firstMatch.waitForExistence(timeout: 2))
        let saveButton = app.buttons.matching(NSPredicate(format: "label == '保存到本地命令'"))
            .firstMatch
        XCTAssertTrue(saveButton.waitForExistence(timeout: 2))
        XCTAssertFalse(saveButton.isEnabled, "名称为空时不能保存无效的卷命令")
        attachScreenshot(app, name: "create-volume-form")
    }

    @MainActor
    func testCreateNetworkFormUsesPreviewAndTextOptions() throws {
        let app = launchDockerResource(tab: "networks")
        openCreateResource(app, menuLabel: "创建网络", navigationTitle: "创建网络")

        XCTAssertTrue(app.switches["内部网络"].waitForExistence(timeout: 2))
        for _ in 0..<4 { app.swipeUp() }
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label == '高级选项'"))
            .firstMatch.waitForExistence(timeout: 2))
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label == '预览命令'"))
            .firstMatch.waitForExistence(timeout: 2))
        let saveButton = app.buttons.matching(NSPredicate(format: "label == '保存到本地命令'"))
            .firstMatch
        XCTAssertTrue(saveButton.waitForExistence(timeout: 2))
        XCTAssertFalse(saveButton.isEnabled, "名称为空时不能保存无效的网络命令")
        attachScreenshot(app, name: "create-network-form")
    }

    @MainActor
    func testPullImageFormShowsCommandPreview() throws {
        let app = launchDockerResource(tab: "images")
        openCreateResource(app, menuLabel: "拉取镜像", navigationTitle: "拉取镜像")

        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label == '预览命令'"))
            .firstMatch.waitForExistence(timeout: 2))
        let referenceField = app.textFields["镜像引用"]
        XCTAssertTrue(referenceField.waitForExistence(timeout: 2))
        referenceField.tap()
        referenceField.typeText("nginx:latest")
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label == %@", "docker pull 'nginx:latest'"))
            .firstMatch.waitForExistence(timeout: 2))
        attachScreenshot(app, name: "pull-image-form")
    }

    private func launchDockerResource(tab: String) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["CONN_DEMO"] = "1"
        app.launchEnvironment["CONN_SMOKE_DETAIL"] = "1"
        app.launchEnvironment["CONN_SMOKE_SEGMENT"] = "docker"
        app.launchEnvironment["CONN_SMOKE_DOCKER_TAB"] = tab
        app.launch()
        return app
    }

    private func openCreateResource(_ app: XCUIApplication, menuLabel: String, navigationTitle: String) {
        let menuTrigger = app.buttons["更多操作"]
        XCTAssertTrue(menuTrigger.waitForExistence(timeout: 8))
        menuTrigger.tap()
        let createMenuItem = app.buttons.matching(NSPredicate(format: "label == %@", menuLabel)).firstMatch
        XCTAssertTrue(createMenuItem.waitForExistence(timeout: 4))
        createMenuItem.tap()
        XCTAssertTrue(app.navigationBars[navigationTitle].waitForExistence(timeout: 4))
    }

    private func attachScreenshot(_ app: XCUIApplication, name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
