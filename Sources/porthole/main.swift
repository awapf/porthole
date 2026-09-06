import AppKit
import PortholeCore

setbuf(stdout, nil)

let arguments = Array(CommandLine.arguments.dropFirst())

func die(_ message: String) -> Never {
    FileHandle.standardError.write(Data("porthole: \(message)\n".utf8))
    exit(2)
}

let options: Options
do {
    options = try Options.parse(arguments)
} catch CLIError.showUsage {
    print(Options.usage)
    exit(arguments.isEmpty ? 1 : 0)
} catch CLIError.showVersion {
    print(Porthole.versionString)
    exit(0)
} catch CLIError.initConfig {
    do {
        let path = try PortholeConfig.writeTemplate()
        print("wrote \(path.path)")
        exit(0)
    } catch {
        die("could not write the config: \(error)")
    }
} catch CLIError.missingValue(let flag) {
    die("\(flag) needs a value")
} catch CLIError.unknownFlag(let flag) {
    die("unknown option \(flag) — run `porthole --help`")
} catch CLIError.badValue(let flag, let value) {
    die("\(value) is not valid for \(flag)")
} catch {
    die("\(error)")
}

// Diagnostic path: no window, no Metal, just the decoded pixels.
if options.testInput {
    FrameDumper(path: "", verbose: options.verbose).runInputTest(options: options)
}
if let path = options.dumpFrame {
    FrameDumper(path: path, verbose: options.verbose).run(options: options)
}

// Our subclass, so it becomes NSApp — this is what rescues key-up events
// swallowed while Command is held.
let application = PortholeApplication.shared
let delegate = AppDelegate(options: options)
application.delegate = delegate

// A menu is what gives a bare CLI binary working ⌘Q and standard edit keys.
let menu = NSMenu()
let appMenuItem = NSMenuItem()
menu.addItem(appMenuItem)
let appMenu = NSMenu()
appMenu.addItem(withTitle: "Quit porthole", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
appMenuItem.submenu = appMenu
application.mainMenu = menu

application.run()
