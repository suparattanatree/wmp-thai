import AppKit
import Combine
import ServiceManagement
import WmpCore

final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private let settings = Settings()
    private let log = FixLog()
    private let status = RuntimeStatus()
    private var statusItem: NSStatusItem!
    private var tap: EventTap?
    private var engine: Engine?
    private var settingsWindow: SettingsWindowController?
    private var cancellables: Set<AnyCancellable> = []
    private var permissionTimer: Timer?
    private var scorer: LanguageScorer?
    private var layoutSummary = "-"
    /// `--preview` opens just the settings window: no tap, no permission
    /// prompt, so the UI can be checked on its own.
    private let previewOnly = CommandLine.arguments.contains("--preview")

    func applicationDidFinishLaunching(_ notification: Notification) {
        buildStatusItem()

        guard let layouts = LayoutPair() else {
            status.state = .noLayouts
            fail("wmp-ไทย needs both a Latin (ABC or U.S.) and a Thai keyboard layout installed.\n\nAdd them in System Settings > Keyboard > Input Sources.")
            return
        }
        layoutSummary = "\(layouts.latin.localizedName) ↔ \(layouts.thai.localizedName)"

        let scorer = LanguageScorer()
        self.scorer = scorer
        let corrector = Corrector(layouts: layouts, scorer: scorer, thresholds: settings.thresholds)
        corrector.allowedTargets = settings.direction.targets
        corrector.guessWhenUnreadable = settings.guessWhenUnreadable
        let engine = Engine(layouts: layouts, corrector: corrector, settings: settings)
        engine.onCorrection = { [weak self] correction, midWord in
            self?.record(correction, midWord: midWord)
        }
        self.engine = engine

        // Anything the settings window changes reaches the running engine here.
        settings.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] in
                guard let self else { return }
                self.engine?.configure(thresholds: self.settings.thresholds,
                                       allowedTargets: self.settings.direction.targets,
                                       guessWhenUnreadable: self.settings.guessWhenUnreadable)
                self.refreshMenu()
            }
            .store(in: &cancellables)

        // Built before the permission check: if access is missing, the menu and
        // this window still have to work so there is somewhere to fix it from.
        settingsWindow = SettingsWindowController(settings: settings, log: log, corrector: corrector,
                                                  layoutSummary: layoutSummary, status: status)
        settingsWindow?.window?.delegate = self
        refreshMenu()

        if previewOnly {
            status.state = .previewOnly
            settingsWindow?.show()
            return
        }

        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak engine] _ in engine?.handleAppSwitch() }

        NotificationCenter.default.addObserver(
            forName: .wmpWordListsRebuilt, object: nil, queue: .main
        ) { [weak self] _ in self?.scorer?.reload() }

        // The word lists are built from this Mac rather than shipped, so the very
        // first launch has to make them before anything can be judged.
        guard WordListBuilder.isBuilt else {
            status.state = .buildingWordLists
            settingsWindow?.show()
            buildWordLists()
            return
        }

        guard EventTap.hasAccessibilityPermission(prompt: true) else {
            status.state = .needsPermission
            waitForPermission()
            settingsWindow?.show()
            return
        }
        startTap()
    }

    func buildWordLists() {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            _ = try? WordListBuilder.build(includeSystemDictionary: self?.settings.useSystemDictionary ?? false)
            DispatchQueue.main.async {
                guard let self else { return }
                self.scorer?.reload()
                self.status.state = .previewOnly
                self.startOrWaitForPermission()
            }
        }
    }

    private func startOrWaitForPermission() {
        guard EventTap.hasAccessibilityPermission(prompt: true) else {
            status.state = .needsPermission
            waitForPermission()
            return
        }
        startTap()
    }

    /// macOS grants Accessibility while the app is already running, so watch for
    /// it and start there and then. Nobody should have to relaunch anything.
    private func waitForPermission() {
        permissionTimer?.invalidate()
        permissionTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            guard let self, EventTap.hasAccessibilityPermission(prompt: false) else { return }
            self.permissionTimer?.invalidate()
            self.permissionTimer = nil
            self.startTap()
        }
    }

    private func startTap() {
        guard tap == nil else { return }
        let tap = EventTap { [weak self] type, event in
            switch type {
            case .keyDown: self?.engine?.handleKeyDown(event)
            case .leftMouseDown, .rightMouseDown: self?.engine?.handleMouseDown()
            default: break
            }
        }
        guard tap.start() else {
            status.state = .tapFailed
            refreshMenu()
            return
        }
        self.tap = tap
        status.state = .running
        setStatusSymbol("keyboard")
        refreshMenu()
    }

    // MARK: - Menu bar

    private func buildStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        setStatusSymbol("keyboard")
        statusItem.menu = NSMenu()
        refreshMenu()
    }

    /// The menu stays a shortcut for the switches people flip most; everything
    /// else lives in the settings window.
    private func refreshMenu() {
        guard let menu = statusItem.menu else { return }
        menu.removeAllItems()

        statusItem.button?.appearsDisabled = !settings.enabled

        let status = NSMenuItem(title: "Layouts: \(layoutSummary)", action: nil, keyEquivalent: "")
        status.isEnabled = false
        menu.addItem(status)
        menu.addItem(.separator())

        add(menu, "Enabled", #selector(toggleEnabled), on: settings.enabled)
        add(menu, "Fix automatically", #selector(toggleAutoFix), on: settings.autoFix)
        add(menu, "Switch mid-word", #selector(toggleLiveSwitch), on: settings.liveSwitch)
        menu.addItem(.separator())

        let convert = NSMenuItem(title: "Convert last word  ⌃⌥L", action: #selector(convertLastWord), keyEquivalent: "")
        convert.target = self
        menu.addItem(convert)
        let revert = NSMenuItem(title: "Undo last fix  ⌃⌥Z", action: #selector(revertLastFix), keyEquivalent: "")
        revert.target = self
        menu.addItem(revert)
        menu.addItem(.separator())

        if log.entries.isEmpty {
            let empty = NSMenuItem(title: "No fixes yet", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            menu.addItem(empty)
        } else {
            for entry in log.entries.prefix(5) {
                let item = NSMenuItem(title: "\(entry.original)  →  \(entry.replacement)", action: nil, keyEquivalent: "")
                item.isEnabled = false
                menu.addItem(item)
            }
        }
        menu.addItem(.separator())

        let preferences = NSMenuItem(title: "Settings...", action: #selector(openSettings), keyEquivalent: ",")
        preferences.target = self
        menu.addItem(preferences)
        menu.addItem(NSMenuItem(title: "Quit wmp-ไทย", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
    }

    private func setStatusSymbol(_ name: String) {
        let image = NSImage(systemSymbolName: name, accessibilityDescription: "wmp-ไทย")
        image?.isTemplate = true
        statusItem.button?.image = image
        statusItem.button?.title = image == nil ? "wmp" : ""
    }

    private func add(_ menu: NSMenu, _ title: String, _ action: Selector, on: Bool) {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        item.state = on ? .on : .off
        menu.addItem(item)
    }

    private func record(_ correction: Correction, midWord: Bool) {
        log.record(correction, midWord: midWord)
        refreshMenu()
    }

    // MARK: - Actions

    @objc private func toggleEnabled() { settings.enabled.toggle() }
    @objc private func toggleAutoFix() { settings.autoFix.toggle() }
    @objc private func toggleLiveSwitch() { settings.liveSwitch.toggle() }
    @objc private func convertLastWord() { engine?.convertLastWord() }
    @objc private func revertLastFix() { engine?.revertLastFix() }
    @objc private func openSettings() { settingsWindow?.show() }

    /// Back to a menu bar only app once the window is gone, so it stays out of
    /// the Dock and the app switcher.
    func windowWillClose(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
    }

    private func fail(_ message: String) {
        setStatusSymbol("keyboard.badge.ellipsis")
        let alert = NSAlert()
        alert.messageText = "wmp-ไทย ไม่ได้ทำงาน"
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.runModal()
    }
}
