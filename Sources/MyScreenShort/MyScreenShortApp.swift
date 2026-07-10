import AppKit

private var appDelegate: MyScreenShortApp?

@main
enum MyScreenShortMain {
    static func main() {
        let application = NSApplication.shared
        let delegate = MyScreenShortApp()
        appDelegate = delegate
        application.delegate = delegate
        application.run()
    }
}

final class MyScreenShortApp: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem?
    private var lastCaptureStatusItem: NSStatusItem?
    private var lastCaptureImage: NSImage?
    private var lastCaptureImageData: Data?
    private let screenshotService = ScreenshotService()
    private lazy var scheduledCaptureService = ScheduledCaptureService(
        screenshotService: screenshotService
    )
    private let launchAgentService = LaunchAgentService()
    private var hotKeyService: HotKeyService?
    private var workspaceActivationObserver: NSObjectProtocol?
    private var lastExternalApplication: NSRunningApplication?
    private let shortcutMenuItem = NSMenuItem(title: "Command + Shift + S / Control + Shift + S 캡처", action: #selector(captureToClipboard), keyEquivalent: "")
    private let scheduleRegionMenuItem = NSMenuItem(title: "영역 지정 후 예약 캡처…", action: #selector(selectRegionAndScheduleCapture), keyEquivalent: "")
    private let repeatScheduledRegionMenuItem = NSMenuItem(title: "마지막 영역 다시 예약 캡처", action: nil, keyEquivalent: "")
    private let scheduledCaptureHelpMenuItem = NSMenuItem(title: "사용법: 아래에서 영역·시간 선택 → 예약 시작", action: nil, keyEquivalent: "")
    private let cancelScheduledCaptureMenuItem = NSMenuItem(title: "예약 캡처 취소", action: #selector(cancelScheduledCapture), keyEquivalent: "")
    private let captureHelpMenuItem = NSMenuItem(title: "캡처 사용법…", action: #selector(showCaptureHelp), keyEquivalent: "")
    private let permissionMenuItem = NSMenuItem(title: "화면 녹화 권한 열기", action: #selector(openScreenCaptureSettings), keyEquivalent: "")
    private let autoStartMenuItem = NSMenuItem(title: "Mac 시작 시 자동 실행", action: #selector(toggleAutoStart), keyEquivalent: "")
    private let statusMenuItem = NSMenuItem(title: "대기 중", action: nil, keyEquivalent: "")

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        launchAgentService.migrateLegacyRegistrationIfNeeded()
        setupStatusItem()
        setupWorkspaceActivationTracking()
        scheduledCaptureService.onPendingStateChanged = { [weak self] _ in
            self?.refreshScheduledCaptureMenuItems()
        }
        refreshScheduledCaptureMenuItems()
        AppLogService.write("App started")
        refreshScreenCapturePermissionStatus()
        registerHotKey()
    }

    func applicationWillTerminate(_ notification: Notification) {
        hotKeyService?.unregister()
        scheduledCaptureService.cancel()
        if let workspaceActivationObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(workspaceActivationObserver)
        }
    }

    private func setupStatusItem() {
        let menu = NSMenu()
        menu.delegate = self
        shortcutMenuItem.target = self
        scheduleRegionMenuItem.target = self
        cancelScheduledCaptureMenuItem.target = self
        captureHelpMenuItem.target = self
        scheduledCaptureHelpMenuItem.isEnabled = false
        let repeatMenu = NSMenu(title: "마지막 영역 준비 시간")
        [3, 5, 10].forEach { delay in
            let item = NSMenuItem(
                title: "\(delay)초 후 캡처",
                action: #selector(scheduleLastRegionCapture(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.tag = delay
            repeatMenu.addItem(item)
        }
        repeatScheduledRegionMenuItem.submenu = repeatMenu
        permissionMenuItem.target = self
        autoStartMenuItem.target = self
        statusMenuItem.isEnabled = false

        menu.addItem(shortcutMenuItem)
        menu.addItem(scheduleRegionMenuItem)
        menu.addItem(repeatScheduledRegionMenuItem)
        menu.addItem(scheduledCaptureHelpMenuItem)
        menu.addItem(cancelScheduledCaptureMenuItem)
        menu.addItem(NSMenuItem.separator())
        menu.addItem(captureHelpMenuItem)
        menu.addItem(permissionMenuItem)
        menu.addItem(NSMenuItem.separator())
        menu.addItem(autoStartMenuItem)
        menu.addItem(statusMenuItem)
        menu.addItem(NSMenuItem.separator())
        let quitMenuItem = NSMenuItem(title: "종료", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        quitMenuItem.target = NSApp
        menu.addItem(quitMenuItem)

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let image = NSImage(systemSymbolName: "camera.fill", accessibilityDescription: "MyScreenShort") {
            image.isTemplate = true
            statusItem?.button?.image = image
        } else {
            statusItem?.button?.title = "S"
        }
        statusItem?.button?.toolTip = "MyScreenShort\n클릭: 즉시 캡처·예약 영역 캡처·사용법"
        statusItem?.menu = menu

        refreshAutoStartMenu()
    }

    func menuWillOpen(_ menu: NSMenu) {
        refreshScheduledCaptureMenuItems()
    }

    private func registerHotKey() {
        hotKeyService = HotKeyService { [weak self] in
            self?.captureToClipboard()
        }

        do {
            try hotKeyService?.registerCaptureHotKeys()
            updateStatus("단축키 등록 완료")
            AppLogService.write("Hotkeys registered: Command+Shift+S, Control+Shift+S")
        } catch {
            updateStatus("단축키 등록 실패")
            AppLogService.write("Hotkey registration failed: \(error)")
        }
    }

    private func refreshScreenCapturePermissionStatus() {
        let hasPermission = CGPreflightScreenCaptureAccess()
        AppLogService.write("Screen capture permission: \(hasPermission)")

        if !hasPermission {
            updateStatus("화면 녹화 권한 확인 필요")
            _ = requestScreenCapturePermission()
        }
    }

    private func hasScreenCapturePermissionForCapture() -> Bool {
        let hasPermission = CGPreflightScreenCaptureAccess()
        AppLogService.write("Screen capture permission: \(hasPermission)")

        if hasPermission {
            return true
        }

        updateStatus("화면 녹화 권한 필요")
        AppLogService.write("Screen capture permission missing")
        return requestScreenCapturePermission()
    }

    private func requestScreenCapturePermission() -> Bool {
        AppLogService.write("Requesting screen capture permission")
        let granted = CGRequestScreenCaptureAccess()
        AppLogService.write("Screen capture permission request result: \(granted)")

        if granted {
            updateStatus("화면 녹화 권한 허용됨")
            return true
        }

        updateStatus("화면 녹화 권한을 켠 뒤 앱 재실행 필요")
        openScreenCapturePrivacySettings()
        return false
    }

    private func refreshAutoStartMenu() {
        autoStartMenuItem.state = launchAgentService.isEnabled ? .on : .off
    }

    private func updateStatus(_ message: String) {
        DispatchQueue.main.async {
            self.statusMenuItem.title = message
        }
    }

    private func setupWorkspaceActivationTracking() {
        let currentPID = ProcessInfo.processInfo.processIdentifier
        if let frontmost = NSWorkspace.shared.frontmostApplication,
           frontmost.processIdentifier != currentPID {
            lastExternalApplication = frontmost
        }

        workspaceActivationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let application = notification.userInfo?[
                NSWorkspace.applicationUserInfoKey
            ] as? NSRunningApplication,
                  application.processIdentifier != currentPID else {
                return
            }
            self?.lastExternalApplication = application
        }
    }

    private func refreshScheduledCaptureMenuItems() {
        repeatScheduledRegionMenuItem.isEnabled = scheduledCaptureService.lastRegion != nil
            && !scheduledCaptureService.isPending
        scheduleRegionMenuItem.isEnabled = !scheduledCaptureService.isPending
            && !screenshotService.isCaptureInProgress
        cancelScheduledCaptureMenuItem.isHidden = !scheduledCaptureService.isPending
        cancelScheduledCaptureMenuItem.isEnabled = scheduledCaptureService.isPending
    }

    @objc private func captureToClipboard() {
        if scheduledCaptureService.isPending {
            scheduledCaptureService.cancel()
            updateStatus("예약 캡처 취소 후 즉시 캡처")
        }
        guard hasScreenCapturePermissionForCapture() else {
            return
        }

        updateStatus("캡처 중...")
        AppLogService.write("Capture requested")
        screenshotService.captureToClipboard { [weak self] result in
            switch result {
            case .success(let capture):
                self?.handleCaptureSuccess(capture, isScheduled: false)
            case .failure(let error):
                self?.handleCaptureFailure(error, isScheduled: false)
            }
        }
    }

    @objc private func selectRegionAndScheduleCapture() {
        guard hasScreenCapturePermissionForCapture() else { return }
        guard !scheduledCaptureService.isPending,
              !screenshotService.isCaptureInProgress else {
            updateStatus("다른 캡처가 진행 중")
            return
        }

        let applicationToRestore = lastExternalApplication
        updateStatus("예약 캡처 영역 지정 중…")
        scheduledCaptureService.selectRegion { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let selection):
                self.refreshScheduledCaptureMenuItems()
                self.startScheduledCapture(
                    region: selection.region,
                    delay: selection.delay,
                    restore: applicationToRestore
                )
            case .failure(let error):
                self.handleCaptureFailure(error, isScheduled: true)
            }
        }
    }

    @objc private func scheduleLastRegionCapture(_ sender: NSMenuItem) {
        guard hasScreenCapturePermissionForCapture() else { return }
        guard let region = scheduledCaptureService.lastRegion else {
            updateStatus("저장된 예약 영역 없음")
            refreshScheduledCaptureMenuItems()
            return
        }
        startScheduledCapture(
            region: region,
            delay: sender.tag,
            restore: lastExternalApplication
        )
    }

    @objc private func cancelScheduledCapture() {
        scheduledCaptureService.cancel()
        updateStatus("예약 캡처 취소됨")
        AppLogService.write("Scheduled capture cancelled")
    }

    @objc private func showCaptureHelp() {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "MyScreenShort 사용법"
        alert.informativeText = """
        즉시 캡처
        • Command+Shift+S 또는 Control+Shift+S
        • 영역 선택 후 펜·화살표·사각형·텍스트로 표시하고 캡처

        예약 영역 캡처
        1. 화면 상단 메뉴 막대의 카메라 아이콘을 클릭합니다.
        2. ‘영역 지정 후 예약 캡처…’를 선택합니다.
        3. 하단 패널에서 영역과 3초·5초·10초 준비 시간을 함께 선택하고 ‘예약 시작’을 누릅니다.
        4. 대상 앱에서 메뉴·콤보박스·팝업을 엽니다.
        5. 테두리가 사라진 뒤 지정 영역이 자동으로 캡처됩니다.

        마지막 영역은 ‘마지막 영역 다시 예약 캡처’의 3초·5초·10초 하위 메뉴에서 바로 사용할 수 있습니다.
        """
        alert.alertStyle = .informational
        alert.addButton(withTitle: "확인")
        alert.runModal()
    }

    private func startScheduledCapture(
        region: ScheduledCaptureRegion,
        delay: Int,
        restore application: NSRunningApplication?
    ) {
        scheduledCaptureService.schedule(
            region: region,
            delay: delay,
            onTick: { [weak self] remaining in
                guard remaining > 0 else {
                    self?.updateStatus("예약 영역 캡처 중…")
                    return
                }
                self?.updateStatus("예약 영역 캡처: \(remaining)초 남음")
            },
            completion: { [weak self] result in
                switch result {
                case .success(let capture):
                    self?.handleCaptureSuccess(capture, isScheduled: true)
                case .failure(let error):
                    self?.handleCaptureFailure(error, isScheduled: true)
                }
            }
        )

        application?.activate(options: [.activateAllWindows, .activateIgnoringOtherApps])
        AppLogService.write("Scheduled capture started: delay=\(delay), rect=\(region.rect)")
    }

    private func handleCaptureSuccess(_ capture: ScreenshotCapture, isScheduled: Bool) {
        updateLastCapturePreview(with: capture.image, imageData: capture.imageData)
        let prefix = isScheduled ? "예약 캡처" : "캡처"
        switch capture.destination {
        case .saveAndCopy:
            updateStatus("\(prefix) 저장 및 복사 완료")
        case .saveOnly:
            updateStatus("\(prefix) 저장 완료")
        case .copyOnly:
            updateStatus("\(prefix) 복사 완료")
        }
        AppLogService.write(
            "\(isScheduled ? "Scheduled capture" : "Capture") completed: \(capture.fileURL?.path ?? "clipboard only")"
        )
    }

    private func handleCaptureFailure(_ error: Error, isScheduled: Bool) {
        if let screenshotError = error as? ScreenshotError,
           case .captureCancelled = screenshotError {
            updateStatus(isScheduled ? "예약 영역 지정 취소됨" : "캡처 취소됨")
            AppLogService.write(isScheduled ? "Scheduled region selection cancelled" : "Capture cancelled")
        } else {
            updateStatus(isScheduled ? "예약 캡처 실패" : "캡처 실패")
            AppLogService.write("Capture failed: \(error)")
        }
        refreshScheduledCaptureMenuItems()
    }

    @objc private func toggleAutoStart() {
        do {
            if launchAgentService.isEnabled {
                try launchAgentService.disable()
            } else {
                try launchAgentService.enable()
            }
            refreshAutoStartMenu()
        } catch {
            updateStatus("자동 시작 변경 실패")
        }
    }

    @objc private func openScreenCaptureSettings() {
        if !CGPreflightScreenCaptureAccess() {
            AppLogService.write("Requesting screen capture permission from settings menu")
            _ = requestScreenCapturePermission()
        }

        openScreenCapturePrivacySettings()
    }

    @objc private func copyLastCaptureToClipboard() {
        guard let lastCaptureImage else {
            updateStatus("마지막 캡처 없음")
            return
        }

        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        if let lastCaptureImageData {
            let item = NSPasteboardItem()
            item.setData(lastCaptureImageData, forType: .png)
            if let tiffData = lastCaptureImage.tiffRepresentation {
                item.setData(tiffData, forType: .tiff)
            }
            if !pasteboard.writeObjects([item]) {
                pasteboard.writeObjects([lastCaptureImage])
            }
        } else {
            pasteboard.writeObjects([lastCaptureImage])
        }
        updateStatus("마지막 캡처 복사 완료")
    }

    @objc private func hideLastCapturePreview() {
        if let lastCaptureStatusItem {
            NSStatusBar.system.removeStatusItem(lastCaptureStatusItem)
        }

        lastCaptureStatusItem = nil
        lastCaptureImage = nil
        lastCaptureImageData = nil
        updateStatus("마지막 캡처 숨김")
    }

    private func updateLastCapturePreview(with image: NSImage, imageData: Data) {
        DispatchQueue.main.async {
            self.lastCaptureImage = image
            self.lastCaptureImageData = imageData

            let statusItem = self.lastCaptureStatusItem ?? NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
            self.lastCaptureStatusItem = statusItem

            let thumbnail = self.menuBarThumbnail(from: image)
            statusItem.length = thumbnail.size.width + 12
            statusItem.button?.image = thumbnail
            statusItem.button?.imagePosition = .imageOnly
            statusItem.button?.toolTip = "마지막 캡처 미리보기"
            statusItem.menu = self.makeLastCaptureMenu(for: image)
        }
    }

    private func makeLastCaptureMenu(for image: NSImage) -> NSMenu {
        let menu = NSMenu()

        let previewItem = NSMenuItem()
        previewItem.view = makePreviewView(for: image)
        menu.addItem(previewItem)
        menu.addItem(NSMenuItem.separator())

        let copyMenuItem = NSMenuItem(title: "마지막 캡처 다시 복사", action: #selector(copyLastCaptureToClipboard), keyEquivalent: "")
        copyMenuItem.target = self
        menu.addItem(copyMenuItem)

        let hideMenuItem = NSMenuItem(title: "상단바 미리보기 숨기기", action: #selector(hideLastCapturePreview), keyEquivalent: "")
        hideMenuItem.target = self
        menu.addItem(hideMenuItem)

        return menu
    }

    private func makePreviewView(for image: NSImage) -> NSView {
        let containerSize = NSSize(width: 340, height: 220)
        let imageViewFrame = NSRect(x: 10, y: 10, width: 320, height: 200)
        let containerView = NSView(frame: NSRect(origin: .zero, size: containerSize))
        let imageView = NSImageView(frame: imageViewFrame)

        imageView.image = image
        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.wantsLayer = true
        imageView.layer?.cornerRadius = 8
        imageView.layer?.borderWidth = 1
        imageView.layer?.borderColor = NSColor.separatorColor.cgColor
        imageView.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor

        containerView.addSubview(imageView)
        return containerView
    }

    private func menuBarThumbnail(from image: NSImage) -> NSImage {
        let originalSize = validImageSize(for: image)
        let targetHeight: CGFloat = 18
        let targetWidth = min(max(targetHeight, targetHeight * originalSize.width / originalSize.height), 42)
        let targetSize = NSSize(width: targetWidth, height: targetHeight)
        let thumbnail = NSImage(size: targetSize)

        thumbnail.lockFocus()
        NSColor.clear.setFill()
        NSRect(origin: .zero, size: targetSize).fill()

        let clipPath = NSBezierPath(roundedRect: NSRect(origin: .zero, size: targetSize), xRadius: 4, yRadius: 4)
        clipPath.addClip()

        image.draw(
            in: aspectFillRect(for: originalSize, targetSize: targetSize),
            from: NSRect(origin: .zero, size: originalSize),
            operation: .copy,
            fraction: 1
        )

        NSColor.separatorColor.setStroke()
        clipPath.lineWidth = 1
        clipPath.stroke()
        thumbnail.unlockFocus()

        return thumbnail
    }

    private func validImageSize(for image: NSImage) -> NSSize {
        guard image.size.width > 0,
              image.size.height > 0 else {
            return NSSize(width: 1, height: 1)
        }

        return image.size
    }

    private func aspectFillRect(for imageSize: NSSize, targetSize: NSSize) -> NSRect {
        let scale = max(targetSize.width / imageSize.width, targetSize.height / imageSize.height)
        let width = imageSize.width * scale
        let height = imageSize.height * scale

        return NSRect(
            x: (targetSize.width - width) / 2,
            y: (targetSize.height - height) / 2,
            width: width,
            height: height
        )
    }

    private func openScreenCapturePrivacySettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") else {
            return
        }

        NSWorkspace.shared.open(url)
    }
}
