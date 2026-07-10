import AppKit

struct ScreenshotCapture {
    let image: NSImage
    let imageData: Data
    let fileURL: URL?
    let destination: CaptureDestination
}

final class ScreenshotService {
    private var selectionController: SelectionOverlayController?
    var isCaptureInProgress: Bool { selectionController != nil }
    private let fileNameDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ko_KR")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        return formatter
    }()

    func captureToClipboard(completion: @escaping (Result<ScreenshotCapture, Error>) -> Void) {
        guard selectionController == nil else {
            AppLogService.write("Capture request ignored: capture already in progress")
            return
        }

        let snapshots: [ScreenSnapshot]
        do {
            snapshots = try captureScreenSnapshots()
        } catch {
            completion(.failure(error))
            return
        }

        let controller = SelectionOverlayController()
        selectionController = controller

        controller.start(snapshots: snapshots) { [weak self] result in
            guard let self else {
                return
            }

            switch result {
            case .success(let selection):
                self.selectionController = nil
                self.cropSelectionToClipboard(selection, completion: completion)
            case .failure(let error):
                self.selectionController = nil
                completion(.failure(error))
            }
        }
    }

    private func captureScreenSnapshots() throws -> [ScreenSnapshot] {
        try NSScreen.screens.map { screen in
            guard let screenNumber = screen.deviceDescription[
                NSDeviceDescriptionKey("NSScreenNumber")
            ] as? NSNumber,
                  let image = CGDisplayCreateImage(CGDirectDisplayID(screenNumber.uint32Value)) else {
                throw ScreenshotError.snapshotFailed
            }

            return ScreenSnapshot(screen: screen, image: image)
        }
    }

    private func cropSelectionToClipboard(
        _ selection: ScreenSelection,
        completion: @escaping (Result<ScreenshotCapture, Error>) -> Void
    ) {
        let snapshot = selection.snapshot
        let pixelRect = pixelCropRect(
            for: selection.rect,
            screenSize: snapshot.screen.frame.size,
            image: snapshot.image
        )
        AppLogService.write("Capture rect: \(selection.rect), pixels: \(pixelRect)")

        guard let croppedImage = snapshot.image.cropping(to: pixelRect) else {
            completion(.failure(ScreenshotError.imageCropFailed))
            return
        }

        guard let imageData = renderPNGData(
            croppedImage: croppedImage,
            selection: selection
        ) else {
            completion(.failure(ScreenshotError.imageEncodingFailed))
            return
        }

        guard let image = NSImage(data: imageData) else {
            completion(.failure(ScreenshotError.imageLoadFailed))
            return
        }

        var captureURL: URL?
        if selection.destination.savesToFile {
            do {
                let outputURL = try nextOutputURL(in: selection.outputDirectory)
                try imageData.write(to: outputURL, options: .atomic)
                captureURL = outputURL
                AppLogService.write("Capture saved: \(outputURL.path)")
            } catch {
                completion(.failure(error))
                return
            }
        }

        if selection.destination.copiesToClipboard {
            copyImageDataToClipboard(imageData, fallbackImage: image)
            AppLogService.write("Capture copied to clipboard")
        }

        completion(
            .success(
                ScreenshotCapture(
                    image: image,
                    imageData: imageData,
                    fileURL: captureURL,
                    destination: selection.destination
                )
            )
        )
    }

    func selectScheduledRegion(
        completion: @escaping (Result<ScheduledCaptureSelection, Error>) -> Void
    ) {
        guard selectionController == nil else {
            completion(.failure(ScreenshotError.captureInProgress))
            return
        }

        let snapshots: [ScreenSnapshot]
        do {
            snapshots = try captureScreenSnapshots()
        } catch {
            completion(.failure(error))
            return
        }

        let controller = SelectionOverlayController()
        selectionController = controller
        controller.start(snapshots: snapshots, purpose: .scheduledRegion) { [weak self] result in
            self?.selectionController = nil
            switch result {
            case .success(let selection):
                guard let displayID = selection.snapshot.screen.displayID else {
                    completion(.failure(ScreenshotError.displayUnavailable))
                    return
                }
                completion(
                    .success(
                        ScheduledCaptureSelection(
                            region: ScheduledCaptureRegion(
                                displayID: displayID,
                                rect: selection.rect
                            ),
                            delay: selection.scheduledDelay ?? 5
                        )
                    )
                )
            case .failure(let error):
                completion(.failure(error))
            }
        }
    }

    func captureScheduledRegion(
        _ region: ScheduledCaptureRegion,
        completion: @escaping (Result<ScreenshotCapture, Error>) -> Void
    ) {
        guard selectionController == nil else {
            completion(.failure(ScreenshotError.captureInProgress))
            return
        }
        guard let screen = region.screen,
              let image = CGDisplayCreateImage(region.displayID) else {
            completion(.failure(ScreenshotError.displayUnavailable))
            return
        }

        let screenBounds = CGRect(origin: .zero, size: screen.frame.size)
        let captureRect = region.rect.intersection(screenBounds)
        guard !captureRect.isNull,
              captureRect.width >= 1,
              captureRect.height >= 1 else {
            completion(.failure(ScreenshotError.invalidRegion))
            return
        }

        let settings = CapturePreferences.shared.load()
        let selection = ScreenSelection(
            snapshot: ScreenSnapshot(screen: screen, image: image),
            rect: captureRect,
            annotations: [],
            destination: settings.destination,
            outputDirectory: settings.outputDirectory
        )
        cropSelectionToClipboard(selection, completion: completion)
    }

    private func renderPNGData(
        croppedImage: CGImage,
        selection: ScreenSelection
    ) -> Data? {
        guard let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: croppedImage.width,
            pixelsHigh: croppedImage.height,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bitmapFormat: [],
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) else {
            return nil
        }

        bitmap.size = selection.rect.size
        guard let context = NSGraphicsContext(bitmapImageRep: bitmap) else {
            return nil
        }

        let image = NSImage(cgImage: croppedImage, size: selection.rect.size)
        let outputBounds = CGRect(origin: .zero, size: selection.rect.size)

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        context.imageInterpolation = .none
        image.draw(in: outputBounds, from: .zero, operation: .copy, fraction: 1)
        NSBezierPath(rect: outputBounds).addClip()
        let offset = CGPoint(x: -selection.rect.minX, y: -selection.rect.minY)
        selection.annotations.forEach { $0.draw(offsetBy: offset) }
        context.flushGraphics()
        NSGraphicsContext.restoreGraphicsState()

        return bitmap.representation(using: .png, properties: [:])
    }

    private func pixelCropRect(
        for selectionRect: CGRect,
        screenSize: CGSize,
        image: CGImage
    ) -> CGRect {
        let scaleX = CGFloat(image.width) / screenSize.width
        let scaleY = CGFloat(image.height) / screenSize.height
        let minX = floor(selectionRect.minX * scaleX)
        let maxX = ceil(selectionRect.maxX * scaleX)
        let minY = floor((screenSize.height - selectionRect.maxY) * scaleY)
        let maxY = ceil((screenSize.height - selectionRect.minY) * scaleY)

        return CGRect(
            x: max(0, minX),
            y: max(0, minY),
            width: min(CGFloat(image.width), maxX) - max(0, minX),
            height: min(CGFloat(image.height), maxY) - max(0, minY)
        )
    }

    private func nextOutputURL(in outputDirectory: URL) throws -> URL {
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: outputDirectory, withIntermediateDirectories: true)

        let baseName = "ScreenShort-\(fileNameDateFormatter.string(from: Date()))"
        let fileExtension = "png"
        var candidate = outputDirectory.appendingPathComponent(baseName).appendingPathExtension(fileExtension)
        var index = 1

        while fileManager.fileExists(atPath: candidate.path) {
            candidate = outputDirectory
                .appendingPathComponent("\(baseName)-\(index)")
                .appendingPathExtension(fileExtension)
            index += 1
        }

        return candidate
    }

    private func copyImageDataToClipboard(_ imageData: Data, fallbackImage image: NSImage) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()

        let item = NSPasteboardItem()
        item.setData(imageData, forType: .png)

        if let tiffData = image.tiffRepresentation {
            item.setData(tiffData, forType: .tiff)
        }

        if !pasteboard.writeObjects([item]) {
            pasteboard.writeObjects([image])
        }
    }

}

enum ScreenshotError: Error {
    case captureCancelled
    case captureInProgress
    case snapshotFailed
    case displayUnavailable
    case invalidRegion
    case imageCropFailed
    case imageEncodingFailed
    case imageLoadFailed
}
