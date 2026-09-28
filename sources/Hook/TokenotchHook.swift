import Foundation
import TokenotchCore
import os

@main
enum TokenotchHook {
    static func main() {
        do {
            let args = CommandLine.arguments
            guard args.count == 3, let client = Client(rawValue: args[1]) else { throw TokenotchError.invalidEvent }
            let data = try LocalBridge.readMessage(STDIN_FILENO, limit: HookNormalizer.inputLimit,
                                                   milliseconds: 500, newlineTerminated: false)
            guard let event = try HookNormalizer.normalizeObservation(data, source: client, hook: args[2]) else { return }
            try LocalBridge.send(event)
        } catch {
            // No stdout, approval decision, payload, or path reaches the agent.
            Logger(subsystem: "io.github.rottathiago.tokenotch", category: "bridge")
                .error("Hook delivery unavailable; inspect Tokenotch integration status.")
            do {
                let marker = (error as? TokenotchError) == .metricUpgrade ? "metric-upgrade" : "Hook delivery unavailable"
                try PrivateFiles.write(Data(marker.utf8),
                                       to: PrivateFiles.root.appendingPathComponent("bridge-failure"))
            } catch {
                Logger(subsystem: "io.github.rottathiago.tokenotch", category: "bridge")
                    .error("Could not save bridge-health marker.")
            }
        }
    }
}
