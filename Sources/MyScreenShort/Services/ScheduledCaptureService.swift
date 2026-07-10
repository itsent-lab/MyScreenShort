import AppKit

final class ScheduledCaptureService {
    private let screenshotService: ScreenshotService
    private let regionStore: ScheduledCaptureRegionStore
    private let countdownController = ScheduledCaptureCountdownController()

    private(set) var isPending = false {
        didSet { onPendingStateChanged?(isPending) }
    }
    var onPendingStateChanged: ((Bool) -> Void)?

    init(
        screenshotService: ScreenshotService,
        regionStore: ScheduledCaptureRegionStore = .shared
    ) {
        self.screenshotService = screenshotService
        self.regionStore = regionStore
    }

    var lastRegion: ScheduledCaptureRegion? {
        regionStore.load()
    }

    func selectRegion(
        completion: @escaping (Result<ScheduledCaptureSelection, Error>) -> Void
    ) {
        screenshotService.selectScheduledRegion { [weak self] result in
            if case .success(let selection) = result {
                self?.regionStore.save(selection.region)
            }
            completion(result)
        }
    }

    func schedule(
        region: ScheduledCaptureRegion,
        delay: Int,
        onTick: @escaping (Int) -> Void,
        completion: @escaping (Result<ScreenshotCapture, Error>) -> Void
    ) {
        cancel()
        guard region.isAvailable else {
            completion(.failure(ScreenshotError.displayUnavailable))
            return
        }

        isPending = true
        let started = countdownController.start(
            region: region,
            seconds: delay,
            onTick: onTick,
            onReady: { [weak self] in
                guard let self else { return }
                self.screenshotService.captureScheduledRegion(region) { result in
                    self.isPending = false
                    completion(result)
                }
            }
        )

        if !started {
            isPending = false
            completion(.failure(ScreenshotError.displayUnavailable))
        }
    }

    func cancel() {
        countdownController.cancel()
        if isPending { isPending = false }
    }
}

private final class ScheduledCaptureCountdownController {
    private var panel: ScheduledCaptureBorderPanel?
    private var timer: Timer?
    private var deadline: Date?
    private var lastDisplayedSecond = -1
    private var onTick: ((Int) -> Void)?
    private var onReady: (() -> Void)?
    private var readyWorkItem: DispatchWorkItem?

    func start(
        region: ScheduledCaptureRegion,
        seconds: Int,
        onTick: @escaping (Int) -> Void,
        onReady: @escaping () -> Void
    ) -> Bool {
        cancel()
        guard let screen = region.screen else { return false }

        let globalRect = region.rect.offsetBy(
            dx: screen.frame.minX,
            dy: screen.frame.minY
        )
        let borderInset: CGFloat = 4
        let panelFrame = globalRect.insetBy(dx: -borderInset, dy: -borderInset)
        let panel = ScheduledCaptureBorderPanel(contentRect: panelFrame)
        let borderView = ScheduledCaptureBorderView(frame: CGRect(origin: .zero, size: panelFrame.size))
        panel.contentView = borderView
        panel.orderFrontRegardless()
        self.panel = panel
        self.deadline = Date().addingTimeInterval(TimeInterval(seconds))
        self.onTick = onTick
        self.onReady = onReady
        lastDisplayedSecond = -1

        updateCountdown()
        let timer = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
            self?.updateCountdown()
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        return true
    }

    func cancel() {
        readyWorkItem?.cancel()
        readyWorkItem = nil
        timer?.invalidate()
        timer = nil
        deadline = nil
        panel?.orderOut(nil)
        panel = nil
        onTick = nil
        onReady = nil
        lastDisplayedSecond = -1
    }

    private func updateCountdown() {
        guard let deadline else { return }
        let remaining = max(0, Int(ceil(deadline.timeIntervalSinceNow)))
        if remaining != lastDisplayedSecond {
            lastDisplayedSecond = remaining
            (panel?.contentView as? ScheduledCaptureBorderView)?.remainingSeconds = remaining
            onTick?(remaining)
        }

        guard remaining == 0 else { return }
        timer?.invalidate()
        timer = nil
        self.deadline = nil
        panel?.orderOut(nil)
        panel = nil
        let ready = onReady
        onReady = nil
        onTick = nil

        // WindowServer가 클릭 통과 테두리를 화면에서 완전히 제거한 다음 캡처한다.
        let workItem = DispatchWorkItem { [weak self] in
            self?.readyWorkItem = nil
            ready?()
        }
        readyWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: workItem)
    }
}

private final class ScheduledCaptureBorderPanel: NSPanel {
    init(contentRect: CGRect) {
        super.init(
            contentRect: contentRect,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        ignoresMouseEvents = true
        hidesOnDeactivate = false
        level = .screenSaver
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

private final class ScheduledCaptureBorderView: NSView {
    var remainingSeconds = 0 {
        didSet { needsDisplay = true }
    }

    override var isOpaque: Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        let borderRect = bounds.insetBy(dx: 2, dy: 2)
        let borderPath = NSBezierPath(roundedRect: borderRect, xRadius: 4, yRadius: 4)
        borderPath.lineWidth = 3
        NSColor.systemOrange.setStroke()
        borderPath.stroke()

        let label = "\(remainingSeconds)초 후 자동 캡처"
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 13, weight: .semibold),
            .foregroundColor: NSColor.white
        ]
        let textSize = label.size(withAttributes: attributes)
        let labelRect = CGRect(
            x: 10,
            y: max(8, bounds.height - textSize.height - 18),
            width: textSize.width + 16,
            height: textSize.height + 8
        )
        NSColor.black.withAlphaComponent(0.72).setFill()
        NSBezierPath(roundedRect: labelRect, xRadius: 6, yRadius: 6).fill()
        label.draw(
            at: CGPoint(x: labelRect.minX + 8, y: labelRect.minY + 4),
            withAttributes: attributes
        )
    }
}
