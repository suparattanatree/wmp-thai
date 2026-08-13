import AppKit
import WmpCore

if let index = CommandLine.arguments.firstIndex(of: "--score"), CommandLine.arguments.count > index + 1 {
    ScoreDebug.run(CommandLine.arguments[index + 1])
    exit(0)
}

if let index = CommandLine.arguments.firstIndex(of: "--try"), CommandLine.arguments.count > index + 1 {
    TryDebug.run(CommandLine.arguments[index + 1])
    exit(0)
}

if let index = CommandLine.arguments.firstIndex(of: "--typo"), CommandLine.arguments.count > index + 1 {
    TypoDebug.run(CommandLine.arguments[index + 1])
    exit(0)
}

if CommandLine.arguments.contains("--sweep") {
    WordListSweep.run()
    exit(0)
}

if CommandLine.arguments.contains("--probe") {
    ProbeDebug.run()
    exit(0)
}

if CommandLine.arguments.contains("--selftest") {
    SelfTest.run()
    exit(0)
}

let delegate = AppDelegate()
let app = NSApplication.shared
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
