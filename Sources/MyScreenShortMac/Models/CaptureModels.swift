import AppKit

struct ScreenSnapshot {
    let screen: NSScreen
    let image: CGImage
}

enum CaptureDestination: Int, CaseIterable {
    case saveAndCopy
    case saveOnly
    case copyOnly

    var savesToFile: Bool { self != .copyOnly }
    var copiesToClipboard: Bool { self != .saveOnly }
}

enum AnnotationColor: Int, CaseIterable {
    case red
    case yellow
    case blue
    case black
    case white

    var color: NSColor {
        switch self {
        case .red: return .systemRed
        case .yellow: return .systemYellow
        case .blue: return .systemBlue
        case .black: return .black
        case .white: return .white
        }
    }

    var title: String {
        switch self {
        case .red: return "빨강"
        case .yellow: return "노랑"
        case .blue: return "파랑"
        case .black: return "검정"
        case .white: return "흰색"
        }
    }
}

struct CaptureSettings: Equatable {
    var destination: CaptureDestination
    var annotationColor: AnnotationColor
    var annotationWidth: CGFloat
    var outputDirectory: URL
}

final class CapturePreferences {
    static let shared = CapturePreferences()

    private enum Key {
        static let destination = "capture.destination"
        static let annotationColor = "capture.annotationColor"
        static let annotationWidth = "capture.annotationWidth"
        static let outputDirectory = "capture.outputDirectory"
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func load() -> CaptureSettings {
        let destination = CaptureDestination(
            rawValue: defaults.integer(forKey: Key.destination)
        ) ?? .saveAndCopy
        let color = AnnotationColor(
            rawValue: defaults.integer(forKey: Key.annotationColor)
        ) ?? .red
        let storedWidth = defaults.double(forKey: Key.annotationWidth)
        let width = storedWidth > 0 ? CGFloat(storedWidth) : 5
        let directory = defaults.string(forKey: Key.outputDirectory)
            .map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? Self.defaultOutputDirectory()

        return CaptureSettings(
            destination: destination,
            annotationColor: color,
            annotationWidth: width,
            outputDirectory: directory
        )
    }

    func save(_ settings: CaptureSettings) {
        defaults.set(settings.destination.rawValue, forKey: Key.destination)
        defaults.set(settings.annotationColor.rawValue, forKey: Key.annotationColor)
        defaults.set(Double(settings.annotationWidth), forKey: Key.annotationWidth)
        defaults.set(settings.outputDirectory.path, forKey: Key.outputDirectory)
    }

    static func defaultOutputDirectory() -> URL {
        let picturesDirectory = FileManager.default.urls(
            for: .picturesDirectory,
            in: .userDomainMask
        ).first ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Pictures", isDirectory: true)

        return picturesDirectory.appendingPathComponent("ScreenShort", isDirectory: true)
    }
}

enum AnnotationTool: Int, CaseIterable {
    case pen
    case arrow
    case rectangle
    case text
    case eraser
}

struct AnnotationStyle: Equatable {
    let color: AnnotationColor
    let lineWidth: CGFloat
}

enum ScreenAnnotation: Equatable {
    case stroke(points: [CGPoint], style: AnnotationStyle)
    case arrow(start: CGPoint, end: CGPoint, style: AnnotationStyle)
    case rectangle(rect: CGRect, style: AnnotationStyle)
    case text(origin: CGPoint, text: String, style: AnnotationStyle)

    private static let textFontSize: CGFloat = 18

    func draw(offsetBy offset: CGPoint = .zero) {
        switch self {
        case .stroke(let points, let style):
            drawStroke(points: points.map { $0.offset(by: offset) }, style: style)
        case .arrow(let start, let end, let style):
            drawArrow(start: start.offset(by: offset), end: end.offset(by: offset), style: style)
        case .rectangle(let rect, let style):
            let path = NSBezierPath(rect: rect.offsetBy(dx: offset.x, dy: offset.y).standardized)
            path.lineWidth = style.lineWidth
            path.lineJoinStyle = .round
            style.color.color.setStroke()
            path.stroke()
        case .text(let origin, let text, let style):
            text.draw(
                at: origin.offset(by: offset),
                withAttributes: Self.textAttributes(style: style)
            )
        }
    }

    func hitTest(_ point: CGPoint, tolerance: CGFloat = 10) -> Bool {
        bounds.insetBy(dx: -tolerance, dy: -tolerance).contains(point)
    }

    var bounds: CGRect {
        switch self {
        case .stroke(let points, let style):
            return Self.bounds(of: points).insetBy(dx: -style.lineWidth, dy: -style.lineWidth)
        case .arrow(let start, let end, let style):
            return Self.bounds(of: [start, end]).insetBy(
                dx: -(style.lineWidth + 12),
                dy: -(style.lineWidth + 12)
            )
        case .rectangle(let rect, let style):
            return rect.standardized.insetBy(dx: -style.lineWidth, dy: -style.lineWidth)
        case .text(let origin, let text, let style):
            let size = text.size(withAttributes: Self.textAttributes(style: style))
            return CGRect(origin: origin, size: size)
        }
    }

    private func drawStroke(points: [CGPoint], style: AnnotationStyle) {
        guard let first = points.first else { return }
        if points.count == 1 {
            style.color.color.setFill()
            NSBezierPath(
                ovalIn: CGRect(
                    x: first.x - style.lineWidth / 2,
                    y: first.y - style.lineWidth / 2,
                    width: style.lineWidth,
                    height: style.lineWidth
                )
            ).fill()
            return
        }

        let path = NSBezierPath()
        path.move(to: first)
        points.dropFirst().forEach { path.line(to: $0) }
        path.lineWidth = style.lineWidth
        path.lineCapStyle = .round
        path.lineJoinStyle = .round
        style.color.color.setStroke()
        path.stroke()
    }

    private func drawArrow(start: CGPoint, end: CGPoint, style: AnnotationStyle) {
        let path = NSBezierPath()
        path.move(to: start)
        path.line(to: end)
        path.lineWidth = style.lineWidth
        path.lineCapStyle = .round
        path.lineJoinStyle = .round

        let angle = atan2(end.y - start.y, end.x - start.x)
        let headLength = max(12, style.lineWidth * 3)
        let spread = CGFloat.pi / 6
        let left = CGPoint(
            x: end.x - headLength * cos(angle - spread),
            y: end.y - headLength * sin(angle - spread)
        )
        let right = CGPoint(
            x: end.x - headLength * cos(angle + spread),
            y: end.y - headLength * sin(angle + spread)
        )
        path.move(to: left)
        path.line(to: end)
        path.line(to: right)

        style.color.color.setStroke()
        path.stroke()
    }

    private static func textAttributes(style: AnnotationStyle) -> [NSAttributedString.Key: Any] {
        [
            .font: NSFont.systemFont(ofSize: textFontSize, weight: .semibold),
            .foregroundColor: style.color.color,
            .strokeColor: NSColor.black.withAlphaComponent(0.45),
            .strokeWidth: -1.5
        ]
    }

    private static func bounds(of points: [CGPoint]) -> CGRect {
        guard let first = points.first else { return .zero }
        return points.dropFirst().reduce(CGRect(origin: first, size: .zero)) { rect, point in
            rect.union(CGRect(origin: point, size: .zero))
        }
    }
}

struct ScreenSelection {
    let snapshot: ScreenSnapshot
    let rect: CGRect
    let annotations: [ScreenAnnotation]
    let destination: CaptureDestination
    let outputDirectory: URL
    let scheduledDelay: Int?

    init(
        snapshot: ScreenSnapshot,
        rect: CGRect,
        annotations: [ScreenAnnotation],
        destination: CaptureDestination,
        outputDirectory: URL,
        scheduledDelay: Int? = nil
    ) {
        self.snapshot = snapshot
        self.rect = rect
        self.annotations = annotations
        self.destination = destination
        self.outputDirectory = outputDirectory
        self.scheduledDelay = scheduledDelay
    }
}

private extension CGPoint {
    func offset(by offset: CGPoint) -> CGPoint {
        CGPoint(x: x + offset.x, y: y + offset.y)
    }
}
