import Foundation
import Testing
@testable import CodexBarCore

struct ProviderStatusIncidentTests {
    @Test func `HTTP error status is rejected even when its body looks healthy`() async throws {
        let transport = ProviderHTTPTransportStub { request in
            let url = try #require(request.url)
            return (
                Data(#"{"status":{"indicator":"none"}}"#.utf8),
                HTTPURLResponse(url: url, statusCode: 503, httpVersion: nil, headerFields: nil)!)
        }
        await #expect(throws: ProviderStatusFetchError.httpStatus(503)) {
            try await ProviderStatusFetcher.fetchStatus(
                from: #require(URL(string: "https://status.example.test")), transport: transport)
        }
    }

    @Test func `statuspage summary keeps incident source fields and scheduled maintenance`() throws {
        let status = try ProviderStatusFetcher.parseStatuspageStatus(data: Data(#"""
        {"status":{"indicator":"minor"},"incidents":[
          {"id":"incident","name":"Codex errors","status":"monitoring","impact":"minor",
           "updated_at":"2026-10-15T10:00:00Z","components":[{"id":"codex","name":"Codex"}]}],
         "scheduled_maintenances":[
          {"id":"work","name":"Codex work","status":"scheduled","impact":"maintenance",
           "scheduled_for":"2026-10-15T12:00:00Z","scheduled_until":"2026-10-15T13:00:00Z",
           "components":[{"id":"codex"}]}]}
        """#.utf8))
        let incidents = try #require(status.incidents)
        #expect(incidents.count == 2)
        #expect(incidents[0].title == "Codex errors")
        #expect(incidents[0].phase == "monitoring")
        #expect(incidents[0].componentIDs == ["codex"])
        #expect(incidents[0].updatedAt != nil)
        #expect(incidents[1].scheduledFor != nil)
        #expect(incidents[1].scheduledUntil != nil)
    }

    @Test func `absent incidents remain unknown rather than a fabricated empty feed`() throws {
        let status = try ProviderStatusFetcher.parseStatuspageStatus(
            data: Data(#"{"status":{"indicator":"none"}}"#.utf8))
        #expect(status.incidents == nil)
    }
}
