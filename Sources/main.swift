import AppKit

let app = NSApplication.shared

if CommandLine.arguments.contains("--list") {
    DisplayManager.printSummary()
    exit(0)
}

let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
