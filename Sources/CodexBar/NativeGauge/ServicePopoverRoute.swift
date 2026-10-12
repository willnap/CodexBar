struct ServicePopoverRoute<Service: Equatable> {
    private(set) var provider: Service?

    mutating func toggle(_ service: Service) {
        self.provider = self.provider == service ? nil : service
    }

    mutating func dismiss() {
        self.provider = nil
    }
}
