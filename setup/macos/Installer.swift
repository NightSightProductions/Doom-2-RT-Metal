// "Install DOOM 2 RT": unpacks DOOM 2 RT.app (an Apple Archive in this installer's Resources:
// as a nested app, it would prevent signing the installer) to Applications,
// and the user's DOOM2.WAD to ~/Library/Application Support/GZDoom, where gzdoom finds IWADs.
// DOOM2.WAD is not distributed: it's found in the user's Steam libraries (also in CrossOver
// bottles), or chosen by the user.
//
// installer --detect   prints the detected DOOM2.WAD, for testing

import AppKit

let appName    = "DOOM 2 RT"
let iwadName   = "DOOM2.WAD"
let fm         = FileManager.default
let home       = fm.homeDirectoryForCurrentUser
let iwadFolder = home.appendingPathComponent("Library/Application Support/GZDoom")

// MARK: - DOOM2.WAD

enum IwadCheck {
    case valid
    case invalid(String)
}

// a DOOM II IWAD: "IWAD" header, and MAP01..MAP30 in its directory
func checkIwad(_ url: URL) -> IwadCheck {
    guard let h = try? FileHandle(forReadingFrom: url) else { return .invalid("Can't read the file.") }
    defer { try? h.close() }
    guard let header = try? h.read(upToCount: 12), header.count == 12 else { return .invalid("Not a WAD file.") }
    guard String(data: header.prefix(4), encoding: .ascii) == "IWAD" else {
        return .invalid("Not an IWAD (game data) file.")
    }
    func u32(_ d: Data, _ o: Int) -> Int {
        Int(d[d.startIndex + o]) | Int(d[d.startIndex + o + 1]) << 8 |
            Int(d[d.startIndex + o + 2]) << 16 | Int(d[d.startIndex + o + 3]) << 24
    }
    let count = u32(header, 4), offset = u32(header, 8)
    guard count > 0, count < 100_000 else { return .invalid("Not a valid WAD file.") }
    do {
        try h.seek(toOffset: UInt64(offset))
        guard let dir = try h.read(upToCount: count * 16), dir.count == count * 16 else {
            return .invalid("The WAD file is damaged.")
        }
        var names = Set< String >()
        for i in 0 ..< count {
            let raw = dir[dir.startIndex + i * 16 + 8 ..< dir.startIndex + i * 16 + 16]
            names.insert(String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self).uppercased())
        }
        guard names.contains("MAP01"), names.contains("MAP30") else {
            return .invalid("This is not DOOM II's game data (DOOM2.WAD).")
        }
    } catch {
        return .invalid("Can't read the file.")
    }
    return .valid
}

// Steam's library folders, from its libraryfolders.vdf; 'driveC' maps Windows paths (CrossOver)
func steamLibraries(steamDir: URL, driveC: URL? = nil) -> [URL] {
    var result = [steamDir.appendingPathComponent("steamapps")]
    let vdf = steamDir.appendingPathComponent("steamapps/libraryfolders.vdf")
    guard let text = try? String(contentsOf: vdf, encoding: .utf8) else { return result }
    for line in text.split(separator: "\n") {
        let parts = line.split(separator: "\"").map(String.init)
        // "path"		"..."
        guard parts.count >= 4, parts[1] == "path" else { continue }
        var path = parts[3].replacingOccurrences(of: "\\\\", with: "/")
        if let c = driveC {
            guard path.lowercased().hasPrefix("c:") else { continue }
            path = c.path + path.dropFirst(2)
        }
        result.append(URL(fileURLWithPath: path).appendingPathComponent("steamapps"))
    }
    return result
}

func detectIwad() -> URL? {
    var candidates: [URL] = [iwadFolder.appendingPathComponent(iwadName)]

    var libraries = steamLibraries(steamDir: home.appendingPathComponent("Library/Application Support/Steam"))
    // Steam for Windows in CrossOver bottles
    let bottles = home.appendingPathComponent("Library/Application Support/CrossOver/Bottles")
    for bottle in (try? fm.contentsOfDirectory(at: bottles, includingPropertiesForKeys: nil)) ?? [] {
        let c = bottle.appendingPathComponent("drive_c")
        for steam in ["Program Files (x86)/Steam", "Program Files/Steam"] {
            libraries += steamLibraries(steamDir: c.appendingPathComponent(steam), driveC: c)
        }
    }
    // DOOM + DOOM II (2024) keeps the original DOOM2.WAD in "base/doom2"
    let inLibrary = [
        "common/Ultimate Doom/base/doom2/DOOM2.WAD",
        "common/Doom 2/base/DOOM2.WAD",
        "common/Doom 2/base/doom2/DOOM2.WAD",
        "common/Doom 2/doom2/DOOM2.WAD",
        "common/Doom 2/DOOM2.WAD",
        "common/Ultimate Doom/rerelease/DOOM2.WAD",
        "common/Doom 2/rerelease/DOOM2.WAD",
    ]
    for lib in libraries {
        candidates += inLibrary.map { lib.appendingPathComponent($0) }
    }
    candidates += ["Documents", "Downloads", "Desktop"].map { home.appendingPathComponent($0).appendingPathComponent(iwadName) }

    return candidates.first { fm.fileExists(atPath: $0.path) && { if case .valid = checkIwad($0) { return true }; return false }($0) }
}

// MARK: - UI helpers

func label(_ text: String, size: CGFloat = 13, bold: Bool = false) -> NSTextField {
    let l = NSTextField(wrappingLabelWithString: text)
    l.font = bold ? .boldSystemFont(ofSize: size) : .systemFont(ofSize: size)
    l.translatesAutoresizingMaskIntoConstraints = false
    return l
}

func button(_ title: String, _ target: AnyObject, _ action: Selector) -> NSButton {
    let b = NSButton(title: title, target: target, action: action)
    b.translatesAutoresizingMaskIntoConstraints = false
    b.bezelStyle = .rounded
    return b
}

func stack(_ views: [NSView], spacing: CGFloat = 12) -> NSStackView {
    let s = NSStackView(views: views)
    s.orientation = .vertical
    s.alignment = .leading
    s.spacing = spacing
    s.translatesAutoresizingMaskIntoConstraints = false
    return s
}

func q(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }

@discardableResult
func run(_ tool: String, _ args: [String]) -> Int32 {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: tool)
    p.arguments = args
    p.standardOutput = FileHandle.nullDevice
    p.standardError = FileHandle.nullDevice
    do { try p.run() } catch { return -1 }
    p.waitUntilExit()
    return p.terminationStatus
}

// MARK: - Wizard

final class Wizard: NSObject, NSApplicationDelegate {
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 620, height: 400),
                          styleMask: [.titled, .closable], backing: .buffered, defer: false)
    let content = NSView()
    let back = NSButton()
    let next = NSButton()

    let payload = Bundle.main.resourceURL!.appendingPathComponent("\(appName).aar")
    var iwad: URL?
    var installed: URL?

    enum Page { case welcome, game, install, done }
    var page = Page.welcome

    // game page
    let pathField = NSTextField(labelWithString: "")
    let statusField = label("")

    // install page
    let progress = NSProgressIndicator()
    let progressText = label("")

    func applicationDidFinishLaunching(_ notification: Notification) {
        window.title = "Install \(appName)"
        window.center()

        let root = NSView()
        window.contentView = root

        let icon = NSImageView(image: NSApp.applicationIconImage)
        icon.translatesAutoresizingMaskIntoConstraints = false
        content.translatesAutoresizingMaskIntoConstraints = false

        for (b, title, action) in [(back, "Back", #selector(goBack)), (next, "Continue", #selector(goNext))] {
            b.title = title
            b.bezelStyle = .rounded
            b.target = self
            b.action = action
            b.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(b)
        }
        next.keyEquivalent = "\r"
        root.addSubview(icon)
        root.addSubview(content)

        NSLayoutConstraint.activate([
            icon.topAnchor.constraint(equalTo: root.topAnchor, constant: 24),
            icon.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 24),
            icon.widthAnchor.constraint(equalToConstant: 96),
            icon.heightAnchor.constraint(equalToConstant: 96),
            content.topAnchor.constraint(equalTo: root.topAnchor, constant: 24),
            content.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 24),
            content.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -24),
            content.bottomAnchor.constraint(equalTo: next.topAnchor, constant: -16),
            next.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -20),
            next.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -20),
            next.widthAnchor.constraint(greaterThanOrEqualToConstant: 110),
            back.trailingAnchor.constraint(equalTo: next.leadingAnchor, constant: -8),
            back.bottomAnchor.constraint(equalTo: next.bottomAnchor),
            back.widthAnchor.constraint(greaterThanOrEqualToConstant: 110),
        ])

        iwad = detectIwad()
        show(.welcome)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func setContent(_ view: NSView) {
        content.subviews.forEach { $0.removeFromSuperview() }
        content.addSubview(view)
        NSLayoutConstraint.activate([
            view.topAnchor.constraint(equalTo: content.topAnchor),
            view.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            view.trailingAnchor.constraint(equalTo: content.trailingAnchor),
        ])
    }

    func show(_ p: Page) {
        page = p
        switch p {
        case .welcome:
            setContent(stack([
                label("Welcome to \(appName)", size: 20, bold: true),
                label("This installs \(appName), a path traced version of DOOM II for Apple silicon Macs, into your Applications folder."),
                label("It needs the game data from your own copy of DOOM II (\(iwadName)), for example from Steam. The installer looks for it, or you can choose it."),
            ]))
            back.isHidden = true
            next.title = "Continue"
            next.isEnabled = true

        case .game:
            pathField.lineBreakMode = .byTruncatingMiddle
            pathField.translatesAutoresizingMaskIntoConstraints = false
            let browse = button("Choose…", self, #selector(browse))
            setContent(stack([
                label("DOOM II game data", size: 20, bold: true),
                label("The installer copies \(iwadName) to ~/Library/Application Support/GZDoom, where \(appName) finds it."),
                pathField,
                browse,
                statusField,
            ]))
            pathField.widthAnchor.constraint(equalTo: content.widthAnchor).isActive = true
            back.isHidden = false
            next.title = "Install"
            updateIwad()

        case .install:
            progress.style = .bar
            progress.isIndeterminate = true
            progress.translatesAutoresizingMaskIntoConstraints = false
            setContent(stack([label("Installing…", size: 20, bold: true), progress, progressText]))
            progress.widthAnchor.constraint(equalTo: content.widthAnchor).isActive = true
            progress.startAnimation(nil)
            back.isHidden = true
            next.isEnabled = false
            install()

        case .done:
            setContent(stack([
                label("\(appName) is installed", size: 20, bold: true),
                label("You can open it from your Applications folder."),
                label("Graphics settings: Options → Graphics (or the RT options in the main menu)."),
            ]))
            back.title = "Quit"
            back.isHidden = false
            next.title = "Open \(appName)"
            next.isEnabled = true
        }
    }

    func updateIwad() {
        guard let url = iwad else {
            pathField.stringValue = "\(iwadName) was not found."
            statusField.stringValue = "Choose your DOOM II's \(iwadName) (in Steam: steamapps/common/Doom 2/base, or Ultimate Doom/base/doom2)."
            next.isEnabled = false
            return
        }
        pathField.stringValue = url.path
        switch checkIwad(url) {
        case .valid:
            statusField.stringValue = "✓ DOOM II game data"
            next.isEnabled = true
        case .invalid(let reason):
            statusField.stringValue = reason
            next.isEnabled = false
        }
    }

    @objc func browse() {
        let panel = NSOpenPanel()
        panel.message = "Choose DOOM II's \(iwadName)"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.beginSheetModal(for: window) { r in
            if r == .OK, let url = panel.url {
                self.iwad = url
                self.updateIwad()
            }
        }
    }

    @objc func goBack() {
        switch page {
        case .game: show(.welcome)
        case .done: NSApp.terminate(nil)
        default: break
        }
    }

    @objc func goNext() {
        switch page {
        case .welcome: show(.game)
        case .game: show(.install)
        case .done:
            if let app = installed { NSWorkspace.shared.open(app) }
            NSApp.terminate(nil)
        default: break
        }
    }

    func status(_ s: String) { DispatchQueue.main.async { self.progressText.stringValue = s } }

    func fail(_ s: String) {
        DispatchQueue.main.async {
            let a = NSAlert()
            a.messageText = "The installation failed"
            a.informativeText = s
            a.alertStyle = .critical
            a.runModal()
            self.show(.game)
        }
    }

    func install() {
        guard let source = iwad else { return }
        DispatchQueue.global(qos: .userInitiated).async {
            // the game data
            self.status("Copying \(iwadName)…")
            let dst = iwadFolder.appendingPathComponent(iwadName)
            if source.standardizedFileURL != dst.standardizedFileURL {
                do {
                    try fm.createDirectory(at: iwadFolder, withIntermediateDirectories: true)
                    if fm.fileExists(atPath: dst.path) {
                        try fm.removeItem(at: dst)
                    }
                    try fm.copyItem(at: source, to: dst)
                } catch {
                    return self.fail("Can't copy \(iwadName): \(error.localizedDescription)")
                }
            }

            // the app: /Applications, or ~/Applications if that's not possible without a password and it's declined
            self.status("Copying \(appName) to Applications (about 2 GB)…")
            guard fm.fileExists(atPath: self.payload.path) else {
                return self.fail("This installer is incomplete: \(appName).aar is missing.")
            }
            let target = URL(fileURLWithPath: "/Applications/\(appName).app")
            let copy = "rm -rf \(q(target.path)) && mkdir -p \(q(target.path)) && " +
                "aa extract -d \(q(target.path)) -i \(q(self.payload.path)) && xattr -dr com.apple.quarantine \(q(target.path))"
            if run("/bin/sh", ["-c", copy]) != 0 {
                // needs an administrator
                let script = "do shell script \"\(copy.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\""))\" with administrator privileges"
                if run("/usr/bin/osascript", ["-e", script]) != 0 {
                    return self.fail("Can't copy \(appName) to the Applications folder.")
                }
            }
            // downloaded files are quarantined, and the app isn't notarized
            run("/usr/bin/xattr", ["-dr", "com.apple.quarantine", target.path])

            self.installed = target
            DispatchQueue.main.async { self.show(.done) }
        }
    }
}

// MARK: - main

if CommandLine.arguments.contains("--detect") {
    if let url = detectIwad() {
        print("found: \(url.path)")
    } else {
        print("not found")
    }
    exit(0)
}

let app = NSApplication.shared
let wizard = Wizard()
app.delegate = wizard
app.setActivationPolicy(.regular)
app.run()
