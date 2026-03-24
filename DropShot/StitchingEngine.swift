import CoreGraphics
import Foundation
import Vision

final class StitchingEngine {
    typealias RegistrationProvider = (CGImage, CGImage) -> Result<Translation, Error>

    struct Configuration {
        var minimumConfidence: Float
        var minimumVerticalOffset: CGFloat
        var minimumVerticalDominanceRatio: CGFloat
        var minimumOverlapRatio: CGFloat
        var maximumCompositePixelCount: Int

        init(
            minimumConfidence: Float = 0.2,
            minimumVerticalOffset: CGFloat = 12,
            minimumVerticalDominanceRatio: CGFloat = 1.75,
            minimumOverlapRatio: CGFloat = 0.2,
            maximumCompositePixelCount: Int = 32_000_000
        ) {
            self.minimumConfidence = minimumConfidence
            self.minimumVerticalOffset = minimumVerticalOffset
            self.minimumVerticalDominanceRatio = minimumVerticalDominanceRatio
            self.minimumOverlapRatio = minimumOverlapRatio
            self.maximumCompositePixelCount = maximumCompositePixelCount
        }
    }

    struct Strip {
        let index: Int
        let image: CGImage
        let capturedAt: Date

        init(index: Int, image: CGImage, capturedAt: Date = Date()) {
            self.index = index
            self.image = image
            self.capturedAt = capturedAt
        }
    }

    struct Translation {
        let horizontalOffset: CGFloat
        let verticalOffset: CGFloat
        let confidence: Float

        var absoluteHorizontalOffset: CGFloat {
            abs(horizontalOffset)
        }

        var absoluteVerticalOffset: CGFloat {
            abs(verticalOffset)
        }
    }

    enum StripDisposition {
        case seed
        case appended
        case trimmed
        case rejected
    }

    enum RejectionReason: String {
        case imageSizeMismatch
        case registrationFailed
        case registrationObservationMissing
        case lowConfidence
        case insufficientVerticalMovement
        case insufficientVerticalDominance
        case insufficientOverlap
        case reverseVerticalMovement
        case excessiveReverseMovement
    }

    struct ProcessedStrip {
        let strip: Strip
        let disposition: StripDisposition
        let translation: Translation?
        let appendedHeight: Int
        let compositeHeight: Int
        let rejectionReason: RejectionReason?
        let diagnostic: String?
    }

    struct CaptureMetadata {
        let startedAt: Date
        let endedAt: Date
        let sourceStripCount: Int
        let acceptedStripCount: Int
        let rejectedStripCount: Int
        let compositePixelSize: CGSize
        let processedStrips: [ProcessedStrip]
    }

    struct Composite {
        let image: CGImage
        let metadata: CaptureMetadata
    }

    enum StitchingError: LocalizedError {
        case noStrips
        case compositeTooLarge(width: Int, height: Int, maximumPixels: Int)
        case rasterizationFailed(width: Int, height: Int)
        case compositeImageCreationFailed(width: Int, height: Int)

        var errorDescription: String? {
            switch self {
            case .noStrips:
                return "The stitching engine cannot build a composite without any strips."
            case .compositeTooLarge(let width, let height, let maximumPixels):
                let pixelCount = Int64(width) * Int64(height)
                return "The stitched image would be \(width)x\(height) (\(pixelCount) pixels), exceeding the \(maximumPixels)-pixel safety limit."
            case .rasterizationFailed(let width, let height):
                return "The stitching engine could not rasterize a \(width)x\(height) strip."
            case .compositeImageCreationFailed(let width, let height):
                return "The stitching engine could not create a \(width)x\(height) composite image."
            }
        }
    }

    private struct Failure: Error {
        let reason: RejectionReason
        let diagnostic: String
    }

    private struct RegistrationAssessment {
        let translation: Translation?
        let usableTranslation: Translation?
        let failure: Failure?

        static func usable(_ translation: Translation) -> RegistrationAssessment {
            RegistrationAssessment(
                translation: translation,
                usableTranslation: translation,
                failure: nil
            )
        }

        static func rejected(
            translation: Translation? = nil,
            reason: RejectionReason,
            diagnostic: String
        ) -> RegistrationAssessment {
            RegistrationAssessment(
                translation: translation,
                usableTranslation: nil,
                failure: Failure(reason: reason, diagnostic: diagnostic)
            )
        }
    }

    private struct CompositeAlignment {
        let horizontalOffset: CGFloat
        let verticalOffset: CGFloat

        static let identity = CompositeAlignment(horizontalOffset: 0, verticalOffset: 0)

        init(horizontalOffset: CGFloat, verticalOffset: CGFloat) {
            self.horizontalOffset = horizontalOffset
            self.verticalOffset = verticalOffset
        }

        init(_ translation: Translation) {
            self.init(
                horizontalOffset: translation.horizontalOffset,
                verticalOffset: translation.verticalOffset
            )
        }

        var absoluteHorizontalOffset: CGFloat {
            abs(horizontalOffset)
        }

        var absoluteVerticalOffset: CGFloat {
            abs(verticalOffset)
        }

        func appending(_ translation: Translation) -> CompositeAlignment {
            CompositeAlignment(
                horizontalOffset: horizontalOffset + translation.horizontalOffset,
                verticalOffset: verticalOffset + translation.verticalOffset
            )
        }
    }

    private struct QuantizedAlignment {
        let horizontalOffset: Int
        let verticalOffset: Int

        init(_ alignment: CompositeAlignment) {
            horizontalOffset = Int(alignment.horizontalOffset.rounded())
            verticalOffset = Int(alignment.verticalOffset.rounded())
        }
    }

    private struct AppendPlan {
        let appendedHeight: Int
        let sourceStartRow: Int
    }

    private struct TrimPlan {
        let trimmedHeight: Int
    }

    private struct MovementGeometry {
        let horizontalOffset: Int
        let verticalOffset: Int
    }

    private enum CompositeChangeDecision {
        case append(AppendPlan)
        case trim(TrimPlan)
        case deferMovement(diagnostic: String)
        case reject(reason: RejectionReason, diagnostic: String)
    }

    private enum ConnectionResolution {
        case connected(alignment: CompositeAlignment, diagnostic: String?)
        case disconnected(reason: RejectionReason, diagnostic: String)
    }

    private struct Raster {
        let width: Int
        let height: Int
        let bytesPerRow: Int
        let bytes: [UInt8]
    }

    private struct CompositeSegment {
        let image: CGImage
        let sourceStartRow: Int
        let height: Int
    }

    private static let colorSpace = CGColorSpaceCreateDeviceRGB()
    private static let bitmapInfo = CGBitmapInfo.byteOrder32Big.union(
        CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue)
    )

    let configuration: Configuration

    private let registrationProvider: RegistrationProvider

    private(set) var processedStrips: [ProcessedStrip] = []

    // Registration always advances through adjacent source strips, while the composite itself
    // stays anchored to the last strip already represented at the stitched edge.
    private var compositeAnchorStrip: Strip?
    private var lastStrip: Strip?
    private var lastStripAlignmentToAnchor: CompositeAlignment?
    private var compositeSegments: [CompositeSegment] = []
    private var compositeWidth: Int = 0
    private var compositeHeight: Int = 0

    init(
        configuration: Configuration = Configuration(),
        registrationProvider: @escaping RegistrationProvider = StitchingEngine.defaultRegistrationProvider
    ) {
        self.configuration = configuration
        self.registrationProvider = registrationProvider
    }

    @discardableResult
    func addStrips<S: Sequence>(_ strips: S) throws -> [ProcessedStrip] where S.Element == Strip {
        var processed: [ProcessedStrip] = []
        processed.reserveCapacity(underestimatedCount(for: strips))

        for strip in strips {
            processed.append(try addStrip(strip))
        }

        return processed
    }

    @discardableResult
    func addStrip(_ strip: Strip) throws -> ProcessedStrip {
        guard let previousStrip = lastStrip else {
            let processed = try seed(strip)
            processedStrips.append(processed)
            return processed
        }

        let adjacentAssessment = assessRegistration(from: previousStrip, to: strip)
        let processed = try process(strip, relativeTo: previousStrip, adjacentAssessment: adjacentAssessment)
        processedStrips.append(processed)
        lastStrip = strip
        return processed
    }

    func buildComposite() throws -> Composite {
        guard let startedAt = processedStrips.first?.strip.capturedAt,
              let endedAt = processedStrips.last?.strip.capturedAt else {
            throw StitchingError.noStrips
        }

        try validateCompositeSize(width: compositeWidth, height: compositeHeight)
        let image = try renderCompositeImage()
        let acceptedStripCount = processedStrips.reduce(into: 0) { count, processed in
            if processed.disposition != .rejected {
                count += 1
            }
        }
        let metadata = CaptureMetadata(
            startedAt: startedAt,
            endedAt: endedAt,
            sourceStripCount: processedStrips.count,
            acceptedStripCount: acceptedStripCount,
            rejectedStripCount: processedStrips.count - acceptedStripCount,
            compositePixelSize: CGSize(width: compositeWidth, height: compositeHeight),
            processedStrips: processedStrips
        )
        return Composite(image: image, metadata: metadata)
    }

    static func stitch(
        _ strips: [Strip],
        configuration: Configuration = Configuration()
    ) throws -> Composite {
        let engine = StitchingEngine(configuration: configuration)
        try engine.addStrips(strips)
        return try engine.buildComposite()
    }

    private func seed(_ strip: Strip) throws -> ProcessedStrip {
        try validateCompositeSize(width: strip.image.width, height: strip.image.height)
        compositeWidth = strip.image.width
        compositeHeight = strip.image.height
        compositeSegments = [
            CompositeSegment(image: strip.image, sourceStartRow: 0, height: strip.image.height)
        ]
        compositeAnchorStrip = strip
        lastStrip = strip
        lastStripAlignmentToAnchor = .identity

        return ProcessedStrip(
            strip: strip,
            disposition: .seed,
            translation: nil,
            appendedHeight: strip.image.height,
            compositeHeight: strip.image.height,
            rejectionReason: nil,
            diagnostic: nil
        )
    }

    private func process(
        _ strip: Strip,
        relativeTo previousStrip: Strip,
        adjacentAssessment: RegistrationAssessment
    ) throws -> ProcessedStrip {
        let connection = resolveCompositeConnection(
            for: strip,
            relativeTo: previousStrip,
            adjacentAssessment: adjacentAssessment
        )

        switch connection {
        case .connected(let alignment, let diagnostic):
            let decision = decideCompositeChange(
                for: alignment,
                imageWidth: strip.image.width,
                imageHeight: strip.image.height
            )

            switch decision {
            case .append(let plan):
                try validateCompositeSize(
                    width: compositeWidth,
                    height: compositeHeight + plan.appendedHeight
                )
                compositeSegments.append(
                    CompositeSegment(
                        image: strip.image,
                        sourceStartRow: plan.sourceStartRow,
                        height: plan.appendedHeight
                    )
                )
                compositeHeight += plan.appendedHeight
                compositeAnchorStrip = strip
                lastStripAlignmentToAnchor = .identity

                return ProcessedStrip(
                    strip: strip,
                    disposition: .appended,
                    translation: adjacentAssessment.translation,
                    appendedHeight: plan.appendedHeight,
                    compositeHeight: compositeHeight,
                    rejectionReason: nil,
                    diagnostic: diagnostic
                )

            case .trim(let plan):
                trimComposite(by: plan.trimmedHeight)
                compositeAnchorStrip = strip
                lastStripAlignmentToAnchor = .identity

                return ProcessedStrip(
                    strip: strip,
                    disposition: .trimmed,
                    translation: adjacentAssessment.translation,
                    appendedHeight: 0,
                    compositeHeight: compositeHeight,
                    rejectionReason: nil,
                    diagnostic: joinedDiagnostics(
                        diagnostic,
                        "Trimmed \(plan.trimmedHeight)px from the composite tail after reverse movement."
                    )
                )

            case .deferMovement(let movementDiagnostic):
                lastStripAlignmentToAnchor = alignment
                return ProcessedStrip(
                    strip: strip,
                    disposition: .rejected,
                    translation: adjacentAssessment.translation,
                    appendedHeight: 0,
                    compositeHeight: compositeHeight,
                    rejectionReason: .insufficientVerticalMovement,
                    diagnostic: joinedDiagnostics(diagnostic, movementDiagnostic)
                )

            case .reject(let reason, let rejectionDiagnostic):
                lastStripAlignmentToAnchor = nil
                return ProcessedStrip(
                    strip: strip,
                    disposition: .rejected,
                    translation: adjacentAssessment.translation,
                    appendedHeight: 0,
                    compositeHeight: compositeHeight,
                    rejectionReason: reason,
                    diagnostic: joinedDiagnostics(diagnostic, rejectionDiagnostic)
                )
            }

        case .disconnected(let reason, let diagnostic):
            lastStripAlignmentToAnchor = nil
            return ProcessedStrip(
                strip: strip,
                disposition: .rejected,
                translation: adjacentAssessment.translation,
                appendedHeight: 0,
                compositeHeight: compositeHeight,
                rejectionReason: reason,
                diagnostic: diagnostic
            )
        }
    }

    private func resolveCompositeConnection(
        for strip: Strip,
        relativeTo previousStrip: Strip,
        adjacentAssessment: RegistrationAssessment
    ) -> ConnectionResolution {
        if let previousAlignment = lastStripAlignmentToAnchor,
           let adjacentTranslation = adjacentAssessment.usableTranslation {
            return .connected(
                alignment: previousAlignment.appending(adjacentTranslation),
                diagnostic: nil
            )
        }

        var diagnostics: [String] = []

        if let adjacentFailure = adjacentAssessment.failure {
            diagnostics.append("Adjacent registration failed: \(adjacentFailure.diagnostic)")
        } else if adjacentAssessment.usableTranslation != nil {
            diagnostics.append(
                "Adjacent registration was credible, but the previous strip was not connected to the composite edge."
            )
        }

        guard let anchorStrip = compositeAnchorStrip else {
            return .disconnected(
                reason: adjacentAssessment.failure?.reason ?? .registrationFailed,
                diagnostic: joinedDiagnostics(
                    diagnostics.joined(separator: " "),
                    "The composite anchor was unavailable."
                ) ?? "The composite anchor was unavailable."
            )
        }

        guard anchorStrip.index != previousStrip.index else {
            if let adjacentFailure = adjacentAssessment.failure {
                return .disconnected(
                    reason: adjacentFailure.reason,
                    diagnostic: joinedDiagnostics(
                        diagnostics.isEmpty ? nil : diagnostics.joined(separator: " "),
                        nil
                    ) ?? adjacentFailure.diagnostic
                )
            }

            return .disconnected(
                reason: .registrationFailed,
                diagnostic: joinedDiagnostics(
                    diagnostics.isEmpty ? nil : diagnostics.joined(separator: " "),
                    "The strip could not be reattached to the composite edge."
                ) ?? "The strip could not be reattached to the composite edge."
            )
        }

        let anchorAssessment = assessRegistration(from: anchorStrip, to: strip)
        if let recoveryTranslation = anchorAssessment.usableTranslation {
            return .connected(
                alignment: CompositeAlignment(recoveryTranslation),
                diagnostic: joinedDiagnostics(
                    diagnostics.joined(separator: " "),
                    "Recovered alignment directly from composite anchor strip \(anchorStrip.index)."
                )
            )
        }

        let recoveryFailure = anchorAssessment.failure ?? Failure(
            reason: .registrationFailed,
            diagnostic: "The strip could not be reattached to the composite edge."
        )
        return .disconnected(
            reason: recoveryFailure.reason,
            diagnostic: joinedDiagnostics(
                diagnostics.joined(separator: " "),
                "Composite-anchor recovery failed: \(recoveryFailure.diagnostic)"
            ) ?? "Composite-anchor recovery failed: \(recoveryFailure.diagnostic)"
        )
    }

    private func decideCompositeChange(
        for alignment: CompositeAlignment,
        imageWidth: Int,
        imageHeight: Int
    ) -> CompositeChangeDecision {
        guard alignment.absoluteVerticalOffset >=
                alignment.absoluteHorizontalOffset * configuration.minimumVerticalDominanceRatio else {
            return .reject(
                reason: .insufficientVerticalDominance,
                diagnostic: "Accumulated vertical offset \(alignment.absoluteVerticalOffset)px was not dominant over horizontal offset \(alignment.absoluteHorizontalOffset)px."
            )
        }

        let quantizedAlignment = QuantizedAlignment(alignment)
        if quantizedAlignment.verticalOffset == 0 {
            return .deferMovement(
                diagnostic: "The accumulated movement rounded to zero new rows."
            )
        }

        if quantizedAlignment.verticalOffset > 0 {
            switch makeAppendPlan(for: alignment, imageWidth: imageWidth, imageHeight: imageHeight) {
            case .success(let plan):
                guard CGFloat(plan.appendedHeight) >= configuration.minimumVerticalOffset else {
                    return .deferMovement(
                        diagnostic: "Accumulated forward movement \(plan.appendedHeight)px was below \(configuration.minimumVerticalOffset)px."
                    )
                }
                return .append(plan)

            case .failure(let failure):
                if failure.reason == .insufficientVerticalMovement {
                    return .deferMovement(diagnostic: failure.diagnostic)
                }
                return .reject(reason: failure.reason, diagnostic: failure.diagnostic)
            }
        }

        switch makeTrimPlan(
            for: alignment,
            imageWidth: imageWidth,
            imageHeight: imageHeight,
            compositeHeight: compositeHeight
        ) {
        case .success(let plan):
            return .trim(plan)

        case .failure(let failure):
            if failure.reason == .insufficientVerticalMovement {
                return .deferMovement(diagnostic: failure.diagnostic)
            }
            return .reject(reason: failure.reason, diagnostic: failure.diagnostic)
        }
    }

    private func assessRegistration(from referenceStrip: Strip, to currentStrip: Strip) -> RegistrationAssessment {
        guard imagesHaveMatchingSize(referenceStrip.image, currentStrip.image) else {
            return .rejected(
                reason: .imageSizeMismatch,
                diagnostic: "Expected \(referenceStrip.image.width)x\(referenceStrip.image.height) but received \(currentStrip.image.width)x\(currentStrip.image.height)."
            )
        }

        switch registrationProvider(referenceStrip.image, currentStrip.image) {
        case .success(let translation):
            return assessUsableMotion(translation, imageWidth: currentStrip.image.width, imageHeight: currentStrip.image.height)

        case .failure(let error):
            let reason: RejectionReason
            if case RegistrationError.observationMissing = error {
                reason = .registrationObservationMissing
            } else {
                reason = .registrationFailed
            }
            return .rejected(reason: reason, diagnostic: error.localizedDescription)
        }
    }

    private func assessUsableMotion(
        _ translation: Translation,
        imageWidth: Int,
        imageHeight: Int
    ) -> RegistrationAssessment {
        guard translation.confidence >= configuration.minimumConfidence else {
            return .rejected(
                translation: translation,
                reason: .lowConfidence,
                diagnostic: "Vision confidence \(translation.confidence) was below \(configuration.minimumConfidence)."
            )
        }

        guard translation.absoluteVerticalOffset >=
                translation.absoluteHorizontalOffset * configuration.minimumVerticalDominanceRatio else {
            return .rejected(
                translation: translation,
                reason: .insufficientVerticalDominance,
                diagnostic: "Vertical offset \(translation.absoluteVerticalOffset)px was not dominant over horizontal offset \(translation.absoluteHorizontalOffset)px."
            )
        }

        switch movementGeometry(
            for: CompositeAlignment(translation),
            imageWidth: imageWidth,
            imageHeight: imageHeight
        ) {
        case .success:
            return .usable(translation)

        case .failure(let failure):
            return .rejected(
                translation: translation,
                reason: failure.reason,
                diagnostic: failure.diagnostic
            )
        }
    }

    private func makeAppendPlan(
        for alignment: CompositeAlignment,
        imageWidth: Int,
        imageHeight: Int
    ) -> Result<AppendPlan, Failure> {
        switch movementGeometry(for: alignment, imageWidth: imageWidth, imageHeight: imageHeight) {
        case .success(let geometry):
            guard geometry.verticalOffset > 0 else {
                return .failure(
                    Failure(
                        reason: .reverseVerticalMovement,
                        diagnostic: "Vision alignment indicates the current strip would prepend rows above the existing composite."
                    )
                )
            }

            return .success(
                AppendPlan(
                    appendedHeight: geometry.verticalOffset,
                    sourceStartRow: imageHeight - geometry.verticalOffset
                )
            )

        case .failure(let failure):
            return .failure(failure)
        }
    }

    private func makeTrimPlan(
        for alignment: CompositeAlignment,
        imageWidth: Int,
        imageHeight: Int,
        compositeHeight: Int
    ) -> Result<TrimPlan, Failure> {
        switch movementGeometry(for: alignment, imageWidth: imageWidth, imageHeight: imageHeight) {
        case .success(let geometry):
            guard geometry.verticalOffset < 0 else {
                return .failure(
                    Failure(
                        reason: .insufficientVerticalMovement,
                        diagnostic: "The registered movement did not move the composite backward."
                    )
                )
            }

            let trimmedHeight = -geometry.verticalOffset
            let remainingHeight = compositeHeight - trimmedHeight
            guard remainingHeight > 0 else {
                return .failure(
                    Failure(
                        reason: .excessiveReverseMovement,
                        diagnostic: "Reverse movement of \(trimmedHeight)px would remove the entire composite."
                    )
                )
            }

            return .success(TrimPlan(trimmedHeight: trimmedHeight))

        case .failure(let failure):
            return .failure(failure)
        }
    }

    private func movementGeometry(
        for alignment: CompositeAlignment,
        imageWidth: Int,
        imageHeight: Int
    ) -> Result<MovementGeometry, Failure> {
        let quantizedAlignment = QuantizedAlignment(alignment)
        let verticalOffset = quantizedAlignment.verticalOffset
        let horizontalOffset = quantizedAlignment.horizontalOffset

        guard verticalOffset != 0 else {
            return .failure(
                Failure(
                    reason: .insufficientVerticalMovement,
                    diagnostic: "The registered movement rounded to zero new rows."
                )
            )
        }

        let overlapHeight = imageHeight - abs(verticalOffset)
        let overlapWidth = imageWidth - abs(horizontalOffset)
        let minimumOverlapHeight = minimumOverlapLength(for: imageHeight)
        let minimumOverlapWidth = minimumOverlapLength(for: imageWidth)

        guard overlapHeight >= minimumOverlapHeight, overlapWidth >= minimumOverlapWidth else {
            return .failure(
                Failure(
                    reason: .insufficientOverlap,
                    diagnostic: "The registered movement left only \(max(0, overlapWidth))px x \(max(0, overlapHeight))px of overlap; at least \(minimumOverlapWidth)px x \(minimumOverlapHeight)px is required."
                )
            )
        }

        return .success(
            MovementGeometry(
                horizontalOffset: horizontalOffset,
                verticalOffset: verticalOffset
            )
        )
    }

    private func minimumOverlapLength(for dimension: Int) -> Int {
        max(1, Int((CGFloat(dimension) * configuration.minimumOverlapRatio).rounded(.up)))
    }

    private func trimComposite(by trimmedHeight: Int) {
        guard trimmedHeight > 0 else {
            return
        }

        var remainingTrim = trimmedHeight
        while remainingTrim > 0, let trailingSegment = compositeSegments.last {
            if trailingSegment.height <= remainingTrim {
                compositeSegments.removeLast()
                remainingTrim -= trailingSegment.height
            } else {
                compositeSegments[compositeSegments.count - 1] = CompositeSegment(
                    image: trailingSegment.image,
                    sourceStartRow: trailingSegment.sourceStartRow,
                    height: trailingSegment.height - remainingTrim
                )
                remainingTrim = 0
            }
        }

        compositeHeight -= trimmedHeight
    }

    private func validateCompositeSize(width: Int, height: Int) throws {
        let pixelCount = Int64(width) * Int64(height)
        guard pixelCount <= Int64(configuration.maximumCompositePixelCount) else {
            throw StitchingError.compositeTooLarge(
                width: width,
                height: height,
                maximumPixels: configuration.maximumCompositePixelCount
            )
        }
    }

    private func renderCompositeImage() throws -> CGImage {
        guard !compositeSegments.isEmpty else {
            throw StitchingError.noStrips
        }

        let bytesPerRow = compositeWidth * 4
        var compositeBytes = [UInt8](repeating: 0, count: compositeHeight * bytesPerRow)
        var destinationStartRow = 0

        for segment in compositeSegments {
            let raster = try rasterize(segment.image)
            copyRows(
                from: raster,
                sourceStartRow: segment.sourceStartRow,
                rowCount: segment.height,
                into: &compositeBytes,
                destinationStartRow: destinationStartRow,
                destinationBytesPerRow: bytesPerRow
            )
            destinationStartRow += segment.height
        }

        return try makeImage(from: compositeBytes, width: compositeWidth, height: compositeHeight)
    }

    private func rasterize(_ image: CGImage) throws -> Raster {
        let bytesPerRow = image.width * 4
        var bytes = [UInt8](repeating: 0, count: image.height * bytesPerRow)
        let wasRasterized = bytes.withUnsafeMutableBytes { rawBuffer in
            guard let context = CGContext(
                data: rawBuffer.baseAddress,
                width: image.width,
                height: image.height,
                bitsPerComponent: 8,
                bytesPerRow: bytesPerRow,
                space: Self.colorSpace,
                bitmapInfo: Self.bitmapInfo.rawValue
            ) else {
                return false
            }

            context.interpolationQuality = .none
            // Core Graphics bitmap contexts use a bottom-left origin by default.
            // Flip into a top-left coordinate space so copied rows preserve the
            // same visual orientation as the original capture strips.
            context.translateBy(x: 0, y: CGFloat(image.height))
            context.scaleBy(x: 1, y: -1)
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            return true
        }

        guard wasRasterized else {
            throw StitchingError.rasterizationFailed(width: image.width, height: image.height)
        }

        return Raster(width: image.width, height: image.height, bytesPerRow: bytesPerRow, bytes: bytes)
    }

    private func copyRows(
        from raster: Raster,
        sourceStartRow: Int,
        rowCount: Int,
        into destinationBytes: inout [UInt8],
        destinationStartRow: Int,
        destinationBytesPerRow: Int
    ) {
        let rowLength = raster.width * 4

        for rowOffset in 0..<rowCount {
            let sourceOffset = (sourceStartRow + rowOffset) * raster.bytesPerRow
            let destinationOffset = (destinationStartRow + rowOffset) * destinationBytesPerRow
            destinationBytes[destinationOffset..<(destinationOffset + rowLength)] =
                raster.bytes[sourceOffset..<(sourceOffset + rowLength)]
        }
    }

    private func makeImage(from bytes: [UInt8], width: Int, height: Int) throws -> CGImage {
        let cfData = bytes.withUnsafeBytes { rawBuffer in
            CFDataCreate(nil, rawBuffer.bindMemory(to: UInt8.self).baseAddress, bytes.count)
        }
        guard let cfData, let provider = CGDataProvider(data: cfData) else {
            throw StitchingError.compositeImageCreationFailed(width: width, height: height)
        }

        guard let image = CGImage(
            width: width,
            height: height,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: width * 4,
            space: Self.colorSpace,
            bitmapInfo: Self.bitmapInfo,
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        ) else {
            throw StitchingError.compositeImageCreationFailed(width: width, height: height)
        }

        return image
    }

    private func imagesHaveMatchingSize(_ lhs: CGImage, _ rhs: CGImage) -> Bool {
        lhs.width == rhs.width && lhs.height == rhs.height
    }

    private func underestimatedCount<S: Sequence>(for sequence: S) -> Int {
        sequence.underestimatedCount
    }

    private func joinedDiagnostics(_ lhs: String?, _ rhs: String?) -> String? {
        let parts = [lhs, rhs].compactMap { $0 }.filter { !$0.isEmpty }
        guard !parts.isEmpty else {
            return nil
        }
        return parts.joined(separator: " ")
    }

    private static func defaultRegistrationProvider(
        referenceImage: CGImage,
        currentImage: CGImage
    ) -> Result<Translation, Error> {
        do {
            let request = VNTranslationalImageRegistrationRequest(targetedCGImage: currentImage, options: [:])
            let handler = VNImageRequestHandler(cgImage: referenceImage, options: [:])
            try handler.perform([request])

            guard let observation = request.results?.first else {
                return .failure(RegistrationError.observationMissing)
            }

            let transform = observation.alignmentTransform
            return .success(
                Translation(
                    horizontalOffset: transform.tx,
                    verticalOffset: transform.ty,
                    confidence: observation.confidence
                )
            )
        } catch {
            return .failure(error)
        }
    }

    private enum RegistrationError: LocalizedError {
        case observationMissing

        var errorDescription: String? {
            switch self {
            case .observationMissing:
                return "Vision completed image registration without returning an alignment observation."
            }
        }
    }
}
