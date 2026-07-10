import AppKit

enum SelectionOverlayPurpose {
    case immediateCapture
    case scheduledRegion

    var allowsFullScreen: Bool { self == .immediateCapture }
    var allowsAnnotations: Bool { self == .immediateCapture }
}

final class SelectionOverlayController {
    private var windows: [SelectionOverlayWindow] = []
    private var overlayViews: [SelectionOverlayView] = []
    private var completion: ((Result<ScreenSelection, Error>) -> Void)?
    private var keyDownMonitor: Any?
    private var didFinish = false
    private var captureSettings = CapturePreferences.shared.load()
    private weak var activeOverlayView: SelectionOverlayView?

    func start(
        snapshots: [ScreenSnapshot],
        purpose: SelectionOverlayPurpose = .immediateCapture,
        completion: @escaping (Result<ScreenSelection, Error>) -> Void
    ) {
        self.completion = completion
        didFinish = false

        NSCursor.crosshair.push()
        keyDownMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if NSApp.keyWindow?.firstResponder is NSTextView {
                return event
            }

            if event.keyCode == 53 {
                self?.finish(.failure(ScreenshotError.captureCancelled))
                return nil
            }

            return event
        }

        overlayViews.removeAll()
        windows = snapshots.map { snapshot in
            let window = SelectionOverlayWindow(screen: snapshot.screen)
            var view: SelectionOverlayView!
            view = SelectionOverlayView(
                snapshot: snapshot,
                settings: captureSettings,
                purpose: purpose,
                onActivate: { [weak self, weak view] in
                    guard let view else { return }
                    self?.activateToolbar(on: view)
                },
                onSettingsChanged: { [weak self] settings in
                    self?.updateCaptureSettings(settings)
                },
                onFinish: { [weak self] selection in
                    self?.finish(.success(selection))
                },
                onCancel: { [weak self] in
                    self?.finish(.failure(ScreenshotError.captureCancelled))
                }
            )
            window.contentView = view
            window.makeKeyAndOrderFront(nil)
            window.makeFirstResponder(view)
            overlayViews.append(view)
            return window
        }

        let mouseLocation = NSEvent.mouseLocation
        let activeView = overlayViews.first { $0.screenFrame.contains(mouseLocation) }
            ?? overlayViews.first
        if let activeView {
            activateToolbar(on: activeView)
        }

        NSApp.activate(ignoringOtherApps: true)
    }

    private func activateToolbar(on activeView: SelectionOverlayView) {
        guard activeOverlayView !== activeView else { return }
        activeOverlayView = activeView
        overlayViews.forEach { view in
            view.setToolbarVisible(view === activeView)
        }
        activeView.activateForInput()
    }

    private func updateCaptureSettings(_ settings: CaptureSettings) {
        captureSettings = settings
        CapturePreferences.shared.save(settings)
        overlayViews.forEach { $0.applyCaptureSettings(settings) }
    }

    private func finish(_ result: Result<ScreenSelection, Error>) {
        guard !didFinish else {
            return
        }

        didFinish = true
        windows.forEach { $0.orderOut(nil) }
        windows.removeAll()
        overlayViews.removeAll()
        activeOverlayView = nil
        if let keyDownMonitor {
            NSEvent.removeMonitor(keyDownMonitor)
            self.keyDownMonitor = nil
        }
        NSCursor.pop()
        completion?(result)
        completion = nil
    }
}

final class SelectionOverlayWindow: NSWindow {
    init(screen: NSScreen) {
        super.init(
            contentRect: screen.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )

        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        ignoresMouseEvents = false
        level = .screenSaver
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
    }

    override var canBecomeKey: Bool {
        true
    }
}

private enum ScreenshotCaptureMode {
    case fullScreen
    case selection
}

final class SelectionOverlayView: NSView, NSTextFieldDelegate {
    private enum DragMode {
        case none
        case drawing
        case moving
        case resizing(ResizeHandle)
    }

    private enum ResizeHandle: CaseIterable {
        case topLeft
        case top
        case topRight
        case right
        case bottomRight
        case bottom
        case bottomLeft
        case left
    }

    private let snapshot: ScreenSnapshot
    private let snapshotImage: NSImage
    private let purpose: SelectionOverlayPurpose
    private let onActivate: () -> Void
    private let onSettingsChanged: (CaptureSettings) -> Void
    private let onFinish: (ScreenSelection) -> Void
    private let onCancel: () -> Void
    private let minimumSelectionSize: CGFloat = 8
    private let handleSize: CGFloat = 10
    private let handleHitSize: CGFloat = 18
    private var dragStartPoint: CGPoint?
    private var dragStartRect: CGRect?
    private var currentPoint: CGPoint?
    private var selectionRect: CGRect?
    private var dragMode: DragMode = .none
    private var captureMode: ScreenshotCaptureMode = .selection
    private var captureSettings: CaptureSettings
    private var scheduledDelay = 5
    private var annotations: [ScreenAnnotation] = []
    private var annotationHistory: [[ScreenAnnotation]] = [[]]
    private var annotationHistoryIndex = 0
    private var activeAnnotationIndex: Int?
    private var annotationTool: AnnotationTool?
    private var annotationStartPoint: CGPoint?
    private var eraserDidChange = false
    private var textEntryField: NSTextField?
    private var textEntryOrigin: CGPoint?
    private var isCancellingTextEntry = false
    private lazy var toolbarView = ScreenshotToolbarView(
        mode: captureMode,
        settings: captureSettings,
        purpose: purpose,
        scheduledDelay: scheduledDelay,
        onModeChanged: { [weak self] mode in
            self?.changeCaptureMode(to: mode)
        },
        onAnnotationToolChanged: { [weak self] tool in
            self?.changeAnnotationTool(to: tool)
        },
        onUndo: { [weak self] in
            self?.undoAnnotation()
        },
        onRedo: { [weak self] in
            self?.redoAnnotation()
        },
        onClear: { [weak self] in
            self?.clearAllAnnotations()
        },
        onSettingsChanged: { [weak self] settings in
            self?.applyCaptureSettings(settings)
            self?.onSettingsChanged(settings)
        },
        onScheduledDelayChanged: { [weak self] delay in
            self?.scheduledDelay = delay
        },
        onCapture: { [weak self] in
            self?.finishSelection()
        },
        onCancel: { [weak self] in
            self?.onCancel()
        }
    )

    init(
        snapshot: ScreenSnapshot,
        settings: CaptureSettings,
        purpose: SelectionOverlayPurpose,
        onActivate: @escaping () -> Void,
        onSettingsChanged: @escaping (CaptureSettings) -> Void,
        onFinish: @escaping (ScreenSelection) -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.snapshot = snapshot
        snapshotImage = NSImage(cgImage: snapshot.image, size: snapshot.screen.frame.size)
        self.purpose = purpose
        captureSettings = settings
        self.onActivate = onActivate
        self.onSettingsChanged = onSettingsChanged
        self.onFinish = onFinish
        self.onCancel = onCancel
        super.init(frame: NSRect(origin: .zero, size: snapshot.screen.frame.size))
        wantsLayer = true
        addSubview(toolbarView)
        toolbarView.setCaptureEnabled(false)
    }

    var screenFrame: CGRect { snapshot.screen.frame }

    func setToolbarVisible(_ isVisible: Bool) {
        toolbarView.isHidden = !isVisible
    }

    func activateForInput() {
        window?.makeKey()
        window?.makeFirstResponder(self)
    }

    func applyCaptureSettings(_ settings: CaptureSettings) {
        captureSettings = settings
        toolbarView.setSettings(settings)
    }

    required init?(coder: NSCoder) {
        nil
    }

    override var acceptsFirstResponder: Bool {
        true
    }

    override func layout() {
        super.layout()

        let toolbarSize = toolbarView.fittingSize
        let horizontalMargin: CGFloat = 20
        let width = min(toolbarSize.width, max(0, bounds.width - horizontalMargin * 2))
        toolbarView.frame = CGRect(
            x: bounds.midX - width / 2,
            y: bounds.minY + 34,
            width: width,
            height: toolbarSize.height
        )
    }

    override func resetCursorRects() {
        let cursor: NSCursor = annotationTool != nil || captureMode == .selection ? .crosshair : .arrow
        addCursorRect(bounds, cursor: cursor)
    }

    override func mouseMoved(with event: NSEvent) {
        onActivate()
        currentPoint = clampedPoint(event.locationInWindow)
        updateCursor(at: currentPoint)
        needsDisplay = true
    }

    override func mouseDown(with event: NSEvent) {
        onActivate()
        if let annotationTool {
            handleAnnotationMouseDown(
                tool: annotationTool,
                point: clampedPoint(event.locationInWindow)
            )
            return
        }

        guard captureMode == .selection else {
            return
        }

        let point = clampedPoint(event.locationInWindow)
        currentPoint = point

        if event.clickCount >= 2,
           let selectionRect,
           selectionRect.contains(point) {
            finishSelection()
            return
        }

        dragStartPoint = point
        dragStartRect = selectionRect

        if let selectionRect {
            if let handle = resizeHandle(at: point, in: selectionRect) {
                dragMode = .resizing(handle)
            } else if selectionRect.contains(point) {
                dragMode = .moving
                NSCursor.closedHand.set()
            } else {
                dragMode = .drawing
                resetAnnotationHistory()
                self.selectionRect = CGRect(origin: point, size: .zero)
            }
        } else {
            dragMode = .drawing
            resetAnnotationHistory()
            selectionRect = CGRect(origin: point, size: .zero)
        }

        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        if let annotationTool {
            handleAnnotationMouseDragged(
                tool: annotationTool,
                point: clampedPoint(event.locationInWindow)
            )
            return
        }

        guard captureMode == .selection else {
            return
        }

        let point = clampedPoint(event.locationInWindow)
        currentPoint = point

        guard let dragStartPoint else {
            return
        }

        switch dragMode {
        case .drawing:
            selectionRect = normalizedRect(from: dragStartPoint, to: point)
        case .moving:
            if let dragStartRect {
                let offset = CGPoint(
                    x: point.x - dragStartPoint.x,
                    y: point.y - dragStartPoint.y
                )
                selectionRect = constrainedRect(dragStartRect.offsetBy(dx: offset.x, dy: offset.y))
            }
        case .resizing(let handle):
            if let dragStartRect {
                selectionRect = resizedRect(dragStartRect, handle: handle, to: point)
            }
        case .none:
            break
        }

        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        if let annotationTool {
            handleAnnotationMouseUp(
                tool: annotationTool,
                point: clampedPoint(event.locationInWindow)
            )
            return
        }

        guard captureMode == .selection else {
            return
        }

        currentPoint = clampedPoint(event.locationInWindow)

        if let rect = selectionRect,
           (rect.width < minimumSelectionSize || rect.height < minimumSelectionSize) {
            selectionRect = nil
        }

        dragMode = .none
        dragStartPoint = nil
        dragStartRect = nil
        updateCursor(at: currentPoint)
        updateCaptureButton()
        needsDisplay = true
    }

    override func keyDown(with event: NSEvent) {
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if event.keyCode == 6, modifiers.contains(.command) {
            modifiers.contains(.shift) ? redoAnnotation() : undoAnnotation()
            return
        }

        if event.keyCode == 53 {
            onCancel()
            return
        }

        if event.keyCode == 36 || event.keyCode == 76 {
            finishSelection()
            return
        }

        if event.keyCode == 18 {
            if purpose.allowsFullScreen {
                changeCaptureMode(to: .fullScreen)
            }
            return
        }

        if event.keyCode == 19 {
            changeCaptureMode(to: .selection)
            return
        }

        if modifiers.isEmpty, purpose.allowsAnnotations {
            switch event.keyCode {
            case 35: changeAnnotationTool(to: .pen)
            case 0: changeAnnotationTool(to: .arrow)
            case 15: changeAnnotationTool(to: .rectangle)
            case 17: changeAnnotationTool(to: .text)
            case 14: changeAnnotationTool(to: .eraser)
            default:
                super.keyDown(with: event)
            }
            return
        }

        super.keyDown(with: event)
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        snapshotImage.draw(in: bounds, from: .zero, operation: .copy, fraction: 1)

        NSColor.black.withAlphaComponent(0.22).setFill()
        dimmedRects(around: selectionRect).forEach { $0.fill() }

        if captureMode == .selection,
           let point = currentPoint,
           selectionRect == nil {
            drawGuideLines(at: point)
        }

        guard let selectionRect else {
            return
        }

        NSColor.systemBlue.withAlphaComponent(0.16).setFill()
        selectionRect.fill()

        drawAnnotations(clippedTo: selectionRect)

        let borderPath = NSBezierPath(rect: selectionRect)
        borderPath.lineWidth = 2
        NSColor.systemBlue.setStroke()
        borderPath.stroke()

        if captureMode == .selection {
            drawResizeHandles(for: selectionRect)
            drawSizeLabel(for: selectionRect)
        }
    }

    private func changeCaptureMode(to mode: ScreenshotCaptureMode) {
        guard mode != .fullScreen || purpose.allowsFullScreen else { return }
        captureMode = mode
        annotationTool = nil
        dragMode = .none
        dragStartPoint = nil
        dragStartRect = nil
        cancelTextEntry()
        resetAnnotationHistory()

        switch mode {
        case .fullScreen:
            selectionRect = bounds
            currentPoint = nil
        case .selection:
            selectionRect = nil
        }

        toolbarView.setMode(mode)
        toolbarView.setAnnotationTool(nil)
        updateCaptureButton()
        window?.invalidateCursorRects(for: self)
        updateCursor(at: currentPoint)
        needsDisplay = true
    }

    private func updateCaptureButton() {
        let isEnabled: Bool
        switch captureMode {
        case .fullScreen:
            isEnabled = true
        case .selection:
            isEnabled = selectionRect.map {
                $0.width >= minimumSelectionSize && $0.height >= minimumSelectionSize
            } ?? false
        }
        toolbarView.setCaptureEnabled(isEnabled)
        toolbarView.setAnnotationToolsEnabled(isEnabled && purpose.allowsAnnotations)
    }

    private var currentAnnotationStyle: AnnotationStyle {
        AnnotationStyle(
            color: captureSettings.annotationColor,
            lineWidth: captureSettings.annotationWidth
        )
    }

    private func changeAnnotationTool(to tool: AnnotationTool?) {
        guard purpose.allowsAnnotations else { return }
        guard tool == nil || selectionRect != nil else {
            toolbarView.setAnnotationTool(nil)
            return
        }

        cancelTextEntry()
        annotationTool = annotationTool == tool ? nil : tool
        activeAnnotationIndex = nil
        annotationStartPoint = nil
        toolbarView.setAnnotationTool(annotationTool)
        window?.invalidateCursorRects(for: self)
        updateCursor(at: currentPoint)
    }

    private func handleAnnotationMouseDown(tool: AnnotationTool, point: CGPoint) {
        guard let selectionRect, selectionRect.contains(point) else { return }
        let style = currentAnnotationStyle
        annotationStartPoint = point

        switch tool {
        case .pen:
            annotations.append(.stroke(points: [point], style: style))
            activeAnnotationIndex = annotations.indices.last
        case .arrow:
            annotations.append(.arrow(start: point, end: point, style: style))
            activeAnnotationIndex = annotations.indices.last
        case .rectangle:
            annotations.append(.rectangle(rect: CGRect(origin: point, size: .zero), style: style))
            activeAnnotationIndex = annotations.indices.last
        case .text:
            beginTextEntry(at: point)
        case .eraser:
            eraserDidChange = false
            eraseAnnotation(at: point)
        }
        needsDisplay = true
    }

    private func handleAnnotationMouseDragged(tool: AnnotationTool, point: CGPoint) {
        guard let selectionRect else { return }
        let clamped = clampedPoint(point, to: selectionRect)

        switch tool {
        case .pen:
            guard let index = activeAnnotationIndex,
                  case .stroke(var points, let style) = annotations[index] else { return }
            points.append(clamped)
            annotations[index] = .stroke(points: points, style: style)
        case .arrow:
            guard let index = activeAnnotationIndex,
                  case .arrow(let start, _, let style) = annotations[index] else { return }
            annotations[index] = .arrow(start: start, end: clamped, style: style)
        case .rectangle:
            guard let index = activeAnnotationIndex,
                  let start = annotationStartPoint,
                  case .rectangle(_, let style) = annotations[index] else { return }
            annotations[index] = .rectangle(
                rect: normalizedRect(from: start, to: clamped),
                style: style
            )
        case .eraser:
            eraseAnnotation(at: clamped)
        case .text:
            return
        }
        needsDisplay = true
    }

    private func handleAnnotationMouseUp(tool: AnnotationTool, point: CGPoint) {
        handleAnnotationMouseDragged(tool: tool, point: point)
        switch tool {
        case .pen, .arrow, .rectangle:
            if let index = activeAnnotationIndex {
                switch annotations[index] {
                case .arrow(let start, let end, _)
                    where hypot(end.x - start.x, end.y - start.y) < 3:
                    annotations.remove(at: index)
                case .rectangle(let rect, _)
                    where rect.width < 3 || rect.height < 3:
                    annotations.remove(at: index)
                default:
                    break
                }
            }
            activeAnnotationIndex = nil
            annotationStartPoint = nil
            commitAnnotationHistory()
        case .eraser:
            if eraserDidChange { commitAnnotationHistory() }
            eraserDidChange = false
        case .text:
            break
        }
        needsDisplay = true
    }

    private func eraseAnnotation(at point: CGPoint) {
        guard let index = annotations.lastIndex(where: { $0.hitTest(point) }) else { return }
        annotations.remove(at: index)
        eraserDidChange = true
        needsDisplay = true
    }

    private func undoAnnotation() {
        guard annotationHistoryIndex > 0 else { return }
        cancelTextEntry()
        annotationHistoryIndex -= 1
        annotations = annotationHistory[annotationHistoryIndex]
        updateHistoryButtons()
        needsDisplay = true
    }

    private func redoAnnotation() {
        guard annotationHistoryIndex + 1 < annotationHistory.count else { return }
        cancelTextEntry()
        annotationHistoryIndex += 1
        annotations = annotationHistory[annotationHistoryIndex]
        updateHistoryButtons()
        needsDisplay = true
    }

    private func clearAllAnnotations() {
        guard !annotations.isEmpty else { return }
        cancelTextEntry()
        annotations.removeAll()
        commitAnnotationHistory()
        needsDisplay = true
    }

    private func commitAnnotationHistory() {
        if annotationHistoryIndex + 1 < annotationHistory.count {
            annotationHistory.removeSubrange((annotationHistoryIndex + 1)...)
        }
        guard annotationHistory.last != annotations else {
            updateHistoryButtons()
            return
        }
        annotationHistory.append(annotations)
        annotationHistoryIndex = annotationHistory.count - 1
        updateHistoryButtons()
    }

    private func resetAnnotationHistory() {
        annotations.removeAll()
        activeAnnotationIndex = nil
        annotationStartPoint = nil
        annotationHistory = [[]]
        annotationHistoryIndex = 0
        updateHistoryButtons()
    }

    private func updateHistoryButtons() {
        toolbarView.setUndoEnabled(annotationHistoryIndex > 0)
        toolbarView.setRedoEnabled(annotationHistoryIndex + 1 < annotationHistory.count)
        toolbarView.setClearEnabled(!annotations.isEmpty)
    }

    private func drawAnnotations(clippedTo rect: CGRect) {
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(rect: rect).addClip()
        annotations.forEach { $0.draw() }
        NSGraphicsContext.restoreGraphicsState()
    }

    private func beginTextEntry(at point: CGPoint) {
        cancelTextEntry()
        guard let selectionRect else { return }

        let width = min(240, max(110, selectionRect.maxX - point.x))
        let origin = CGPoint(
            x: min(point.x, selectionRect.maxX - width),
            y: min(point.y, selectionRect.maxY - 28)
        )
        let field = NSTextField(frame: CGRect(origin: origin, size: CGSize(width: width, height: 28)))
        field.placeholderString = "표시할 텍스트"
        field.font = .systemFont(ofSize: 18, weight: .semibold)
        field.textColor = captureSettings.annotationColor.color
        field.backgroundColor = NSColor.windowBackgroundColor.withAlphaComponent(0.94)
        field.isBezeled = true
        field.bezelStyle = .roundedBezel
        field.delegate = self
        textEntryField = field
        textEntryOrigin = origin
        addSubview(field, positioned: .above, relativeTo: nil)
        window?.makeFirstResponder(field)
    }

    private func finishTextEntry(commit: Bool) {
        guard let field = textEntryField else { return }
        let text = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let origin = textEntryOrigin ?? field.frame.origin
        field.delegate = nil
        field.removeFromSuperview()
        textEntryField = nil
        textEntryOrigin = nil
        window?.makeFirstResponder(self)

        if commit, !text.isEmpty {
            annotations.append(.text(origin: origin, text: text, style: currentAnnotationStyle))
            commitAnnotationHistory()
            needsDisplay = true
        }
    }

    private func cancelTextEntry() {
        finishTextEntry(commit: false)
    }

    func controlTextDidEndEditing(_ notification: Notification) {
        finishTextEntry(commit: !isCancellingTextEntry)
        isCancellingTextEntry = false
    }

    func control(
        _ control: NSControl,
        textView: NSTextView,
        doCommandBy commandSelector: Selector
    ) -> Bool {
        if commandSelector == #selector(NSResponder.insertNewline(_:)) {
            finishTextEntry(commit: true)
            return true
        }
        if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
            isCancellingTextEntry = true
            finishTextEntry(commit: false)
            isCancellingTextEntry = false
            return true
        }
        return false
    }

    private func finishSelection() {
        finishTextEntry(commit: true)
        guard let rect = selectionRect,
              rect.width >= minimumSelectionSize,
              rect.height >= minimumSelectionSize else {
            return
        }

        onFinish(
            ScreenSelection(
                snapshot: snapshot,
                rect: rect,
                annotations: annotations,
                destination: captureSettings.destination,
                outputDirectory: captureSettings.outputDirectory,
                scheduledDelay: purpose == .scheduledRegion ? scheduledDelay : nil
            )
        )
    }

    private func dimmedRects(around selectionRect: CGRect?) -> [CGRect] {
        guard let selectionRect else {
            return [bounds]
        }

        return [
            CGRect(
                x: bounds.minX,
                y: bounds.minY,
                width: bounds.width,
                height: max(0, selectionRect.minY - bounds.minY)
            ),
            CGRect(
                x: bounds.minX,
                y: selectionRect.maxY,
                width: bounds.width,
                height: max(0, bounds.maxY - selectionRect.maxY)
            ),
            CGRect(
                x: bounds.minX,
                y: selectionRect.minY,
                width: max(0, selectionRect.minX - bounds.minX),
                height: selectionRect.height
            ),
            CGRect(
                x: selectionRect.maxX,
                y: selectionRect.minY,
                width: max(0, bounds.maxX - selectionRect.maxX),
                height: selectionRect.height
            )
        ]
    }

    private func normalizedRect(from startPoint: CGPoint, to currentPoint: CGPoint) -> CGRect {
        CGRect(
            x: min(startPoint.x, currentPoint.x),
            y: min(startPoint.y, currentPoint.y),
            width: abs(startPoint.x - currentPoint.x),
            height: abs(startPoint.y - currentPoint.y)
        )
    }

    private func constrainedRect(_ rect: CGRect) -> CGRect {
        let width = min(rect.width, bounds.width)
        let height = min(rect.height, bounds.height)
        let x = min(max(rect.minX, bounds.minX), bounds.maxX - width)
        let y = min(max(rect.minY, bounds.minY), bounds.maxY - height)

        return CGRect(x: x, y: y, width: width, height: height)
    }

    private func resizedRect(_ rect: CGRect, handle: ResizeHandle, to point: CGPoint) -> CGRect {
        var minX = rect.minX
        var maxX = rect.maxX
        var minY = rect.minY
        var maxY = rect.maxY

        switch handle {
        case .topLeft:
            minX = point.x
            maxY = point.y
        case .top:
            maxY = point.y
        case .topRight:
            maxX = point.x
            maxY = point.y
        case .right:
            maxX = point.x
        case .bottomRight:
            maxX = point.x
            minY = point.y
        case .bottom:
            minY = point.y
        case .bottomLeft:
            minX = point.x
            minY = point.y
        case .left:
            minX = point.x
        }

        if abs(maxX - minX) < minimumSelectionSize {
            switch handle {
            case .topLeft, .bottomLeft, .left:
                minX = maxX - minimumSelectionSize
            case .topRight, .bottomRight, .right:
                maxX = minX + minimumSelectionSize
            case .top, .bottom:
                break
            }
        }

        if abs(maxY - minY) < minimumSelectionSize {
            switch handle {
            case .bottomLeft, .bottomRight, .bottom:
                minY = maxY - minimumSelectionSize
            case .topLeft, .topRight, .top:
                maxY = minY + minimumSelectionSize
            case .left, .right:
                break
            }
        }

        let normalized = CGRect(
            x: min(minX, maxX),
            y: min(minY, maxY),
            width: abs(maxX - minX),
            height: abs(maxY - minY)
        )

        return constrainedRect(normalized)
    }

    private func clampedPoint(_ point: CGPoint) -> CGPoint {
        CGPoint(
            x: min(max(point.x, bounds.minX), bounds.maxX),
            y: min(max(point.y, bounds.minY), bounds.maxY)
        )
    }

    private func clampedPoint(_ point: CGPoint, to rect: CGRect) -> CGPoint {
        CGPoint(
            x: min(max(point.x, rect.minX), rect.maxX),
            y: min(max(point.y, rect.minY), rect.maxY)
        )
    }

    private func resizeHandle(at point: CGPoint, in rect: CGRect) -> ResizeHandle? {
        ResizeHandle.allCases.first { handleRect(for: $0, in: rect, size: handleHitSize).contains(point) }
    }

    private func handleCenter(for handle: ResizeHandle, in rect: CGRect) -> CGPoint {
        switch handle {
        case .topLeft:
            return CGPoint(x: rect.minX, y: rect.maxY)
        case .top:
            return CGPoint(x: rect.midX, y: rect.maxY)
        case .topRight:
            return CGPoint(x: rect.maxX, y: rect.maxY)
        case .right:
            return CGPoint(x: rect.maxX, y: rect.midY)
        case .bottomRight:
            return CGPoint(x: rect.maxX, y: rect.minY)
        case .bottom:
            return CGPoint(x: rect.midX, y: rect.minY)
        case .bottomLeft:
            return CGPoint(x: rect.minX, y: rect.minY)
        case .left:
            return CGPoint(x: rect.minX, y: rect.midY)
        }
    }

    private func handleRect(for handle: ResizeHandle, in rect: CGRect, size: CGFloat) -> CGRect {
        let center = handleCenter(for: handle, in: rect)
        return CGRect(
            x: center.x - size / 2,
            y: center.y - size / 2,
            width: size,
            height: size
        )
    }

    private func updateCursor(at point: CGPoint?) {
        if annotationTool != nil {
            NSCursor.crosshair.set()
            return
        }

        guard captureMode == .selection else {
            NSCursor.arrow.set()
            return
        }

        guard let point,
              let selectionRect else {
            NSCursor.crosshair.set()
            return
        }

        if let handle = resizeHandle(at: point, in: selectionRect) {
            cursor(for: handle).set()
        } else if selectionRect.contains(point) {
            NSCursor.openHand.set()
        } else {
            NSCursor.crosshair.set()
        }
    }

    private func cursor(for handle: ResizeHandle) -> NSCursor {
        switch handle {
        case .left, .right:
            return .resizeLeftRight
        case .top, .bottom:
            return .resizeUpDown
        case .topLeft, .bottomRight, .topRight, .bottomLeft:
            return .crosshair
        }
    }

    private func drawGuideLines(at point: CGPoint) {
        let path = NSBezierPath()
        path.move(to: CGPoint(x: point.x, y: bounds.minY))
        path.line(to: CGPoint(x: point.x, y: bounds.maxY))
        path.move(to: CGPoint(x: bounds.minX, y: point.y))
        path.line(to: CGPoint(x: bounds.maxX, y: point.y))
        path.lineWidth = 1
        path.setLineDash([6, 4], count: 2, phase: 0)
        NSColor.white.withAlphaComponent(0.82).setStroke()
        path.stroke()
    }

    private func drawSizeLabel(for rect: CGRect) {
        let scaleX = CGFloat(snapshot.image.width) / snapshot.screen.frame.width
        let scaleY = CGFloat(snapshot.image.height) / snapshot.screen.frame.height
        let label = "\(Int(rect.width * scaleX)) x \(Int(rect.height * scaleY))  Enter 캡처  Esc 취소"
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 12, weight: .semibold),
            .foregroundColor: NSColor.white
        ]
        let textSize = label.size(withAttributes: attributes)
        let labelRect = CGRect(
            x: min(max(rect.minX, bounds.minX + 8), bounds.maxX - textSize.width - 18),
            y: max(rect.minY - textSize.height - 14, bounds.minY + 8),
            width: textSize.width + 10,
            height: textSize.height + 6
        )

        NSColor.black.withAlphaComponent(0.62).setFill()
        NSBezierPath(roundedRect: labelRect, xRadius: 5, yRadius: 5).fill()
        label.draw(
            at: CGPoint(x: labelRect.minX + 5, y: labelRect.minY + 3),
            withAttributes: attributes
        )
    }

    private func drawResizeHandles(for rect: CGRect) {
        NSColor.white.setFill()
        NSColor.systemBlue.setStroke()

        for handle in ResizeHandle.allCases {
            let handleRect = handleRect(for: handle, in: rect, size: handleSize)
            let path = NSBezierPath(roundedRect: handleRect, xRadius: 2, yRadius: 2)
            path.lineWidth = 1
            path.fill()
            path.stroke()
        }
    }
}

private final class ScreenshotToolbarHoverButton: NSButton {
    var hoverDescription = ""
    var onHoverChanged: ((String?) -> Void)?
    private var hoverTrackingArea: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverTrackingArea { removeTrackingArea(hoverTrackingArea) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.activeAlways, .mouseEnteredAndExited, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        hoverTrackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        onHoverChanged?(hoverDescription)
    }

    override func mouseExited(with event: NSEvent) {
        onHoverChanged?(nil)
    }
}

private final class ScreenshotToolbarView: NSVisualEffectView {
    private let onModeChanged: (ScreenshotCaptureMode) -> Void
    private let onAnnotationToolChanged: (AnnotationTool?) -> Void
    private let onUndo: () -> Void
    private let onRedo: () -> Void
    private let onClear: () -> Void
    private let onSettingsChanged: (CaptureSettings) -> Void
    private let onScheduledDelayChanged: (Int) -> Void
    private let onCapture: () -> Void
    private let onCancel: () -> Void
    private let purpose: SelectionOverlayPurpose
    private var mode: ScreenshotCaptureMode
    private var settings: CaptureSettings
    private var scheduledDelay: Int
    private var selectedTool: AnnotationTool?
    private lazy var helpLabel: NSTextField = {
        let label = NSTextField(labelWithString: defaultHelpText)
        label.font = .systemFont(ofSize: 11.5, weight: .medium)
        label.textColor = NSColor.white.withAlphaComponent(0.82)
        label.alignment = .center
        label.lineBreakMode = .byTruncatingTail
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return label
    }()

    private var defaultHelpText: String {
        switch purpose {
        case .immediateCapture:
            return "아이콘에 마우스를 올리면 설명 표시 · 예약 캡처: 상단 메뉴 막대 카메라 아이콘"
        case .scheduledRegion:
            return "영역 선택 + 3·5·10초 준비 시간 선택 → ‘예약 시작’ → 메뉴·팝업 열기"
        }
    }

    private lazy var closeButton = makeIconButton("xmark.circle.fill", "취소: 캡처 화면을 닫습니다 (Esc)", #selector(cancelCapture))
    private lazy var fullScreenButton = makeIconButton("rectangle", "전체 화면: 현재 모니터 전체를 캡처합니다 (1)", #selector(selectFullScreenMode))
    private lazy var selectionButton = makeIconButton("rectangle.dashed", "영역 선택: 드래그한 부분만 캡처합니다 (2)", #selector(selectSelectionMode))
    private lazy var penButton = makeToolButton(.pen, "pencil.tip", "펜: 선택 영역 위에 자유롭게 그립니다 (P)")
    private lazy var arrowButton = makeToolButton(.arrow, "arrow.up.right", "화살표: 강조할 방향을 드래그합니다 (A)")
    private lazy var rectangleButton = makeToolButton(.rectangle, "square", "사각형: 강조할 부분을 둘러쌉니다 (R)")
    private lazy var textButton = makeToolButton(.text, "textformat", "텍스트: 클릭한 위치에 설명을 입력합니다 (T)")
    private lazy var eraserButton = makeToolButton(.eraser, "eraser", "지우개: 표시를 클릭하거나 문질러 지웁니다 (E)")
    private lazy var undoButton = makeIconButton("arrow.uturn.backward", "실행 취소: 마지막 표시를 되돌립니다 (⌘Z)", #selector(undoAnnotation))
    private lazy var redoButton = makeIconButton("arrow.uturn.forward", "다시 실행: 취소한 표시를 복원합니다 (⇧⌘Z)", #selector(redoAnnotation))
    private lazy var clearButton = makeIconButton("trash", "전체 지우기: 모든 표시를 삭제합니다", #selector(clearAnnotations))

    private lazy var optionsButton: NSButton = {
        let button = ScreenshotToolbarHoverButton(frame: .zero)
        button.title = "옵션⌄"
        button.target = self
        button.action = #selector(showOptions)
        button.isBordered = false
        button.font = .systemFont(ofSize: 13, weight: .medium)
        button.contentTintColor = .white
        button.refusesFirstResponder = true
        button.setAccessibilityLabel("캡처 옵션")
        configureHover(
            button,
            description: "옵션: 저장 방식, 표시 색상·굵기, 저장 폴더를 선택합니다"
        )
        button.widthAnchor.constraint(equalToConstant: 104).isActive = true
        button.heightAnchor.constraint(equalToConstant: 42).isActive = true
        return button
    }()
    private lazy var captureButton: NSButton = {
        let button = ScreenshotToolbarHoverButton(frame: .zero)
        button.title = "캡처"
        button.target = self
        button.action = #selector(capture)
        button.isBordered = false
        button.font = .systemFont(ofSize: 13, weight: .semibold)
        button.contentTintColor = .white
        button.refusesFirstResponder = true
        button.wantsLayer = true
        button.layer?.cornerRadius = 9
        button.setAccessibilityLabel("캡처 실행")
        configureHover(button, description: "캡처: 현재 선택 영역을 저장·복사합니다 (Enter)")
        button.keyEquivalent = "\r"
        button.widthAnchor.constraint(equalToConstant: 78).isActive = true
        button.heightAnchor.constraint(equalToConstant: 42).isActive = true
        return button
    }()
    private lazy var scheduledDelayButton: NSPopUpButton = {
        let button = NSPopUpButton(frame: .zero, pullsDown: false)
        [3, 5, 10].forEach { delay in
            button.addItem(withTitle: "\(delay)초 준비")
            button.lastItem?.tag = delay
        }
        button.selectItem(withTag: scheduledDelay)
        button.target = self
        button.action = #selector(selectScheduledDelay(_:))
        button.font = .systemFont(ofSize: 12.5, weight: .medium)
        button.toolTip = "준비 시간: 영역 지정 후 자동 캡처까지 기다릴 시간"
        button.setAccessibilityLabel("예약 캡처 준비 시간")
        button.widthAnchor.constraint(equalToConstant: 100).isActive = true
        button.heightAnchor.constraint(equalToConstant: 32).isActive = true
        button.isHidden = purpose != .scheduledRegion
        return button
    }()
    private lazy var optionsMenu = makeOptionsMenu()

    private var toolButtons: [(AnnotationTool, NSButton)] {
        [
            (.pen, penButton), (.arrow, arrowButton), (.rectangle, rectangleButton),
            (.text, textButton), (.eraser, eraserButton)
        ]
    }

    init(
        mode: ScreenshotCaptureMode,
        settings: CaptureSettings,
        purpose: SelectionOverlayPurpose,
        scheduledDelay: Int,
        onModeChanged: @escaping (ScreenshotCaptureMode) -> Void,
        onAnnotationToolChanged: @escaping (AnnotationTool?) -> Void,
        onUndo: @escaping () -> Void,
        onRedo: @escaping () -> Void,
        onClear: @escaping () -> Void,
        onSettingsChanged: @escaping (CaptureSettings) -> Void,
        onScheduledDelayChanged: @escaping (Int) -> Void,
        onCapture: @escaping () -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.mode = mode
        self.settings = settings
        self.purpose = purpose
        self.scheduledDelay = scheduledDelay
        self.onModeChanged = onModeChanged
        self.onAnnotationToolChanged = onAnnotationToolChanged
        self.onUndo = onUndo
        self.onRedo = onRedo
        self.onClear = onClear
        self.onSettingsChanged = onSettingsChanged
        self.onScheduledDelayChanged = onScheduledDelayChanged
        self.onCapture = onCapture
        self.onCancel = onCancel
        super.init(frame: .zero)

        material = .hudWindow
        blendingMode = .withinWindow
        state = .active
        wantsLayer = true
        layer?.cornerRadius = 12
        layer?.masksToBounds = true

        let stackView = NSStackView(views: [
            closeButton, makeSeparator(), fullScreenButton, selectionButton, makeSeparator(),
            penButton, arrowButton, rectangleButton, textButton, eraserButton,
            undoButton, redoButton, clearButton, makeSeparator(), optionsButton,
            scheduledDelayButton, captureButton
        ])
        stackView.orientation = .horizontal
        stackView.alignment = .centerY
        stackView.spacing = 3
        stackView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stackView)
        helpLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(helpLabel)

        NSLayoutConstraint.activate([
            stackView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            stackView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -7),
            stackView.topAnchor.constraint(equalTo: topAnchor, constant: 7),
            stackView.heightAnchor.constraint(equalToConstant: 42),
            helpLabel.topAnchor.constraint(equalTo: stackView.bottomAnchor, constant: 3),
            helpLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            helpLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            helpLabel.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -6),
            heightAnchor.constraint(equalToConstant: 76)
        ])

        updateModeButtons()
        setAnnotationToolsEnabled(false)
        setUndoEnabled(false)
        setRedoEnabled(false)
        setClearEnabled(false)
        updateSettingsAppearance()
        configureForPurpose()
    }

    required init?(coder: NSCoder) { nil }

    func setMode(_ mode: ScreenshotCaptureMode) {
        self.mode = mode
        updateModeButtons()
    }

    func setSettings(_ settings: CaptureSettings) {
        self.settings = settings
        updateSettingsAppearance()
        updateOptionsMenuStates()
    }

    func setAnnotationTool(_ tool: AnnotationTool?) {
        selectedTool = tool
        toolButtons.forEach { update($0.1, isSelected: $0.0 == tool) }
    }

    func setAnnotationToolsEnabled(_ isEnabled: Bool) {
        let isEnabled = isEnabled && purpose.allowsAnnotations
        toolButtons.forEach { _, button in
            button.isEnabled = isEnabled
            button.alphaValue = isEnabled ? 1 : 0.35
        }
        if !isEnabled { setAnnotationTool(nil) }
    }

    func setUndoEnabled(_ enabled: Bool) { set(enabled, on: undoButton) }
    func setRedoEnabled(_ enabled: Bool) { set(enabled, on: redoButton) }
    func setClearEnabled(_ enabled: Bool) { set(enabled, on: clearButton) }

    func setCaptureEnabled(_ isEnabled: Bool) {
        captureButton.isEnabled = isEnabled
        captureButton.alphaValue = isEnabled ? 1 : 0.45
        captureButton.layer?.backgroundColor = isEnabled
            ? NSColor.controlAccentColor.cgColor
            : NSColor.controlAccentColor.withAlphaComponent(0.45).cgColor
    }

    private func makeIconButton(_ symbolName: String, _ label: String, _ action: Selector) -> NSButton {
        let button = ScreenshotToolbarHoverButton(frame: .zero)
        button.target = self
        button.action = action
        let symbol = NSImage(systemSymbolName: symbolName, accessibilityDescription: label)
        button.image = symbol?.withSymbolConfiguration(
            NSImage.SymbolConfiguration(pointSize: 19, weight: .regular)
        )
        button.imagePosition = .imageOnly
        button.isBordered = false
        button.refusesFirstResponder = true
        button.contentTintColor = .white
        button.wantsLayer = true
        button.layer?.cornerRadius = 8
        button.setAccessibilityLabel(label)
        button.toolTip = label
        configureHover(button, description: label)
        button.widthAnchor.constraint(equalToConstant: 40).isActive = true
        button.heightAnchor.constraint(equalToConstant: 42).isActive = true
        return button
    }

    private func configureHover(_ button: NSButton, description: String) {
        guard let button = button as? ScreenshotToolbarHoverButton else { return }
        button.hoverDescription = description
        button.onHoverChanged = { [weak self] description in
            self?.helpLabel.stringValue = description ?? self?.defaultHelpText ?? ""
        }
    }

    private func makeToolButton(_ tool: AnnotationTool, _ symbol: String, _ label: String) -> NSButton {
        let button = makeIconButton(symbol, label, #selector(selectAnnotationTool(_:)))
        button.tag = tool.rawValue
        return button
    }

    private func makeSeparator() -> NSBox {
        let separator = NSBox()
        separator.boxType = .separator
        separator.widthAnchor.constraint(equalToConstant: 1).isActive = true
        separator.heightAnchor.constraint(equalToConstant: 28).isActive = true
        return separator
    }

    private func makeOptionsMenu() -> NSMenu {
        let menu = NSMenu(title: "캡처 옵션")
        menu.autoenablesItems = false
        [("파일 저장 + 클립보드 복사", CaptureDestination.saveAndCopy),
         ("파일 저장만", CaptureDestination.saveOnly),
         ("클립보드 복사만", CaptureDestination.copyOnly)].forEach { title, destination in
            let item = NSMenuItem(title: title, action: #selector(selectDestination(_:)), keyEquivalent: "")
            item.target = self
            item.tag = destination.rawValue
            item.isEnabled = true
            menu.addItem(item)
        }

        let colorMenu = NSMenu(title: "표시 색상")
        colorMenu.autoenablesItems = false
        AnnotationColor.allCases.forEach { color in
            let item = NSMenuItem(title: color.title, action: #selector(selectAnnotationColor(_:)), keyEquivalent: "")
            item.target = self
            item.tag = color.rawValue
            item.isEnabled = true
            colorMenu.addItem(item)
        }
        let colorItem = NSMenuItem(title: "표시 색상", action: nil, keyEquivalent: "")
        colorItem.submenu = colorMenu

        let widthMenu = NSMenu(title: "선 굵기")
        widthMenu.autoenablesItems = false
        [("얇게", 3), ("보통", 5), ("굵게", 9)].forEach { title, width in
            let item = NSMenuItem(title: title, action: #selector(selectAnnotationWidth(_:)), keyEquivalent: "")
            item.target = self
            item.tag = width
            item.isEnabled = true
            widthMenu.addItem(item)
        }
        let widthItem = NSMenuItem(title: "선 굵기", action: nil, keyEquivalent: "")
        widthItem.submenu = widthMenu

        let chooseFolder = NSMenuItem(title: "저장 폴더 선택…", action: #selector(chooseOutputDirectory), keyEquivalent: "")
        chooseFolder.target = self
        chooseFolder.isEnabled = true
        let locationItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        locationItem.tag = 900
        locationItem.isEnabled = false

        menu.addItem(.separator())
        menu.addItem(colorItem)
        menu.addItem(widthItem)
        menu.addItem(.separator())
        menu.addItem(chooseFolder)
        menu.addItem(locationItem)
        updateOptionsMenuStates(menu)
        return menu
    }

    private func updateModeButtons() {
        update(fullScreenButton, isSelected: mode == .fullScreen)
        update(selectionButton, isSelected: mode == .selection)
    }

    private func configureForPurpose() {
        guard purpose == .scheduledRegion else { return }
        fullScreenButton.isHidden = true
        toolButtons.forEach { $0.1.isHidden = true }
        undoButton.isHidden = true
        redoButton.isHidden = true
        clearButton.isHidden = true
        optionsButton.isHidden = true
        captureButton.title = "예약 시작"
        selectionButton.toolTip = "예약 캡처 영역 선택"
        configureHover(selectionButton, description: "예약 캡처할 영역을 마우스로 드래그합니다")
        configureHover(captureButton, description: "예약 시작: 선택한 준비 시간 뒤 현재 영역을 자동 캡처합니다")
    }

    private func updateSettingsAppearance() {
        let tint = settings.annotationColor.color
        [penButton, arrowButton, rectangleButton, textButton].forEach { $0.contentTintColor = tint }
        penButton.toolTip = "펜 (P) · \(settings.annotationColor.title) · \(Int(settings.annotationWidth))pt"
        configureHover(
            penButton,
            description: "펜: 자유롭게 그립니다 · \(settings.annotationColor.title) · \(Int(settings.annotationWidth))pt (P)"
        )
        let optionTitle = NSMutableAttributedString(
            string: "●",
            attributes: [
                .font: NSFont.systemFont(ofSize: 14, weight: .bold),
                .foregroundColor: tint
            ]
        )
        optionTitle.append(
            NSAttributedString(
                string: " \(Int(settings.annotationWidth))pt 옵션⌄",
                attributes: [
                    .font: NSFont.systemFont(ofSize: 12, weight: .medium),
                    .foregroundColor: NSColor.white
                ]
            )
        )
        optionsButton.attributedTitle = optionTitle
        optionsButton.toolTip = settings.outputDirectory.path
    }

    private func updateOptionsMenuStates(_ suppliedMenu: NSMenu? = nil) {
        let menu = suppliedMenu ?? optionsMenu
        menu.items.prefix(3).forEach {
            $0.state = $0.tag == settings.destination.rawValue ? .on : .off
        }
        menu.item(withTitle: "표시 색상")?.submenu?.items.forEach {
            $0.state = $0.tag == settings.annotationColor.rawValue ? .on : .off
        }
        menu.item(withTitle: "선 굵기")?.submenu?.items.forEach {
            $0.state = CGFloat($0.tag) == settings.annotationWidth ? .on : .off
        }
        menu.item(withTag: 900)?.title = "현재 위치: \((settings.outputDirectory.path as NSString).abbreviatingWithTildeInPath)"
    }

    private func update(_ button: NSButton, isSelected: Bool) {
        button.layer?.backgroundColor = isSelected
            ? NSColor.white.withAlphaComponent(0.18).cgColor
            : NSColor.clear.cgColor
    }

    private func set(_ enabled: Bool, on button: NSButton) {
        button.isEnabled = enabled
        button.alphaValue = enabled ? 1 : 0.35
    }

    @objc private func cancelCapture() { onCancel() }
    @objc private func selectFullScreenMode() { onModeChanged(.fullScreen) }
    @objc private func selectSelectionMode() { onModeChanged(.selection) }

    @objc private func selectAnnotationTool(_ sender: NSButton) {
        guard sender.isEnabled, let tool = AnnotationTool(rawValue: sender.tag) else { return }
        onAnnotationToolChanged(selectedTool == tool ? nil : tool)
    }

    @objc private func undoAnnotation() { if undoButton.isEnabled { onUndo() } }
    @objc private func redoAnnotation() { if redoButton.isEnabled { onRedo() } }
    @objc private func clearAnnotations() { if clearButton.isEnabled { onClear() } }

    @objc private func selectDestination(_ sender: NSMenuItem) {
        guard let value = CaptureDestination(rawValue: sender.tag) else { return }
        settings.destination = value
        settingsDidChange()
    }

    @objc private func selectAnnotationColor(_ sender: NSMenuItem) {
        guard let value = AnnotationColor(rawValue: sender.tag) else { return }
        settings.annotationColor = value
        settingsDidChange()
    }

    @objc private func selectAnnotationWidth(_ sender: NSMenuItem) {
        settings.annotationWidth = CGFloat(sender.tag)
        settingsDidChange()
    }

    @objc private func selectScheduledDelay(_ sender: NSPopUpButton) {
        let delay = sender.selectedItem?.tag ?? 5
        scheduledDelay = delay
        helpLabel.stringValue = "\(delay)초 준비: 예약 시작 후 메뉴·콤보박스·팝업을 여세요"
        onScheduledDelayChanged(delay)
    }

    private func settingsDidChange() {
        updateSettingsAppearance()
        updateOptionsMenuStates()
        onSettingsChanged(settings)
    }

    @objc private func chooseOutputDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.prompt = "선택"
        panel.message = "스크린샷을 저장할 폴더를 선택하세요."
        panel.directoryURL = settings.outputDirectory
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue + 1)
        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            self?.settings.outputDirectory = url
            self?.settingsDidChange()
        }
    }

    @objc private func capture() { if captureButton.isEnabled { onCapture() } }

    @objc private func showOptions() {
        updateOptionsMenuStates()
        optionsMenu.popUp(
            positioning: nil,
            at: CGPoint(x: optionsButton.bounds.minX, y: optionsButton.bounds.maxY + 6),
            in: optionsButton
        )
    }
}
