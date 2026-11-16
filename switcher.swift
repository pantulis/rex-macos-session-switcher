// rex-session-switcher: a native AppKit popup for choosing a Rex session.
//
// Reads {"sessions":[{"session_id":"...","label":"..."}],"current":"..."} from
// stdin. On a choice it prints {"action":"...","session_id":"...","label":"..."}
// and exits 0. Return on a session goes to it; Tab opens that session's actions.
// Exits 1 if the user cancels (Esc or click away).
import AppKit

// What an agent or other program in the session last reported (OSC 7501).
struct Status: Decodable {
    let state: String  // idle, working, done, blocked, error
    let msg: String?
    let kind: String?  // for blocked: permission, question, auth
    let updated_at: String?
}

struct Session: Decodable {
    let session_id: String
    let label: String
    let status: Status?
}

struct Input: Decodable {
    let sessions: [Session]
    let current: String?
}

final class Panel: NSPanel {
    override var canBecomeKey: Bool { true }
}

// Selected rows are a rounded accent-colored pill, like Rex's own switcher.
final class RowView: NSTableRowView {
    // The filter field holds focus, so AppKit would never emphasize the selection.
    override var interiorBackgroundStyle: NSView.BackgroundStyle {
        isSelected ? .emphasized : .normal
    }

    override func drawSelection(in dirtyRect: NSRect) {
        guard isSelected else { return }
        NSColor.controlAccentColor.setFill()
        NSBezierPath(roundedRect: bounds.insetBy(dx: 0, dy: 1), xRadius: 14, yRadius: 14).fill()
    }
}

final class SeparatorView: NSView {
    override func draw(_ dirtyRect: NSRect) {
        NSColor.labelColor.withAlphaComponent(0.12).setFill()
        NSRect(x: 12, y: bounds.midY, width: bounds.width - 24, height: 1).fill()
    }
}

// One line in the list: a session, or an action on a session.
struct Row {
    let id: String
    let title: String
    var current = false
    var hasMenu = false
    var destructive = false
    var status: Status?
    var separator = false
    var symbol: String?  // leading icon, for rows that aren't sessions
}

final class Cell: NSTableCellView {
    let title = NSTextField(labelWithString: "")
    let check = NSImageView()
    let chevron = NSImageView()
    let leadingIcon = NSImageView()
    let statusIcon = NSImageView()
    let statusLabel = NSTextField(labelWithString: "")
    let statusColor: NSColor
    let destructive: Bool
    let hasMenu: Bool

    init(row: Row, title text: String) {
        destructive = row.destructive
        hasMenu = row.hasMenu
        let look = Cell.look(row.status)
        statusColor = look.color
        super.init(frame: .zero)
        title.stringValue = text
        title.font = .systemFont(ofSize: 17)
        title.lineBreakMode = .byTruncatingTail
        title.textColor = row.destructive ? .systemRed : .labelColor
        check.image = NSImage(systemSymbolName: "checkmark", accessibilityDescription: "Current")
        check.symbolConfiguration = .init(pointSize: 15, weight: .semibold)
        check.isHidden = !row.current
        // A triangle on the selected row hints that Tab opens its actions.
        chevron.image = NSImage(systemSymbolName: "chevron.right", accessibilityDescription: "Actions")
        chevron.symbolConfiguration = .init(pointSize: 13, weight: .bold)
        chevron.isHidden = true
        statusIcon.image = look.symbol.flatMap {
            NSImage(systemSymbolName: $0, accessibilityDescription: row.status?.state)
        }
        statusIcon.symbolConfiguration = .init(pointSize: 14, weight: .semibold)
        statusIcon.contentTintColor = look.color
        statusLabel.stringValue = look.text
        statusLabel.font = .systemFont(ofSize: 14)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.lineBreakMode = .byTruncatingTail
        // The status gives way before the session name does.
        statusLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        title.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)
        leadingIcon.image = row.symbol.flatMap { NSImage(systemSymbolName: $0, accessibilityDescription: nil) }
        leadingIcon.symbolConfiguration = .init(pointSize: 16, weight: .semibold)
        leadingIcon.contentTintColor = .labelColor
        leadingIcon.isHidden = row.symbol == nil
        for v in [title, leadingIcon, check, chevron, statusIcon, statusLabel] {
            v.translatesAutoresizingMaskIntoConstraints = false
            addSubview(v)
        }
        NSLayoutConstraint.activate([
            leadingIcon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            leadingIcon.centerYAnchor.constraint(equalTo: centerYAnchor),
            title.leadingAnchor.constraint(equalTo: leadingAnchor, constant: row.symbol == nil ? 12 : 40),
            title.centerYAnchor.constraint(equalTo: centerYAnchor),
            title.trailingAnchor.constraint(lessThanOrEqualTo: statusIcon.leadingAnchor, constant: -12),
            statusLabel.trailingAnchor.constraint(equalTo: check.leadingAnchor, constant: -12),
            statusLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            statusLabel.widthAnchor.constraint(lessThanOrEqualToConstant: 230),
            statusIcon.trailingAnchor.constraint(equalTo: statusLabel.leadingAnchor, constant: -6),
            statusIcon.centerYAnchor.constraint(equalTo: centerYAnchor),
            chevron.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
            chevron.centerYAnchor.constraint(equalTo: centerYAnchor),
            chevron.widthAnchor.constraint(equalToConstant: 10),
            check.trailingAnchor.constraint(equalTo: chevron.leadingAnchor, constant: -10),
            check.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    // The icon, its color, and the text shown for a session's status.
    static func look(_ st: Status?) -> (symbol: String?, color: NSColor, text: String) {
        guard let st else { return (nil, .clear, "") }
        let msg = st.msg ?? ""
        switch st.state {
        case "working":
            return ("hourglass", .systemBlue, msg.isEmpty ? "Working" : msg)
        case "blocked":
            let why = ["permission": "Needs permission", "question": "Has a question", "auth": "Needs sign-in"]
            return ("exclamationmark.circle.fill", .systemOrange,
                    msg.isEmpty ? (why[st.kind ?? ""] ?? "Waiting for you") : msg)
        case "error":
            return ("xmark.octagon.fill", .systemRed, msg.isEmpty ? "Failed" : msg)
        case "done":
            return ("checkmark.circle.fill", .systemGreen, "Done " + ago(st.updated_at))
        default:
            return (nil, .clear, "")
        }
    }

    static func ago(_ stamp: String?) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        guard let stamp, let date = f.date(from: stamp) ?? ISO8601DateFormatter().date(from: stamp),
            Date().timeIntervalSince(date) >= 60
        else { return "now" }
        let rel = RelativeDateTimeFormatter()
        rel.unitsStyle = .short
        return rel.localizedString(for: date, relativeTo: Date())
    }

    override var backgroundStyle: NSView.BackgroundStyle {
        didSet {
            let on = backgroundStyle == .emphasized
            title.textColor = on ? .white : (destructive ? .systemRed : .labelColor)
            check.contentTintColor = on ? .white : .labelColor
            leadingIcon.contentTintColor = on ? .white : .labelColor
            statusIcon.contentTintColor = on ? .white : statusColor
            statusLabel.textColor = on ? NSColor.white.withAlphaComponent(0.85) : .secondaryLabelColor
            chevron.contentTintColor = .white
            chevron.isHidden = !(on && hasMenu)
        }
    }
}

final class Picker: NSObject, NSApplicationDelegate, NSTableViewDataSource,
    NSTableViewDelegate, NSTextFieldDelegate, NSWindowDelegate
{
    static let width: CGFloat = 720
    static let rowHeight: CGFloat = 42

    enum Mode {
        case sessions
        case actions(Session)
        case rename(Session)
        case confirmClose(Session)
    }

    static let actions: [Row] = [
        Row(id: "select", title: "Go to Session"),
        Row(id: "rename", title: "Rename…"),
        Row(id: "new_tab", title: "New Tab"),
        Row(id: "copy", title: "Copy Session ID"),
        Row(id: "close", title: "Close Session", destructive: true),
    ]

    let sessions: [Session]
    let current: String?
    var mode = Mode.sessions
    var rows: [Row]  // everything the current mode offers
    var shown: [Row]  // rows that pass the filter
    let panel: Panel
    let search = NSTextField()
    let glass = NSImageView()
    let table = NSTableView()
    var wasKey = false

    init(_ input: Input) {
        sessions = input.sessions
        current = input.current
        rows = Picker.sessionRows(input.sessions, current: input.current)
        shown = rows
        panel = Panel(
            contentRect: NSRect(
                x: 0, y: 0, width: Picker.width, height: Picker.height(forRows: rows)),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: false)
        super.init()
    }

    // Every session, then a separator and the entry that creates a new one.
    static func sessionRows(_ sessions: [Session], current: String?) -> [Row] {
        sessions.map {
            Row(id: $0.session_id, title: $0.label.isEmpty ? $0.session_id : $0.label,
                current: $0.session_id == current, hasMenu: true, status: $0.status)
        } + [
            Row(id: "separator", title: "", separator: true),
            Row(id: "new", title: "New Session", symbol: "plus"),
        ]
    }

    static let separatorHeight: CGFloat = 17

    static func rowHeight(_ row: Row) -> CGFloat { row.separator ? separatorHeight : rowHeight }

    // Panel height for these rows, showing at most eight rows' worth.
    static func height(forRows rows: [Row]) -> CGFloat {
        if rows.isEmpty { return 14 + 46 + 14 }
        var list: CGFloat = 0
        for row in rows { list = min(list + rowHeight(row), 8 * rowHeight) }
        return 14 + 46 + 10 + list + 12
    }

    func applicationDidFinishLaunching(_ note: Notification) {
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.delegate = self
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true

        let background = NSVisualEffectView()
        background.material = .popover
        background.state = .active
        // A blur material ignores layer masks, so round it with a mask image.
        let radius: CGFloat = 22
        let mask = NSImage(size: NSSize(width: radius * 2 + 1, height: radius * 2 + 1), flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
            return true
        }
        mask.capInsets = NSEdgeInsets(top: radius, left: radius, bottom: radius, right: radius)
        mask.resizingMode = .stretch
        background.maskImage = mask
        panel.contentView = background

        // Filter field: a rounded gray well with a magnifying glass.
        let well = NSView()
        well.wantsLayer = true
        well.layer?.cornerRadius = 14
        well.layer?.cornerCurve = .continuous
        well.layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(0.05).cgColor
        glass.image = NSImage(systemSymbolName: "magnifyingglass", accessibilityDescription: nil)
        glass.symbolConfiguration = .init(pointSize: 18, weight: .regular)
        glass.contentTintColor = .labelColor
        search.placeholderString = "Filter sessions or create…"
        search.delegate = self
        search.font = .systemFont(ofSize: 20)
        search.isBordered = false
        search.drawsBackground = false
        search.focusRingType = .none

        let column = NSTableColumn(identifier: .init("label"))
        column.resizingMask = .autoresizingMask
        table.addTableColumn(column)
        table.headerView = nil
        table.rowHeight = Picker.rowHeight
        table.intercellSpacing = .zero
        table.backgroundColor = .clear
        table.selectionHighlightStyle = .regular
        table.style = .plain
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.action = #selector(accept)

        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = false
        scroll.scrollerStyle = .overlay
        scroll.automaticallyAdjustsContentInsets = false
        scroll.contentInsets = NSEdgeInsetsZero

        for view in [well, glass, search, scroll] {
            view.translatesAutoresizingMaskIntoConstraints = false
        }
        background.addSubview(well)
        background.addSubview(scroll)
        well.addSubview(glass)
        well.addSubview(search)
        NSLayoutConstraint.activate([
            well.topAnchor.constraint(equalTo: background.topAnchor, constant: 14),
            well.leadingAnchor.constraint(equalTo: background.leadingAnchor, constant: 12),
            well.trailingAnchor.constraint(equalTo: background.trailingAnchor, constant: -12),
            well.heightAnchor.constraint(equalToConstant: 46),
            glass.leadingAnchor.constraint(equalTo: well.leadingAnchor, constant: 14),
            glass.centerYAnchor.constraint(equalTo: well.centerYAnchor),
            search.leadingAnchor.constraint(equalTo: glass.trailingAnchor, constant: 10),
            search.trailingAnchor.constraint(equalTo: well.trailingAnchor, constant: -12),
            search.centerYAnchor.constraint(equalTo: well.centerYAnchor),
            scroll.topAnchor.constraint(equalTo: well.bottomAnchor, constant: 10),
            scroll.leadingAnchor.constraint(equalTo: background.leadingAnchor, constant: 12),
            scroll.trailingAnchor.constraint(equalTo: background.trailingAnchor, constant: -12),
            scroll.bottomAnchor.constraint(equalTo: background.bottomAnchor, constant: -12),
        ])

        table.reloadData()
        // Start on the most recent session other than the current one.
        select(defaultRow())
        let border = NSView()
        border.wantsLayer = true
        border.layer?.cornerRadius = radius
        border.layer?.cornerCurve = .continuous
        border.layer?.borderWidth = 0.5
        border.layer?.borderColor = NSColor.separatorColor.cgColor
        border.translatesAutoresizingMaskIntoConstraints = false
        background.addSubview(border)
        NSLayoutConstraint.activate([
            border.topAnchor.constraint(equalTo: background.topAnchor),
            border.bottomAnchor.constraint(equalTo: background.bottomAnchor),
            border.leadingAnchor.constraint(equalTo: background.leadingAnchor),
            border.trailingAnchor.constraint(equalTo: background.trailingAnchor),
        ])
        position()
        // For documentation screenshots: REX_SWITCHER_APPEARANCE=light|dark, and
        // REX_SWITCHER_START=actions to open the selected session's actions.
        let env = ProcessInfo.processInfo.environment
        if let name = env["REX_SWITCHER_APPEARANCE"] {
            panel.appearance = NSAppearance(named: name == "dark" ? .darkAqua : .aqua)
        }
        if env["REX_SWITCHER_START"] == "actions", table.selectedRow >= 0,
            let s = session(for: shown[table.selectedRow])
        {
            enterActions(s)
        }
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(search)
        panel.invalidateShadow()
    }

    // Rex's frontmost window in Cocoa coordinates, if it can be found.
    func rexWindowFrame() -> NSRect? {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID)
            as? [[String: Any]], let primary = NSScreen.screens.first
        else { return nil }
        for w in list {  // front to back
            guard (w[kCGWindowOwnerName as String] as? String)?.hasPrefix("Rex") == true,
                (w[kCGWindowLayer as String] as? Int) == 0,
                let b = w[kCGWindowBounds as String] as? [String: CGFloat],
                let x = b["X"], let y = b["Y"], let width = b["Width"], let height = b["Height"]
            else { continue }
            return NSRect(x: x, y: primary.frame.height - y - height, width: width, height: height)
        }
        return nil
    }

    // Horizontally centered in Rex's window, near its top. Falls back to screen center,
    // which REX_SWITCHER_POSITION=screen asks for outright.
    func position() {
        guard ProcessInfo.processInfo.environment["REX_SWITCHER_POSITION"] != "screen",
            let f = rexWindowFrame()
        else {
            // NSWindow.center() sits above the middle, so center exactly.
            let screen = (NSScreen.main ?? NSScreen.screens[0]).visibleFrame
            let size = panel.frame.size
            return panel.setFrameOrigin(NSPoint(x: screen.midX - size.width / 2, y: screen.midY - size.height / 2))
        }
        let size = panel.frame.size
        panel.setFrameOrigin(NSPoint(
            x: f.midX - size.width / 2,
            y: f.maxY - size.height - f.height * 0.12))
    }

    // Selects a row, skipping separators in the direction of travel.
    func select(_ row: Int, step: Int = 1) {
        guard !shown.isEmpty else { return }
        var r = max(0, min(shown.count - 1, row))
        while shown[r].separator {
            let next = r + step
            if next < 0 || next >= shown.count { r -= step; break }
            r = next
        }
        table.selectRowIndexes([r], byExtendingSelection: false)
        // Rows beyond the visible eight need scrolling; otherwise the list must not move.
        if table.frame.height > table.enclosingScrollView?.frame.height ?? .infinity { table.scrollRowToVisible(r) }
    }

    func defaultRow() -> Int {
        shown.firstIndex(where: { !$0.current && !$0.separator && $0.id != "new" }) ?? 0
    }

    func session(for row: Row) -> Session? { sessions.first { $0.session_id == row.id } }

    // MARK: results

    func emit(_ action: String, _ s: Session? = nil, label: String? = nil) -> Never {
        var out = ["action": action]
        if let s { out["session_id"] = s.session_id }
        if let label { out["label"] = label }
        let json = try! JSONSerialization.data(withJSONObject: out)
        print(String(decoding: json, as: UTF8.self))
        exit(0)
    }

    @objc func accept() {
        // Rename has no list, so it must be handled before the row checks.
        if case .rename(let s) = mode {
            let name = search.stringValue.trimmingCharacters(in: .whitespaces)
            if !name.isEmpty { emit("rename", s, label: name) }
            return
        }
        let row = table.selectedRow
        guard row >= 0, row < shown.count else { return }
        switch mode {
        case .sessions:
            if shown[row].id == "new" {
                // Anything typed becomes the new session's name.
                let name = search.stringValue.trimmingCharacters(in: .whitespaces)
                emit("new_session", label: name.isEmpty ? nil : name)
            }
            if let s = session(for: shown[row]) { emit("select", s) }
        case .actions(let s):
            perform(shown[row].id, on: s)
        case .confirmClose(let s):
            if shown[row].id == "close" { emit("close", s) }
            enterActions(s)
        case .rename: break
        }
    }

    func perform(_ action: String, on s: Session) {
        switch action {
        case "rename": enterRename(s)
        case "close": enterConfirmClose(s)
        default: emit(action, s)
        }
    }

    func finish() -> Never { exit(1) }

    // MARK: modes

    func show(_ newRows: [Row], placeholder: String) {
        rows = newRows
        setIcon("magnifyingglass")
        search.stringValue = ""
        search.placeholderString = placeholder
        applyFilter()
        resize()
    }

    func enterSessions() {
        mode = .sessions
        show(Picker.sessionRows(sessions, current: current), placeholder: "Filter sessions or create…")
        select(defaultRow())
    }

    func enterActions(_ s: Session) {
        mode = .actions(s)
        show(Picker.actions, placeholder: "Actions for \(s.label.isEmpty ? s.session_id : s.label)")
        select(0)
    }

    // Closing a session can't be undone, so ask first. Cancel is preselected.
    func enterConfirmClose(_ s: Session) {
        mode = .confirmClose(s)
        show([
            Row(id: "cancel", title: "Cancel"),
            Row(id: "close", title: "Close Session", destructive: true),
        ], placeholder: "Close “\(s.label.isEmpty ? s.session_id : s.label)”? This can’t be undone.")
        select(0)
    }

    func enterRename(_ s: Session) {
        mode = .rename(s)
        show([], placeholder: "New name")
        setIcon("pencil")
        search.stringValue = s.label
        (search.currentEditor() as? NSTextView)?.selectAll(nil)
    }

    // The field's icon says what typing does: filter, or rename.
    func setIcon(_ symbol: String) {
        glass.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
    }

    // Resizes the panel for the current rows, keeping its top edge in place.
    func resize() {
        let h = Picker.height(forRows: rows)
        var f = panel.frame
        f.origin.y += f.height - h
        f.size.height = h
        panel.setFrame(f, display: true)
        panel.invalidateShadow()
    }

    // MARK: table

    func numberOfRows(in tableView: NSTableView) -> Int { shown.count }

    func tableView(_ tv: NSTableView, heightOfRow row: Int) -> CGFloat { Picker.rowHeight(shown[row]) }

    func tableView(_ tv: NSTableView, shouldSelectRow row: Int) -> Bool { !shown[row].separator }

    func tableView(_ tv: NSTableView, rowViewForRow row: Int) -> NSTableRowView? { RowView() }

    func tableView(_ tv: NSTableView, viewFor col: NSTableColumn?, row: Int) -> NSView? {
        let r = shown[row]
        if r.separator { return SeparatorView() }
        let typed = search.stringValue.trimmingCharacters(in: .whitespaces)
        if r.id == "new", case .sessions = mode, !typed.isEmpty {
            return Cell(row: r, title: "New Session “\(typed)”")
        }
        return Cell(row: r, title: r.title)
    }

    // MARK: search

    func applyFilter() {
        let q = search.stringValue.lowercased()
        // The separator and New Session stay put; the rest is filtered.
        let matches = rows.filter { $0.separator || $0.id == "new" || q.isEmpty || $0.title.lowercased().contains(q) }
        let hasSessions = matches.contains { !$0.separator && $0.id != "new" }
        shown = matches.filter { !$0.separator || hasSessions }
        table.reloadData()
        select(0)
    }

    func controlTextDidChange(_ obj: Notification) {
        if case .rename = mode { return }
        applyFilter()
    }

    func control(_ c: NSControl, textView: NSTextView, doCommandBy sel: Selector) -> Bool {
        switch (sel, mode) {
        case (#selector(NSResponder.moveDown(_:)), _): select(table.selectedRow + 1, step: 1)
        case (#selector(NSResponder.moveUp(_:)), _): select(table.selectedRow - 1, step: -1)
        case (#selector(NSResponder.insertNewline(_:)), _): accept()
        case (#selector(NSResponder.insertTab(_:)), .sessions), (#selector(NSResponder.moveRight(_:)), .sessions):
            // Only take Right when it can't move the text cursor.
            if sel == #selector(NSResponder.moveRight(_:)) && !search.stringValue.isEmpty { return false }
            guard table.selectedRow >= 0, let s = session(for: shown[table.selectedRow]) else { return true }
            enterActions(s)
        case (#selector(NSResponder.insertTab(_:)), .actions), (#selector(NSResponder.insertBacktab(_:)), .actions),
            (#selector(NSResponder.cancelOperation(_:)), .actions), (#selector(NSResponder.moveLeft(_:)), .actions):
            // Only take Left when it can't move the text cursor.
            if sel == #selector(NSResponder.moveLeft(_:)) && !search.stringValue.isEmpty { return false }
            enterSessions()
        case (#selector(NSResponder.insertTab(_:)), .rename), (#selector(NSResponder.insertBacktab(_:)), .rename):
            break
        case (#selector(NSResponder.cancelOperation(_:)), .rename(let s)): enterActions(s)
        case (#selector(NSResponder.insertTab(_:)), .confirmClose(let s)),
            (#selector(NSResponder.insertBacktab(_:)), .confirmClose(let s)),
            (#selector(NSResponder.cancelOperation(_:)), .confirmClose(let s)),
            (#selector(NSResponder.moveLeft(_:)), .confirmClose(let s)):
            if sel == #selector(NSResponder.moveLeft(_:)) && !search.stringValue.isEmpty { return false }
            enterActions(s)
        case (#selector(NSResponder.cancelOperation(_:)), .sessions): finish()
        default: return false
        }
        return true
    }

    // Clicking away cancels.
    func windowDidBecomeKey(_ n: Notification) { wasKey = true }
    func windowDidResignKey(_ n: Notification) { if wasKey { finish() } }
}

let data = FileHandle.standardInput.readDataToEndOfFile()
guard let input = try? JSONDecoder().decode(Input.self, from: data) else {
    FileHandle.standardError.write(Data("rex-session-switcher: expected JSON on stdin\n".utf8))
    exit(2)
}
let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let picker = Picker(input)
app.delegate = picker
app.run()
