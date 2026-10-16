import Foundation
import Testing
@testable import CodexBar

@MainActor struct NativeOrbitBadgeVisionBudgetTests {
    private enum Failure: Error { case imageCount, imageResponse, textResponse }

    @Test func imageCountingFailureCanStillUseTheSmallPreview() async throws {
        var trace = NativeOrbitBadgeModel.PreviewTrace()
        let value = try await NativeOrbitBadgeModel.optionalPreviewResponse(
            textTokenCount: 500,
            contextSize: 4096,
            hasPreview: true,
            imageTokenCount: { throw Failure.imageCount },
            respond: { $0 ? "preview response" : "text response" },
            observe: { trace = $0 })
        #expect(value == "preview response")
        #expect(trace.attempted && trace.used)
        #expect(trace.preflightError != nil)
        #expect(trace.fallbackReason == nil)
    }

    @Test func failedImageResponseRetriesIdenticalFullText() async throws {
        let fullContext = "Target: Repairs. Peers: full long peer descriptions preserved."
        var inputs: [(Bool, String)] = []
        var trace = NativeOrbitBadgeModel.PreviewTrace()
        let value = try await NativeOrbitBadgeModel.optionalPreviewResponse(
            textTokenCount: 800,
            contextSize: 4096,
            hasPreview: true,
            imageTokenCount: { 1200 },
            respond: { usePreview in
                inputs.append((usePreview, fullContext))
                if usePreview { throw Failure.imageResponse }
                return fullContext
            },
            observe: { trace = $0 })
        #expect(value == fullContext)
        #expect(inputs.map(\.0) == [true, false])
        #expect(inputs.map(\.1) == [fullContext, fullContext])
        #expect(trace.attempted && !trace.used)
        #expect(trace.fallbackReason != nil)
    }

    @Test func unknownImageSizeCannotConsumeTheTextResponseReserve() async throws {
        var trace = NativeOrbitBadgeModel.PreviewTrace()
        let value = try await NativeOrbitBadgeModel.optionalPreviewResponse(
            textTokenCount: 3000,
            contextSize: 4096,
            hasPreview: true,
            imageTokenCount: { throw Failure.imageCount },
            respond: { $0 ? "image" : "full text" },
            observe: { trace = $0 })
        #expect(value == "full text")
        #expect(!trace.attempted && !trace.used)
        #expect(trace.preflightError != nil && trace.fallbackReason != nil)
    }

    @Test func oversizedImageFallsBackWithoutReducingPeerContext() async throws {
        var trace = NativeOrbitBadgeModel.PreviewTrace()
        let value = try await NativeOrbitBadgeModel.optionalPreviewResponse(
            textTokenCount: 700,
            contextSize: 4096,
            hasPreview: true,
            imageTokenCount: { 4000 },
            respond: { $0 ? "image" : "complete text" },
            observe: { trace = $0 })
        #expect(value == "complete text")
        #expect(!trace.attempted && !trace.used)
        #expect(trace.fallbackReason != nil)
    }

    @Test func successfulExactImageCountNeedsNoEstimatedImageReserve() async throws {
        var trace = NativeOrbitBadgeModel.PreviewTrace()
        let value = try await NativeOrbitBadgeModel.optionalPreviewResponse(
            textTokenCount: 3000,
            contextSize: 4096,
            hasPreview: true,
            imageTokenCount: { 3500 },
            respond: { $0 ? "image" : "text" },
            observe: { trace = $0 })
        #expect(value == "image")
        #expect(trace.attempted && trace.used)
        #expect(trace.preflightError == nil && trace.fallbackReason == nil)
    }

    @Test func noPreviewUsesTextWithoutCallingImageAPI() async throws {
        var trace = NativeOrbitBadgeModel.PreviewTrace()
        let value = try await NativeOrbitBadgeModel.optionalPreviewResponse(
            textTokenCount: 800,
            contextSize: 4096,
            hasPreview: false,
            imageTokenCount: { throw Failure.imageCount },
            respond: { $0 ? "image" : "text" },
            observe: { trace = $0 })
        #expect(value == "text")
        #expect(!trace.attempted && !trace.used)
        #expect(trace.preflightError == nil && trace.fallbackReason == nil)
    }

    @Test func invalidTextBudgetStopsBeforeAnyInference() async {
        var called = false
        do {
            _ = try await NativeOrbitBadgeModel.optionalPreviewResponse(
                textTokenCount: 4000,
                contextSize: 4096,
                hasPreview: true,
                imageTokenCount: { called = true; return 1 },
                respond: { _ in called = true; return "wrong" })
            Issue.record("Over-budget text must fail before either model path")
        } catch {}
        #expect(!called)
    }

    @Test func textFailureRemainsTheErrorAfterOptionalImageFailure() async {
        var trace = NativeOrbitBadgeModel.PreviewTrace()
        do {
            _ = try await NativeOrbitBadgeModel.optionalPreviewResponse(
                textTokenCount: 500,
                contextSize: 4096,
                hasPreview: true,
                imageTokenCount: { 1000 },
                respond: { usePreview -> String in
                    throw usePreview ? Failure.imageResponse : Failure.textResponse
                },
                observe: { trace = $0 })
            Issue.record("Both responses fail")
        } catch {
            #expect(error as? Failure == .textResponse)
        }
        #expect(trace.attempted && !trace.used && trace.fallbackReason != nil)
    }

    @Test func cancelledImageResponseDoesNotStartTextRetry() async {
        var calls: [Bool] = []
        do {
            _ = try await NativeOrbitBadgeModel.optionalPreviewResponse(
                textTokenCount: 500,
                contextSize: 4096,
                hasPreview: true,
                imageTokenCount: { 1000 },
                respond: { usePreview -> String in
                    calls.append(usePreview)
                    throw CancellationError()
                })
            Issue.record("Cancellation must propagate")
        } catch { #expect(error is CancellationError) }
        #expect(calls == [true])
    }

    @Test func cancelledImageCountDoesNotStartEitherResponse() async {
        var called = false
        do {
            _ = try await NativeOrbitBadgeModel.optionalPreviewResponse(
                textTokenCount: 500,
                contextSize: 4096,
                hasPreview: true,
                imageTokenCount: { throw CancellationError() },
                respond: { _ in called = true; return "wrong" })
            Issue.record("Cancellation must propagate")
        } catch { #expect(error is CancellationError) }
        #expect(!called)
    }

    @Test func fullTextContextSurvivesBothOptionalImageFailures() async throws {
        var trace = NativeOrbitBadgeModel.PreviewTrace()
        let value = try await NativeOrbitBadgeModel.optionalPreviewResponse(
            textTokenCount: 800,
            contextSize: 4096,
            hasPreview: true,
            imageTokenCount: { throw Failure.imageCount },
            respond: { usePreview in
                if usePreview { throw Failure.imageResponse }
                return "same complete text succeeds"
            },
            observe: { trace = $0 })
        #expect(value == "same complete text succeeds")
        #expect(trace.attempted && !trace.used)
        #expect(trace.preflightError != nil && trace.fallbackReason != nil)
    }

    @Test func textBudgetRetainsFullPeersWhenTheyFit() async throws {
        var requestedBudgets: [Int] = []
        let accepted = try await NativeOrbitBadgeModel.budgetedText(
            contextSize: 4096,
            makeText: { bytes in
                requestedBudgets.append(bytes)
                return "full target and peer context"
            },
            tokenCount: { _ in 3000 })
        #expect(accepted.text == "full target and peer context")
        #expect(accepted.tokens == 3000)
        #expect(requestedBudgets == [256])
    }

    @Test func peersShrinkOnlyWhenTextAloneExceedsBudget() async throws {
        var requestedBudgets: [Int] = []
        let accepted = try await NativeOrbitBadgeModel.budgetedText(
            contextSize: 4096,
            makeText: { bytes in
                requestedBudgets.append(bytes)
                return bytes == 256 ? "full peers" : "bounded peers"
            },
            tokenCount: { $0 == "full peers" ? 3800 : 1200 })
        #expect(accepted.text == "bounded peers")
        #expect(requestedBudgets == [256, 128])
    }

    @Test func noTextContextThatFitsNeverStartsAnUnboundedAttempt() async {
        var requestedBudgets: [Int] = []
        do {
            _ = try await NativeOrbitBadgeModel.budgetedText(
                contextSize: 4096,
                makeText: { bytes in requestedBudgets.append(bytes); return "large target" },
                tokenCount: { _ in 4000 })
            Issue.record("An impossible text budget must fail")
        } catch {}
        #expect(requestedBudgets == [256, 128, 64, 32])
    }

    @Test(arguments: [true, false])
    func responseThatIgnoresCancellationCannotBecomeASuccess(_ hasPreview: Bool) async {
        var trace = NativeOrbitBadgeModel.PreviewTrace()
        let task = Task { @MainActor in
            try await NativeOrbitBadgeModel.optionalPreviewResponse(
                textTokenCount: 500,
                contextSize: 4096,
                hasPreview: hasPreview,
                imageTokenCount: { 1000 },
                respond: { _ in
                    withUnsafeCurrentTask { $0?.cancel() }
                    return "cancelled response"
                },
                observe: { trace = $0 })
        }
        do {
            _ = try await task.value
            Issue.record("A response returned after cancellation must not be accepted")
        } catch { #expect(error is CancellationError) }
        #expect(!trace.used)
    }
}
