import Foundation
import SafeNetCore
import SafeNetUI

// Two modes of the same binary:
//  - `SafeNetApp --watchdog <parentPID> <journalPath>`: the watchdog child started by the app.
//    No UI, no AppKit: it waits for the parent to die, resumes whatever is still journaled, exits.
//  - `SafeNetApp <command> [args]` (status, allow, panel, config, version): console client of the
//    running app (unix socket); no AppKit, no Dock icon, exits with its own code.
//  - otherwise: the menu-bar app.
let args = CommandLine.arguments
if args.count >= 4, args[1] == "--watchdog", let parent = Int32(args[2]), parent > 1 {
    // Survive Ctrl-C / terminal hang-up aimed at the app's process group: the watchdog's job
    // starts exactly when the parent is gone.
    signal(SIGINT, SIG_IGN)
    signal(SIGHUP, SIG_IGN)
    Freezer.runWatchdog(parent: parent, journal: URL(fileURLWithPath: args[3]))
    exit(0)
} else if args.count >= 2, args[1] == "--watchdog" {
    FileHandle.standardError.write(Data("usage: SafeNetApp --watchdog <parentPID> <journalPath>\n".utf8))
    exit(2)
}

if isCLIInvocation(args) {
    exit(runCLIClient(Array(args.dropFirst()),
                      out: { print($0) },
                      err: { FileHandle.standardError.write(Data(($0 + "\n").utf8)) }))
}

SafeNetMenuApp.main()
