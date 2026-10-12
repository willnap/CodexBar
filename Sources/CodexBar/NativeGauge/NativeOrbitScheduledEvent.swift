import Foundation

struct NativeOrbitScheduledEvent: Identifiable {
    let id: String
    let date: Date
    let label: String
    let recoveryPercent: Double?

    var help: String {
        let event = self.recoveryPercent.map {
            "Next recovery · \($0.formatted(.number.precision(.fractionLength(0...2))))%"
        } ?? "Reset"
        return "\(self.label) · \(event) · \(self.date.formatted(date: .abbreviated, time: .shortened))"
    }
}
