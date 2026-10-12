@main
enum NativeServiceRouteProof {
    static func main() {
        var route = ServicePopoverRoute<String>()
        route.toggle("codex")
        precondition(route.provider == "codex", "First click must open the clicked service")
        route.toggle("claude")
        precondition(route.provider == "claude", "Another service must switch directly")
        route.toggle("claude")
        precondition(route.provider == nil, "Second click must dismiss")
        route.toggle("kimi")
        route.dismiss()
        precondition(route.provider == nil, "Outside click dismissal must clear the route")
        print("Service popover routing: 4 checks passed")
    }
}
