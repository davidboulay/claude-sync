// claude-sync menu-bar app (macOS peer) — native replacement for the SwiftBar
// plugin. Shows the Claude Code mark with a status badge; the dropdown lists
// sync health and actions. Compiled by build.sh into "Claude Sync.app".
//
// Status semantics (deliberate):
//   green = everything delivered, hub reachable or not needed
//   blue  = hub offline but NOTHING queued — calm, just informational
//   amber = data queued (for an offline hub, or transferring), or stale heartbeat
//   red   = local Syncthing down
import AppKit
import Foundation

// MARK: - config / helpers

struct Config {
    var values: [String: String] = [:]
    init() {
        let path = NSString(string: "~/.config/claude-sync/config").expandingTildeInPath
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return }
        for line in text.split(separator: "\n") {
            let l = line.trimmingCharacters(in: .whitespaces)
            if l.isEmpty || l.hasPrefix("#") { continue }
            guard let eq = l.firstIndex(of: "=") else { continue }
            let k = String(l[..<eq]).trimmingCharacters(in: .whitespaces)
            var v = String(l[l.index(after: eq)...]).trimmingCharacters(in: .whitespaces)
            v = v.trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            values[k] = v
        }
    }
    subscript(_ k: String, default def: String = "") -> String { values[k] ?? def }
}

func syncthingAPIKey() -> String? {
    let path = NSString(string: "~/Library/Application Support/Syncthing/config.xml").expandingTildeInPath
    guard let xml = try? String(contentsOfFile: path, encoding: .utf8),
          let r = xml.range(of: "<apikey>([^<]+)</apikey>", options: .regularExpression) else { return nil }
    return String(xml[r]).replacingOccurrences(of: "<apikey>", with: "")
                          .replacingOccurrences(of: "</apikey>", with: "")
}

func httpGET(_ urlString: String, apiKey: String, timeout: TimeInterval = 4) -> Data? {
    guard let url = URL(string: urlString) else { return nil }
    var req = URLRequest(url: url, timeoutInterval: timeout)
    req.setValue(apiKey, forHTTPHeaderField: "X-API-Key")
    var out: Data?
    let sem = DispatchSemaphore(value: 0)
    URLSession.shared.dataTask(with: req) { data, resp, _ in
        if let http = resp as? HTTPURLResponse, http.statusCode == 200 { out = data }
        sem.signal()
    }.resume()
    _ = sem.wait(timeout: .now() + timeout + 1)
    return out
}

func json(_ data: Data?) -> [String: Any]? {
    guard let d = data else { return nil }
    return (try? JSONSerialization.jsonObject(with: d)) as? [String: Any]
}

// MARK: - status model

enum Health: String { case green, blue, amber, red, gray }

struct StatusLine {
    let symbol: String   // ✓ ● ◐ ✗ ?
    let text: String
    var color: NSColor {
        switch symbol {
        case "✓": return NSColor.systemGreen
        case "◐": return NSColor.systemOrange
        case "●": return NSColor.systemOrange
        case "○": return NSColor.systemBlue
        case "✗": return NSColor.systemRed
        default:  return NSColor.systemGray
        }
    }
}

struct RenameSuggestion { let old: String; let guess: String? }

struct SyncStatus {
    var health: Health = .gray
    var lines: [StatusLine] = []
    var renames: [RenameSuggestion] = []
    var update: String = "ok"   // ok | pull:<n> | reinstall | unknown
}

func installedVersion() -> String {
    let base = "\(NSHomeDirectory())/.local/share/claude-sync"
    let rel = (try? String(contentsOfFile: "\(base)/installed-release", encoding: .utf8))?
        .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    let hash = (try? String(contentsOfFile: "\(base)/installed-version", encoding: .utf8))?
        .trimmingCharacters(in: .whitespacesAndNewlines).prefix(7) ?? ""
    if !rel.isEmpty { return hash.isEmpty ? "v\(rel)" : "v\(rel) (\(hash))" }
    return hash.isEmpty ? "dev" : String(hash)
}

func runCapture(_ path: String, _ args: [String] = []) -> String {
    guard FileManager.default.isExecutableFile(atPath: path) else { return "" }
    let p = Process()
    p.executableURL = URL(fileURLWithPath: path)
    p.arguments = args
    let pipe = Pipe()
    p.standardOutput = pipe
    p.standardError = FileHandle.nullDevice
    guard (try? p.run()) != nil else { return "" }
    p.waitUntilExit()
    return String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
        .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
}

func detectRenames(root: String) -> [RenameSuggestion] {
    // same detection as the other indicators: session stores whose project
    // folder no longer exists, fuzzy-matched against current folders
    let py = """
    import difflib, os, re
    from pathlib import Path
    root = Path(os.environ.get("CS_ROOT", str(Path.home()/ "Claude")))
    store = Path.home() / ".claude/projects"
    prefix = str(root) + "/"
    seen, orphans = set(), []
    if store.is_dir():
        for d in sorted(store.iterdir()):
            if not d.is_dir(): continue
            f = next(iter(sorted(d.glob("*.jsonl"))), None)
            if f is None: continue
            try: head = f.open("rb").read(65536).decode("utf-8", "replace")
            except OSError: continue
            m = re.search(r'"cwd":"([^"]+)"', head)
            if not m or not m.group(1).startswith(prefix): continue
            top = m.group(1)[len(prefix):].split("/")[0]
            if top in seen: continue
            seen.add(top)
            if not (root / top).exists(): orphans.append(top)
    folders = [p.name for p in root.iterdir() if p.is_dir() and not p.name.startswith(".")] if root.is_dir() else []
    for old in orphans:
        best = difflib.get_close_matches(old, folders, n=1, cutoff=0.6)
        print(f"{old}|{best[0] if best else ''}")
    """
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
    p.arguments = ["-c", py]
    var env = ProcessInfo.processInfo.environment
    env["CS_ROOT"] = root
    p.environment = env
    let pipe = Pipe()
    p.standardOutput = pipe
    p.standardError = FileHandle.nullDevice
    guard (try? p.run()) != nil else { return [] }
    p.waitUntilExit()
    let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    return out.split(separator: "\n").compactMap { line in
        let parts = line.split(separator: "|", maxSplits: 1, omittingEmptySubsequences: false)
        guard let old = parts.first, !old.isEmpty else { return nil }
        let guess = parts.count > 1 && !parts[1].isEmpty ? String(parts[1]) : nil
        return RenameSuggestion(old: String(old), guess: guess)
    }
}

func fetchStatus() -> SyncStatus {
    var st = SyncStatus()
    let cfg = Config()
    let root = cfg["LOCAL_ROOT", default: NSString(string: "~/Claude").expandingTildeInPath]
    let folder = cfg["ST_FOLDER_ID", default: "claude-projects"]
    let hubID = cfg["HUB_DEVICE_ID"]
    let hubName = cfg["HUB_NAME", default: "hub"]
    let base = "http://127.0.0.1:8384/rest"

    guard let key = syncthingAPIKey(),
          let ping = httpGET("\(base)/system/ping", apiKey: key), !ping.isEmpty else {
        st.health = .red
        st.lines.append(StatusLine(symbol: "✗", text: "Syncthing not running — open the Syncthing app"))
        return st
    }

    var health = Health.green
    var queuedForOfflineHub = false

    let conns = json(httpGET("\(base)/system/connections", apiKey: key))?["connections"] as? [String: Any]
    let hubConn = ((conns?[hubID] as? [String: Any])?["connected"] as? Bool) ?? false

    func completion(_ device: String?) -> (pct: Double, need: Int)? {
        var url = "\(base)/db/completion?folder=\(folder)"
        if let d = device { url += "&device=\(d)" }
        guard let j = json(httpGET(url, apiKey: key)),
              let pct = j["completion"] as? Double,
              let need = j["needBytes"] as? Int else { return nil }
        return (pct, need)
    }
    let here = completion(nil)
    let hub = hubID.isEmpty ? nil : completion(hubID)

    if hubConn {
        st.lines.append(StatusLine(symbol: "✓", text: "\(hubName) connected"))
        if let h = here, h.need > 0 {
            st.lines.append(StatusLine(symbol: "◐", text: String(format: "this Mac: %.0f%% (%d MB left)", h.pct, h.need / 1_000_000)))
            health = .amber
        }
        if let h = hub, h.need > 0 {
            st.lines.append(StatusLine(symbol: "◐", text: String(format: "\(hubName): %.0f%% (%d MB left)", h.pct, h.need / 1_000_000)))
            health = .amber
        }
        if (here?.need ?? 0) == 0 && (hub?.need ?? 0) == 0 {
            st.lines.append(StatusLine(symbol: "✓", text: "projects fully mirrored"))
        }
    } else {
        // the point-1 distinction: offline-with-queue vs offline-clean
        let queued = hub?.need ?? 0
        if queued > 0 {
            st.lines.append(StatusLine(symbol: "●", text: "\(hubName) offline — \(queued / 1_000_000) MB queued, delivers when it's back"))
            health = .amber
            queuedForOfflineHub = true
        } else {
            st.lines.append(StatusLine(symbol: "○", text: "\(hubName) offline — nothing pending, fully delivered"))
            if health == .green { health = .blue }
        }
        if let h = here, h.need > 0 {
            st.lines.append(StatusLine(symbol: "●", text: "this Mac awaits \(h.need / 1_000_000) MB (arrives when peers return)"))
        }
    }

    // session-sync heartbeat stamped by the hub
    let hbPath = NSString(string: "~/.claude/.claude-sync-heartbeat").expandingTildeInPath
    let hbLegacy = NSString(string: "~/.claude/.last-sync-from-linux").expandingTildeInPath
    let hb = FileManager.default.fileExists(atPath: hbPath) ? hbPath : hbLegacy
    if let txt = try? String(contentsOfFile: hb, encoding: .utf8), let ts = Double(txt.trimmingCharacters(in: .whitespacesAndNewlines)) {
        let mins = Int(Date().timeIntervalSince1970 - ts) / 60
        if mins < 15 {
            st.lines.append(StatusLine(symbol: "✓", text: "sessions: synced \(mins) min ago"))
        } else if hubConn {
            st.lines.append(StatusLine(symbol: "●", text: "sessions: last sync \(mins) min ago (timer stuck on \(hubName)?)"))
            health = .amber
        } else {
            st.lines.append(StatusLine(symbol: "○", text: "sessions: last sync \(mins) min ago (\(hubName) offline)"))
            if health == .green { health = .blue }
        }
    } else {
        st.lines.append(StatusLine(symbol: "?", text: "sessions: no sync heartbeat yet"))
    }

    st.renames = detectRenames(root: root)
    if !st.renames.isEmpty && health != .red { health = .amber }

    st.update = runCapture("\(NSHomeDirectory())/.local/bin/claude-sync-check-update")
    if st.update.hasPrefix("pull:") {
        let n = st.update.dropFirst(5)
        st.lines.append(StatusLine(symbol: "●", text: "update available (\(n) new commit\(n == "1" ? "" : "s"))"))
    } else if st.update == "reinstall" {
        st.lines.append(StatusLine(symbol: "○", text: "new version synced — reinstall pending"))
    }

    _ = queuedForOfflineHub
    st.health = health
    return st
}

// MARK: - icon

func badgeColor(_ h: Health) -> NSColor {
    switch h {
    case .green: return NSColor.systemGreen
    case .blue:  return NSColor.systemBlue
    case .amber: return NSColor.systemOrange
    case .red:   return NSColor.systemRed
    case .gray:  return NSColor.systemGray
    }
}

func menuBarIcon(_ health: Health) -> NSImage {
    let size = NSSize(width: 20, height: 20)
    let img = NSImage(size: size)
    img.lockFocus()
    let logoPath = NSString(string: "~/.local/share/claude-sync/claude-logo.png").expandingTildeInPath
    if let logo = NSImage(contentsOfFile: logoPath) {
        logo.draw(in: NSRect(x: 0, y: 1, width: 18, height: 18),
                  from: .zero, operation: .sourceOver, fraction: 1.0)
    } else {
        let ctx = NSBezierPath(ovalIn: NSRect(x: 2, y: 3, width: 14, height: 14))
        NSColor(calibratedRed: 0.85, green: 0.47, blue: 0.34, alpha: 1).setFill()
        ctx.fill()
    }
    let badge = NSBezierPath(ovalIn: NSRect(x: 11.5, y: 0, width: 8.5, height: 8.5))
    badgeColor(health).setFill()
    badge.fill()
    NSColor.black.withAlphaComponent(0.55).setStroke()
    badge.lineWidth = 0.8
    badge.stroke()
    img.unlockFocus()
    img.isTemplate = false
    return img
}

// MARK: - app

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    var statusItem: NSStatusItem!
    var status = SyncStatus()
    var timer: Timer?
    var lastUpdateState = "ok"

    func applicationDidFinishLaunching(_ note: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = menuBarIcon(.gray)
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            self?.refresh()
        }
    }

    func refresh() {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let st = fetchStatus()
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.status = st
                self.statusItem.button?.image = menuBarIcon(st.health)
                // notify once when an update first becomes available
                let actionable = st.update.hasPrefix("pull") || st.update == "reinstall"
                if actionable && self.lastUpdateState != st.update {
                    let p = Process()
                    p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
                    p.arguments = ["-e",
                        "display notification \"Update available — use “Update Claude Sync now” in the menu\" with title \"Claude Sync\""]
                    try? p.run()
                }
                self.lastUpdateState = st.update
            }
        }
    }

    func menuWillOpen(_ menu: NSMenu) {
        rebuild(menu)
        refresh()   // update for next time; current open shows cached
    }

    func rebuild(_ menu: NSMenu) {
        menu.removeAllItems()
        let title = NSMenuItem()
        title.attributedTitle = NSAttributedString(
            string: "Claude Sync \(installedVersion()) — \(Host.current().localizedName ?? "Mac")",
            attributes: [.foregroundColor: NSColor(calibratedRed: 0.85, green: 0.47, blue: 0.34, alpha: 1),
                         .font: NSFont.boldSystemFont(ofSize: 13)])
        title.isEnabled = false
        menu.addItem(title)
        menu.addItem(.separator())
        for line in status.lines {
            let item = NSMenuItem()
            let s = NSMutableAttributedString(
                string: "\(line.symbol) ", attributes: [.foregroundColor: line.color, .font: NSFont.systemFont(ofSize: 13)])
            s.append(NSAttributedString(string: line.text,
                     attributes: [.foregroundColor: NSColor.labelColor, .font: NSFont.systemFont(ofSize: 13)]))
            item.attributedTitle = s
            item.isEnabled = false
            menu.addItem(item)
        }
        if !status.renames.isEmpty {
            menu.addItem(.separator())
            for r in status.renames {
                if let g = r.guess {
                    let item = NSMenuItem(title: "Repair rename: \(r.old) → \(g)",
                                          action: #selector(repairRename(_:)), keyEquivalent: "")
                    item.target = self
                    item.representedObject = [r.old, g]
                    menu.addItem(item)
                } else {
                    let item = NSMenuItem(title: "'\(r.old)' sessions orphaned — no folder match", action: nil, keyEquivalent: "")
                    item.isEnabled = false
                    menu.addItem(item)
                }
            }
        }
        menu.addItem(.separator())
        if status.update != "ok" && status.update != "unknown" && !status.update.isEmpty {
            menu.addItem(makeAction("Update Claude Sync now", #selector(updateNow)))
        }
        menu.addItem(makeAction("Rename project…", #selector(renameProject)))
        menu.addItem(makeAction("Open Syncthing GUI", #selector(openGUI)))
        menu.addItem(makeAction("Refresh now", #selector(refreshNow)))
        menu.addItem(makeAction("Check for updates…", #selector(checkUpdates)))
        menu.addItem(.separator())
        menu.addItem(makeAction("Quit Claude Sync", #selector(quit)))
    }

    func makeAction(_ title: String, _ sel: Selector) -> NSMenuItem {
        let i = NSMenuItem(title: title, action: sel, keyEquivalent: "")
        i.target = self
        return i
    }

    func run(_ path: String, _ args: [String] = []) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        try? p.run()
    }

    @objc func repairRename(_ sender: NSMenuItem) {
        guard let pair = sender.representedObject as? [String], pair.count == 2 else { return }
        // full mode: folder already renamed → migrates the local store and
        // queues every other device via the synced staging control channel
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "\(NSHomeDirectory())/.local/bin/claude-mv-project")
        p.arguments = [pair[0], pair[1]]
        try? p.run()
        p.waitUntilExit()
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { self.refresh() }
    }

    @objc func updateNow() {
        // apply update, then restart this app (binary is replaced on disk)
        let script = "\(NSHomeDirectory())/.local/bin/claude-sync-check-update --apply " +
                     "&& (sleep 1; /usr/bin/open '/Applications/Claude Sync.app') &"
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/bash")
        p.arguments = ["-c", script]
        try? p.run()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { NSApp.terminate(nil) }
    }

    @objc func checkUpdates() {
        DispatchQueue.global(qos: .userInitiated).async {
            let res = runCapture("\(NSHomeDirectory())/.local/bin/claude-sync-check-update", ["--fresh"])
            DispatchQueue.main.async {
                let a = NSAlert()
                a.messageText = "Claude Sync"
                if res.hasPrefix("pull:") {
                    let n = res.dropFirst(5)
                    a.informativeText = "Update available: \(n) new commit\(n == "1" ? "" : "s").\nUse “Update Claude Sync now” in the menu to apply."
                } else if res == "reinstall" {
                    a.informativeText = "A newer version has already synced to this Mac.\nUse “Update Claude Sync now” in the menu to apply."
                } else if res == "ok" {
                    a.informativeText = "You're up to date."
                } else {
                    a.informativeText = "Couldn't check for updates (offline, or repo not found)."
                }
                NSApp.activate(ignoringOtherApps: true)
                a.runModal()
                self.refresh()
            }
        }
    }

    @objc func renameProject() { run("\(NSHomeDirectory())/.local/bin/claude-rename-project") }
    @objc func openGUI() { NSWorkspace.shared.open(URL(string: "http://127.0.0.1:8384")!) }
    @objc func refreshNow() { refresh() }
    @objc func quit() { NSApp.terminate(nil) }
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let delegate = AppDelegate()
app.delegate = delegate
app.run()
