import Foundation

@main
enum WindowsContractSmoke {
    static func main() throws {
        try WindowsContractChecks.run()
        print("Shared Windows/macOS hook and live-state contracts passed.")
    }
}
