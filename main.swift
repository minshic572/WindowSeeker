// 窗口总览 (WindowSeeker)
// 列出所有运行应用的窗口（含被最小化的、在别的桌面空间的），点一行就把那个窗口调出来。
// 每行右端还有三个按钮：关闭 / 最小化 / 切到前台。
//
// 技术：CoreGraphics 拿窗口的真实状态（是否在屏上），Accessibility API 负责恢复、置前、关闭、最小化。
// 编译：见同目录 build.sh

import Cocoa
import ApplicationServices

// MARK: - 私有符号：把 AX 窗口元素与 CGWindowID 对应起来（找不到就自动降级）

typealias AXGetWindowFn = @convention(c) (AXUIElement, UnsafeMutablePointer<CGWindowID>) -> AXError

let axGetWindowFn: AXGetWindowFn? = {
    guard let h = dlopen("/System/Library/Frameworks/ApplicationServices.framework/ApplicationServices", RTLD_NOW),
          let s = dlsym(h, "_AXUIElementGetWindow") else { return nil }
    return unsafeBitCast(s, to: AXGetWindowFn.self)
}()

func windowNumber(of el: AXUIElement) -> Int? {
    guard let f = axGetWindowFn else { return nil }
    var n: CGWindowID = 0
    guard f(el, &n) == .success, n != 0 else { return nil }
    return Int(n)
}

// MARK: - 模型

struct WinInfo {
    let pid: pid_t
    let appName: String
    let title: String
    let minimized: Bool
    let onscreen: Bool
    let width: Int
    let height: Int
    let ax: AXUIElement
}

enum Row {
    case group(name: String, icon: NSImage?, count: Int)
    case win(WinInfo)
}

// MARK: - AX 取值小工具

func axCopy(_ el: AXUIElement, _ attr: CFString) -> CFTypeRef? {
    var ref: CFTypeRef?
    guard AXUIElementCopyAttributeValue(el, attr, &ref) == .success else { return nil }
    return ref
}

func axTitle(_ w: AXUIElement) -> String {
    (axCopy(w, kAXTitleAttribute as CFString) as? String) ?? ""
}

func axMinimized(_ w: AXUIElement) -> Bool {
    (axCopy(w, kAXMinimizedAttribute as CFString) as? Bool) ?? false
}

func axSize(_ w: AXUIElement) -> CGSize? {
    guard let v = axCopy(w, kAXSizeAttribute as CFString),
          CFGetTypeID(v) == AXValueGetTypeID() else { return nil }
    var s = CGSize.zero
    guard AXValueGetValue(unsafeBitCast(v, to: AXValue.self), .cgSize, &s) else { return nil }
    return s
}

// MARK: - 采集窗口

func collectWindows() -> [WinInfo] {
    let myPID = ProcessInfo.processInfo.processIdentifier

    let cgAll = CGWindowListCopyWindowInfo([.optionAll, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
    let cgOn = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []

    var onscreenNums = Set<Int>()
    for w in cgOn {
        if let n = w[kCGWindowNumber as String] as? Int { onscreenNums.insert(n) }
    }

    // 只认 layer == 0 的普通窗口，顺便记下尺寸
    var cgSize: [Int: CGSize] = [:]
    for w in cgAll {
        guard let n = w[kCGWindowNumber as String] as? Int else { continue }
        guard (w[kCGWindowLayer as String] as? Int ?? 0) == 0 else { continue }
        let b = w[kCGWindowBounds as String] as? [String: Any] ?? [:]
        cgSize[n] = CGSize(width: b["Width"] as? CGFloat ?? 0, height: b["Height"] as? CGFloat ?? 0)
    }

    let apps = NSWorkspace.shared.runningApplications
        .filter { $0.activationPolicy == .regular && !$0.isTerminated && $0.processIdentifier != myPID }
        .sorted { ($0.localizedName ?? "") < ($1.localizedName ?? "") }

    var out: [WinInfo] = []
    for app in apps {
        let pid = app.processIdentifier
        let axApp = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(axApp, 0.5)   // 避免某个卡死的应用拖垮整次刷新

        guard let ref = axCopy(axApp, kAXWindowsAttribute as CFString),
              let wins = ref as? [AXUIElement] else { continue }

        let appName = app.localizedName ?? "未知应用"
        for w in wins {
            let num = windowNumber(of: w) ?? -1
            var size = num >= 0 ? (cgSize[num] ?? .zero) : .zero
            if size.width <= 1, let s = axSize(w) { size = s }
            if size.width < 80 || size.height < 60 { continue }   // 滤掉工具条之类的碎片窗

            out.append(WinInfo(
                pid: pid,
                appName: appName,
                title: axTitle(w),
                minimized: axMinimized(w),
                onscreen: num >= 0 ? onscreenNums.contains(num) : true,
                width: Int(size.width),
                height: Int(size.height),
                ax: w
            ))
        }
    }
    return out
}

// MARK: - 行内操作按钮（图标按钮 + 悬停高亮）

/// 每一行右端的「关闭 / 最小化 / 切到前台」按钮。
/// 用闭包而不是 target/action：按钮属于哪一行，在创建时就由闭包捕获，
/// 这样即使之后表格刷新、行号变了也不会点错目标。
final class CellActionButton: NSButton {

    private var handler: (() -> Void)?
    private var hovering = false

    // 必须显式重写：子类一旦自己实现了任何 designated initializer（含 required 的 coder 版），
    // Swift 就不再自动继承父类的 `init(frame:)`，于是 `self.init(frame: .zero)` 会报
    // "incorrect argument label in call (have 'frame:', expected 'coder:')"。
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    convenience init(symbol: String, tooltip: String, tint: NSColor, handler: @escaping () -> Void) {
        self.init(frame: .zero)
        self.handler = handler
        title = ""
        // 统一点大小：`xmark`/`minus`/`arrow.*` 三个符号的原生尺寸差很多
        // （minus 只有 14×4），不统一的话行里会显得一个大一个小。
        let cfg = NSImage.SymbolConfiguration(pointSize: 13, weight: .medium)
        image = NSImage(systemSymbolName: symbol, accessibilityDescription: tooltip)?
            .withSymbolConfiguration(cfg)
        imagePosition = .imageOnly
        imageScaling = .scaleProportionallyDown
        isBordered = false
        contentTintColor = tint
        toolTip = tooltip
        setButtonType(.momentaryChange)
        target = self
        action = #selector(fire)
        translatesAutoresizingMaskIntoConstraints = false
    }

    @objc private func fire() { handler?() }

    // 悬停时给一块淡色圆角底，让"这里可以点"变得可见
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for t in trackingAreas { removeTrackingArea(t) }
        addTrackingArea(NSTrackingArea(rect: bounds,
                                       options: [.mouseEnteredAndExited, .activeInKeyWindow],
                                       owner: self, userInfo: nil))
    }

    override func mouseEntered(with event: NSEvent) { hovering = true; needsDisplay = true }
    override func mouseExited(with event: NSEvent) { hovering = false; needsDisplay = true }

    override func draw(_ dirtyRect: NSRect) {
        if hovering {
            let bg = isHighlighted ? NSColor.controlAccentColor.withAlphaComponent(0.35)
                                   : NSColor.labelColor.withAlphaComponent(0.10)
            bg.setFill()
            NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 5, yRadius: 5).fill()
        }
        super.draw(dirtyRect)
    }
}

// MARK: - 主界面

final class AppDelegate: NSObject, NSApplicationDelegate, NSTableViewDataSource, NSTableViewDelegate {

    var win: NSWindow!
    var tableView: NSTableView!
    var searchField: NSSearchField!
    var statusLabel: NSTextField!

    var allInfos: [WinInfo] = []
    var rows: [Row] = []
    var permTimer: Timer?

    func applicationDidFinishLaunching(_ note: Notification) {
        buildMenu()
        buildUI()

        refresh()
        if !AXIsProcessTrusted() {
            let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
            _ = AXIsProcessTrustedWithOptions(opts)
            startPermissionWatch()
        }
        if #available(macOS 14.0, *) { NSApp.activate() } else { NSApp.activate(ignoringOtherApps: true) }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    /// 关掉主窗口后，点 Dock 图标 / 重新打开应用时，把窗口叫回来。
    /// 不实现这个的话，窗口一关就再也唤不出（AppKit 默认什么都不做）。
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { showMainWindow() }
        return true
    }

    func showMainWindow() {
        guard let w = win else { return }
        w.makeKeyAndOrderFront(nil)
        if #available(macOS 14.0, *) { NSApp.activate() } else { NSApp.activate(ignoringOtherApps: true) }
        refresh()
    }

    func buildMenu() {
        let main = NSMenu()
        let appItem = NSMenuItem()
        main.addItem(appItem)
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "显示窗口", action: #selector(showWindowAction), keyEquivalent: "0")
        appMenu.addItem(withTitle: "刷新", action: #selector(refreshAction), keyEquivalent: "r")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "退出窗口总览", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        NSApplication.shared.mainMenu = main
    }

    func buildUI() {
        win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 680),
                       styleMask: [.titled, .closable, .miniaturizable, .resizable],
                       backing: .buffered, defer: false)
        win.title = "窗口总览"
        win.center()
        // ⚠️ 名字换成了 V2：每行多了三个操作按钮，默认宽度从 580 提到 700。
        //    沿用旧名字会恢复此前保存的窄窗口，三个按钮会把标题挤没。
        win.setFrameAutosaveName("WindowSeekerMainV2")
        // 关键：关掉"关闭即释放"。默认值为 true，窗口一关就被 release，
        // 我们手里的 win 引用变成野指针，之后点 Dock 图标想再显示就会崩/没反应。
        win.isReleasedWhenClosed = false

        let content = NSView()
        win.contentView = content

        searchField = NSSearchField()
        searchField.placeholderString = "搜索窗口或应用名…"
        searchField.target = self
        searchField.action = #selector(searchChanged)
        searchField.translatesAutoresizingMaskIntoConstraints = false

        let permBtn = NSButton(title: "权限", target: self, action: #selector(openPermSettings))
        permBtn.bezelStyle = .rounded
        permBtn.toolTip = "打开 系统设置 → 隐私与安全性 → 辅助功能"
        permBtn.translatesAutoresizingMaskIntoConstraints = false

        let refreshBtn = NSButton(title: "刷新", target: self, action: #selector(refreshAction))
        refreshBtn.bezelStyle = .rounded
        refreshBtn.toolTip = "重新扫描所有窗口"
        refreshBtn.translatesAutoresizingMaskIntoConstraints = false

        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        scroll.drawsBackground = false
        scroll.translatesAutoresizingMaskIntoConstraints = false

        tableView = NSTableView()
        tableView.headerView = nil
        tableView.rowHeight = 34
        tableView.style = .inset
        tableView.allowsMultipleSelection = false
        tableView.intercellSpacing = NSSize(width: 0, height: 2)
        let col = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("main"))
        col.resizingMask = .autoresizingMask
        tableView.addTableColumn(col)
        tableView.dataSource = self
        tableView.delegate = self
        tableView.target = self
        tableView.action = #selector(rowClicked)
        scroll.documentView = tableView

        statusLabel = NSTextField(labelWithString: "")
        statusLabel.font = .systemFont(ofSize: 11)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.lineBreakMode = .byTruncatingTail
        statusLabel.translatesAutoresizingMaskIntoConstraints = false

        content.addSubview(searchField)
        content.addSubview(permBtn)
        content.addSubview(refreshBtn)
        content.addSubview(scroll)
        content.addSubview(statusLabel)

        NSLayoutConstraint.activate([
            searchField.topAnchor.constraint(equalTo: content.topAnchor, constant: 14),
            searchField.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 14),

            permBtn.centerYAnchor.constraint(equalTo: searchField.centerYAnchor),
            permBtn.leadingAnchor.constraint(equalTo: searchField.trailingAnchor, constant: 8),
            permBtn.widthAnchor.constraint(equalToConstant: 56),

            refreshBtn.centerYAnchor.constraint(equalTo: searchField.centerYAnchor),
            refreshBtn.leadingAnchor.constraint(equalTo: permBtn.trailingAnchor, constant: 8),
            refreshBtn.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -14),
            refreshBtn.widthAnchor.constraint(equalToConstant: 62),

            scroll.topAnchor.constraint(equalTo: searchField.bottomAnchor, constant: 12),
            scroll.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 4),
            scroll.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -4),
            scroll.bottomAnchor.constraint(equalTo: statusLabel.topAnchor, constant: -6),

            statusLabel.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 14),
            statusLabel.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -14),
            statusLabel.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -10)
        ])

        win.makeKeyAndOrderFront(nil)
    }

    // MARK: 数据

    @objc func openPermSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    func startPermissionWatch() {
        permTimer?.invalidate()
        permTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] t in
            guard let self = self else { t.invalidate(); return }
            if AXIsProcessTrusted() {
                t.invalidate()
                self.permTimer = nil
                self.refresh()
            }
        }
    }

    @objc func showWindowAction() { showMainWindow() }
    @objc func refreshAction() { refresh() }
    @objc func searchChanged() { applyFilter() }

    func refresh() {
        allInfos = collectWindows()
        applyFilter()
    }

    func applyFilter() {
        guard AXIsProcessTrusted() else {
            rows = []
            tableView.reloadData()
            statusLabel.stringValue = "⚠️ 需要「辅助功能」权限：点「权限」按钮 → 勾选「窗口总览」。授权后会自动刷新；若仍为空，退出重开一次本应用。"
            return
        }
        let q = searchField.stringValue.trimmingCharacters(in: .whitespaces).lowercased()
        var list = allInfos
        if !q.isEmpty {
            list = allInfos.filter { $0.title.lowercased().contains(q) || $0.appName.lowercased().contains(q) }
        }

        let grouped = Dictionary(grouping: list, by: { $0.appName })
        var newRows: [Row] = []
        for name in grouped.keys.sorted() {
            let items = grouped[name]!.sorted { $0.title < $1.title }
            let icon = NSRunningApplication(processIdentifier: items[0].pid)?.icon
            newRows.append(.group(name: name, icon: icon, count: items.count))
            for w in items { newRows.append(.win(w)) }
        }
        rows = newRows
        tableView.reloadData()

        let mins = list.filter { $0.minimized }.count
        let away = list.filter { !$0.minimized && !$0.onscreen }.count
        var parts = ["共 \(list.count) 个窗口 / \(grouped.count) 个应用"]
        if mins > 0 { parts.append("\(mins) 个已最小化") }
        if away > 0 { parts.append("\(away) 个在别的空间") }
        if !q.isEmpty { parts.append("筛选中") }
        statusLabel.stringValue = parts.joined(separator: " · ")
    }

    // MARK: 行操作：切到前台 / 关闭 / 最小化

    @objc func rowClicked() {
        let r = tableView.clickedRow
        guard r >= 0, r < rows.count else { return }
        if case .win(let info) = rows[r] { bringToFront(info) }
    }

    func displayName(_ info: WinInfo) -> String {
        info.title.isEmpty ? "(无标题窗口)" : info.title
    }

    /// 延迟刷新（操作后让系统先完成状态变更，再回读）
    func refreshSoon(_ delay: Double = 0.8) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in self?.refresh() }
    }

    /// 切到前台：解除最小化 + 激活应用 + 置前
    func bringToFront(_ info: WinInfo) {
        if let app = NSRunningApplication(processIdentifier: info.pid) {
            if app.isHidden { app.unhide() }
            app.activate(options: [.activateAllWindows])
        }
        if info.minimized {
            _ = AXUIElementSetAttributeValue(info.ax, kAXMinimizedAttribute as CFString, kCFBooleanFalse)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            _ = AXUIElementPerformAction(info.ax, kAXRaiseAction as CFString)
        }
        statusLabel.stringValue = "已调出：\(info.appName) — \(displayName(info))"
        refreshSoon(1.2)
    }

    /// 关闭：等价于点这个窗口左上角的红色按钮。
    /// 实现方式是按该窗口的 AX「关闭按钮」，不是杀进程 —— 应用自己的
    /// 「是否保存」等确认流程会正常弹出。
    func closeWindow(_ info: WinInfo) {
        guard let ref = axCopy(info.ax, kAXCloseButtonAttribute as CFString) else {
            statusLabel.stringValue = "⚠️ 这个窗口没有可用的关闭按钮（浮动播放窗、无标题窗常见），无法用此方式关闭"
            return
        }
        let btn = unsafeBitCast(ref, to: AXUIElement.self)
        let err = AXUIElementPerformAction(btn, kAXPressAction as CFString)
        if err == .success {
            statusLabel.stringValue = "已关闭：\(info.appName) — \(displayName(info))"
            refreshSoon()
        } else {
            statusLabel.stringValue = "关闭失败：\(info.appName) — \(displayName(info))（AX 错误码 \(err.rawValue)）"
        }
    }

    /// 最小化
    func minimizeWindow(_ info: WinInfo) {
        let err = AXUIElementSetAttributeValue(info.ax, kAXMinimizedAttribute as CFString, kCFBooleanTrue)
        if err == .success {
            statusLabel.stringValue = "已最小化：\(info.appName) — \(displayName(info))"
            refreshSoon(0.5)
        } else {
            statusLabel.stringValue = "最小化失败：\(info.appName) — \(displayName(info))（AX 错误码 \(err.rawValue)）"
        }
    }

    // MARK: 表格

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tv: NSTableView, heightOfRow row: Int) -> CGFloat {
        if case .group = rows[row] { return 30 }
        return 34
    }

    func tableView(_ tv: NSTableView, viewFor col: NSTableColumn?, row: Int) -> NSView? {
        let container = NSView()

        switch rows[row] {
        case .group(let name, let icon, let count):
            let iv = NSImageView()
            iv.image = icon
            iv.imageScaling = .scaleProportionallyDown
            iv.translatesAutoresizingMaskIntoConstraints = false

            let tf = NSTextField(labelWithString: "\(name)   \(count) 个窗口")
            tf.font = .systemFont(ofSize: 12, weight: .semibold)
            tf.textColor = .secondaryLabelColor
            tf.translatesAutoresizingMaskIntoConstraints = false

            container.addSubview(iv)
            container.addSubview(tf)
            NSLayoutConstraint.activate([
                iv.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 12),
                iv.centerYAnchor.constraint(equalTo: container.centerYAnchor),
                iv.widthAnchor.constraint(equalToConstant: 16),
                iv.heightAnchor.constraint(equalToConstant: 16),
                tf.leadingAnchor.constraint(equalTo: iv.trailingAnchor, constant: 7),
                tf.centerYAnchor.constraint(equalTo: container.centerYAnchor),
                tf.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor, constant: -12)
            ])

        case .win(let info):
            let tf = NSTextField(labelWithString: info.title.isEmpty ? "(无标题窗口)" : info.title)
            tf.font = .systemFont(ofSize: 13)
            tf.lineBreakMode = .byTruncatingTail
            tf.textColor = info.title.isEmpty ? .tertiaryLabelColor : .labelColor
            tf.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            tf.translatesAutoresizingMaskIntoConstraints = false

            let sizeLabel = NSTextField(labelWithString: "\(info.width)×\(info.height)")
            sizeLabel.font = .monospacedDigitSystemFont(ofSize: 10, weight: .regular)
            sizeLabel.textColor = .tertiaryLabelColor
            sizeLabel.setContentHuggingPriority(.required, for: .horizontal)
            sizeLabel.translatesAutoresizingMaskIntoConstraints = false

            let badge = NSTextField(labelWithString: "")
            badge.font = .systemFont(ofSize: 11, weight: .medium)
            badge.setContentHuggingPriority(.required, for: .horizontal)
            badge.translatesAutoresizingMaskIntoConstraints = false
            if info.minimized {
                badge.stringValue = "已最小化"
                badge.textColor = .systemOrange
            } else if !info.onscreen {
                badge.stringValue = "在其他空间"
                badge.textColor = .systemBlue
            }

            let closeBtn = CellActionButton(symbol: "xmark", tooltip: "关闭窗口（等于点窗口左上角的红点）",
                                            tint: .secondaryLabelColor) { [weak self] in
                self?.closeWindow(info)
            }
            let minBtn = CellActionButton(symbol: "minus", tooltip: "最小化窗口",
                                          tint: .secondaryLabelColor) { [weak self] in
                self?.minimizeWindow(info)
            }
            let frontBtn = CellActionButton(symbol: "arrow.up.forward.app", tooltip: "切到前台（解除最小化并置前）",
                                            tint: .systemBlue) { [weak self] in
                self?.bringToFront(info)
            }
            if info.minimized {
                minBtn.isEnabled = false
                minBtn.toolTip = "这个窗口已经是最小化了"
            }

            container.addSubview(tf)
            container.addSubview(sizeLabel)
            container.addSubview(badge)
            container.addSubview(closeBtn)
            container.addSubview(minBtn)
            container.addSubview(frontBtn)
            NSLayoutConstraint.activate([
                tf.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 38),
                tf.centerYAnchor.constraint(equalTo: container.centerYAnchor),

                // 按钮组固定在最右端，从右往左挂：切到前台 / 最小化 / 关闭
                frontBtn.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -12),
                frontBtn.centerYAnchor.constraint(equalTo: container.centerYAnchor),
                frontBtn.widthAnchor.constraint(equalToConstant: 24),
                frontBtn.heightAnchor.constraint(equalToConstant: 22),

                minBtn.trailingAnchor.constraint(equalTo: frontBtn.leadingAnchor, constant: -2),
                minBtn.centerYAnchor.constraint(equalTo: container.centerYAnchor),
                minBtn.widthAnchor.constraint(equalToConstant: 24),
                minBtn.heightAnchor.constraint(equalToConstant: 22),

                closeBtn.trailingAnchor.constraint(equalTo: minBtn.leadingAnchor, constant: -2),
                closeBtn.centerYAnchor.constraint(equalTo: container.centerYAnchor),
                closeBtn.widthAnchor.constraint(equalToConstant: 24),
                closeBtn.heightAnchor.constraint(equalToConstant: 22),

                badge.trailingAnchor.constraint(equalTo: closeBtn.leadingAnchor, constant: -8),
                badge.centerYAnchor.constraint(equalTo: container.centerYAnchor),

                sizeLabel.trailingAnchor.constraint(equalTo: badge.leadingAnchor, constant: -10),
                sizeLabel.centerYAnchor.constraint(equalTo: container.centerYAnchor),

                tf.trailingAnchor.constraint(lessThanOrEqualTo: sizeLabel.leadingAnchor, constant: -8)
            ])
        }

        return container
    }
}

// MARK: - 启动

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
