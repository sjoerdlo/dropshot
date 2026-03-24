import CoreGraphics
import Foundation
import XCTest
@testable import DropShot

final class StitchingEngineTests: XCTestCase {
    private static let colorSpace = CGColorSpaceCreateDeviceRGB()
    private static let bitmapInfo = CGBitmapInfo.byteOrder32Big.union(
        CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue)
    )

    func testBuildCompositeAppendsRowsForForwardMovement() throws {
        let provider = RegistrationProviderStub([
            .success(Self.translation(vertical: 12))
        ])
        let engine = StitchingEngine(registrationProvider: provider.makeProvider())
        let seed = try makeStrip(index: 0, rowBase: 10)
        let appended = try makeStrip(index: 1, rowBase: 100)

        let processed = try engine.addStrips([seed, appended])
        let composite = try engine.buildComposite()

        XCTAssertEqual(processed.count, 2)
        assertDisposition(processed[0].disposition, is: .seed)
        assertDisposition(processed[1].disposition, is: .appended)
        XCTAssertEqual(processed[1].appendedHeight, 12)
        XCTAssertEqual(processed[1].compositeHeight, 36)
        XCTAssertEqual(composite.image.width, 4)
        XCTAssertEqual(composite.image.height, 36)
        XCTAssertEqual(composite.metadata.acceptedStripCount, 2)
        XCTAssertEqual(composite.metadata.rejectedStripCount, 0)
        XCTAssertEqual(try rowMarkers(of: composite.image), try expectedMarkers(seed: seed, appended: appended))
        XCTAssertEqual(provider.requestCount, 1)
    }

    func testBuildCompositePreservesImageOrientation() throws {
        let engine = StitchingEngine()
        let seed = try makeStrip(index: 0, rowBase: 10)

        _ = try engine.addStrip(seed)
        let composite = try engine.buildComposite()

        XCTAssertEqual(try rowMarkers(of: composite.image), Array(10...33))
    }

    func testAddStripRejectsTinyForwardMovementWithoutChangingComposite() throws {
        let provider = RegistrationProviderStub([
            .success(Self.translation(vertical: 11))
        ])
        let engine = StitchingEngine(registrationProvider: provider.makeProvider())
        let seed = try makeStrip(index: 0, rowBase: 10)
        let tinyMovement = try makeStrip(index: 1, rowBase: 100)

        _ = try engine.addStrip(seed)
        let processed = try engine.addStrip(tinyMovement)
        let composite = try engine.buildComposite()

        assertDisposition(processed.disposition, is: .rejected)
        XCTAssertEqual(processed.rejectionReason?.rawValue, StitchingEngine.RejectionReason.insufficientVerticalMovement.rawValue)
        XCTAssertEqual(processed.appendedHeight, 0)
        XCTAssertEqual(processed.compositeHeight, seed.image.height)
        XCTAssertEqual(composite.image.height, seed.image.height)
        XCTAssertEqual(try rowMarkers(of: composite.image), try rowMarkers(of: seed.image))
        XCTAssertEqual(provider.requestCount, 1)
    }

    func testAddStripTrimsCompositeForReverseMovement() throws {
        let provider = RegistrationProviderStub([
            .success(Self.translation(vertical: 12)),
            .success(Self.translation(vertical: -6))
        ])
        let engine = StitchingEngine(registrationProvider: provider.makeProvider())
        let seed = try makeStrip(index: 0, rowBase: 10)
        let appended = try makeStrip(index: 1, rowBase: 100)
        let reverse = try makeStrip(index: 2, rowBase: 200)

        _ = try engine.addStrips([seed, appended])
        let processed = try engine.addStrip(reverse)
        let composite = try engine.buildComposite()

        assertDisposition(processed.disposition, is: .trimmed)
        XCTAssertNil(processed.rejectionReason)
        XCTAssertEqual(processed.appendedHeight, 0)
        XCTAssertEqual(processed.compositeHeight, 30)
        XCTAssertEqual(composite.image.height, 30)
        XCTAssertEqual(composite.metadata.acceptedStripCount, 3)
        XCTAssertEqual(composite.metadata.rejectedStripCount, 0)
        XCTAssertEqual(
            try rowMarkers(of: composite.image),
            try expectedMarkers(seed: seed, appended: appended, trimmedRows: 6)
        )
        XCTAssertEqual(provider.requestCount, 2)
    }

    func testAddStripThrowsWhenCompositeWouldExceedPixelLimit() throws {
        let configuration = StitchingEngine.Configuration(maximumCompositePixelCount: 120)
        let provider = RegistrationProviderStub([
            .success(Self.translation(vertical: 12))
        ])
        let engine = StitchingEngine(
            configuration: configuration,
            registrationProvider: provider.makeProvider()
        )
        let seed = try makeStrip(index: 0, rowBase: 10)
        let oversize = try makeStrip(index: 1, rowBase: 100)

        _ = try engine.addStrip(seed)

        XCTAssertThrowsError(try engine.addStrip(oversize)) { error in
            guard case let StitchingEngine.StitchingError.compositeTooLarge(width, height, maximumPixels) = error else {
                return XCTFail("Expected compositeTooLarge, received \(error).")
            }

            XCTAssertEqual(width, 4)
            XCTAssertEqual(height, 36)
            XCTAssertEqual(maximumPixels, 120)
        }

        XCTAssertEqual(engine.processedStrips.count, 1)
        XCTAssertEqual(try engine.buildComposite().image.height, seed.image.height)
        XCTAssertEqual(provider.requestCount, 1)
    }

    private func makeStrip(index: Int, rowBase: UInt8, width: Int = 4, height: Int = 24) throws -> StitchingEngine.Strip {
        let rowMarkers = (0..<height).map { row in
            UInt8(Int(rowBase) + row)
        }
        return StitchingEngine.Strip(
            index: index,
            image: try makeImage(width: width, rowMarkers: rowMarkers),
            capturedAt: Date(timeIntervalSince1970: TimeInterval(index))
        )
    }

    private func makeImage(width: Int, rowMarkers: [UInt8]) throws -> CGImage {
        let height = rowMarkers.count
        let bytesPerRow = width * 4
        var bytes = [UInt8](repeating: 0, count: height * bytesPerRow)

        for (rowIndex, marker) in rowMarkers.enumerated() {
            for column in 0..<width {
                let offset = rowIndex * bytesPerRow + (column * 4)
                bytes[offset] = marker
                bytes[offset + 1] = UInt8(column)
                bytes[offset + 2] = UInt8(rowIndex)
                bytes[offset + 3] = 255
            }
        }

        guard let provider = CGDataProvider(data: Data(bytes) as CFData),
              let image = CGImage(
                  width: width,
                  height: height,
                  bitsPerComponent: 8,
                  bitsPerPixel: 32,
                  bytesPerRow: bytesPerRow,
                  space: Self.colorSpace,
                  bitmapInfo: Self.bitmapInfo,
                  provider: provider,
                  decode: nil,
                  shouldInterpolate: false,
                  intent: .defaultIntent
              ) else {
            throw TestFailure.imageCreationFailed
        }

        return image
    }

    private func rowMarkers(of image: CGImage) throws -> [UInt8] {
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
            context.translateBy(x: 0, y: CGFloat(image.height))
            context.scaleBy(x: 1, y: -1)
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            return true
        }

        guard wasRasterized else {
            throw TestFailure.rasterizationFailed
        }

        return stride(from: 0, to: bytes.count, by: bytesPerRow).map { bytes[$0] }
    }

    private func expectedMarkers(
        seed: StitchingEngine.Strip,
        appended: StitchingEngine.Strip,
        trimmedRows: Int = 0
    ) throws -> [UInt8] {
        let seedMarkers = try rowMarkers(of: seed.image)
        let appendedMarkers = try rowMarkers(of: appended.image)
        let appendedStart = appended.image.height - 12
        let appendedEnd = appended.image.height - trimmedRows

        return seedMarkers + Array(appendedMarkers[appendedStart..<appendedEnd])
    }

    private func assertDisposition(
        _ actual: StitchingEngine.StripDisposition,
        is expected: StitchingEngine.StripDisposition,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        switch (actual, expected) {
        case (.seed, .seed), (.appended, .appended), (.trimmed, .trimmed), (.rejected, .rejected):
            return
        default:
            XCTFail("Expected disposition \(expected) but received \(actual).", file: file, line: line)
        }
    }

    private static func translation(
        horizontal: CGFloat = 0,
        vertical: CGFloat,
        confidence: Float = 1
    ) -> StitchingEngine.Translation {
        StitchingEngine.Translation(
            horizontalOffset: horizontal,
            verticalOffset: vertical,
            confidence: confidence
        )
    }
}

private final class RegistrationProviderStub {
    private var results: [Result<StitchingEngine.Translation, Error>]

    private(set) var requestCount = 0

    init(_ results: [Result<StitchingEngine.Translation, Error>]) {
        self.results = results
    }

    func makeProvider() -> StitchingEngine.RegistrationProvider {
        { [self] _, _ in
            requestCount += 1
            guard !results.isEmpty else {
                return .failure(TestFailure.unexpectedRegistrationRequest)
            }
            return results.removeFirst()
        }
    }
}

private enum TestFailure: LocalizedError {
    case imageCreationFailed
    case rasterizationFailed
    case unexpectedRegistrationRequest

    var errorDescription: String? {
        switch self {
        case .imageCreationFailed:
            return "The test fixture image could not be created."
        case .rasterizationFailed:
            return "The test fixture image could not be rasterized."
        case .unexpectedRegistrationRequest:
            return "The test requested more registration results than were configured."
        }
    }
}
