import Darwin
import Foundation
import SwiftUI

struct S2FDAApp: App {
    @State private var model = ProbeModel()

    var body: some Scene {
        WindowGroup("S2 Full Disk Access Probe") {
            ContentView(model: model)
        }
        .defaultSize(width: 880, height: 700)
    }
}

/// Entry point. `--cli` runs the probes once, prints the table and exits.
@main
struct S2FDALauncher {
    @MainActor
    static func main() {
        if CommandLine.arguments.contains("--cli") {
            let report = ProbeRunner.runBlocking()
            FileHandle.standardOutput.write(Data((report.plainText() + "\n").utf8))
            exit(0)
        }
        S2FDAApp.main()
    }
}
