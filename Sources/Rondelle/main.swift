import AppKit

// Command-line mode, for testing and scripting without dragging:
//   Rondelle --list [--tools] FILE…               lists the wheel's actions for these files
//   Rondelle --run [--tools] "TITLE" FILE…        runs one action and prints the outputs
//   Rondelle --render [--tools] OUT.png FILE…     saves a picture of the wheel
// Only in DEBUG test builds (see README → Testing): the release app has no command line at all.
Settings.register()
#if DEBUG
let args = Array(CommandLine.arguments.dropFirst())
let isInstalledApp = Bundle.main.bundleURL.pathExtension == "app"
if !isInstalledApp, let command = args.first, command.hasPrefix("--") {
    var rest = Array(args.dropFirst())
    let mode: WheelMode = rest.first == "--tools" ? .tools : rest.first == "--share" ? .share : .convert
    if mode != .convert { rest.removeFirst() }
    exit(MainActor.assumeIsolated { CLI.run(command, mode: mode, rest) })
}
#endif

#if UPDATE_TEST
if CommandLine.arguments.count == 4, CommandLine.arguments[1] == "--update-test-compare" {
    print(Updates.isNewer(CommandLine.arguments[2], than: CommandLine.arguments[3]) ? "si" : "no")
    exit(0)
}
if CommandLine.arguments.contains("--feedback-reach") {
    // The service answers from the sandbox: a kind it refuses, so that nothing is sent.
    MainActor.assumeIsolated {
        Feedback.send(kind: "prova", message: "x", email: "", includeVersions: false) { result in
            print("INVIO \(result)")
            exit(0)
        }
    }
    RunLoop.main.run()
}
if CommandLine.arguments.contains("--feedback-test") {
    // One real message through the service, from the sandbox: only by hand, see Tests/feedback/run.sh.
    MainActor.assumeIsolated {
        Feedback.send(kind: "altro", message: "Prova di collegamento dall'app Rondelle: si può cancellare.", email: "", includeVersions: true) { result in
            print("INVIO \(result)")
            exit(result == "ok" ? 0 : 1)
        }
    }
    RunLoop.main.run()
}
if CommandLine.arguments.contains("--update-test") {
    MainActor.assumeIsolated { Updates.selfTest() }
    RunLoop.main.run()
}
#endif

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    app.run()
}
