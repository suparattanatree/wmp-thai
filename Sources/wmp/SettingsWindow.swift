import AppKit
import ServiceManagement
import SwiftUI
import WmpCore

/// Settings window: sidebar and grouped form, the shape System Settings uses.
final class SettingsWindowController: NSWindowController {
    convenience init(settings: Settings, log: FixLog, corrector: Corrector, layoutSummary: String, status: RuntimeStatus) {
        let root = SettingsView(settings: settings, log: log, corrector: corrector,
                                layoutSummary: layoutSummary, status: status)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 720, height: 520),
            styleMask: [.titled, .closable, .miniaturizable, .fullSizeContentView],
            backing: .buffered, defer: false
        )
        window.title = "wmp-ไทย"
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        window.contentViewController = NSHostingController(rootView: root)
        window.setContentSize(NSSize(width: 720, height: 520))
        window.center()
        self.init(window: window)
    }

    func show() {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}

struct SettingsView: View {
    @ObservedObject var settings: Settings
    @ObservedObject var log: FixLog
    let corrector: Corrector
    let layoutSummary: String
    @ObservedObject var status: RuntimeStatus
    @StateObject private var updates = UpdateChecker()

    @State private var pane: Pane = .general

    enum Pane: String, CaseIterable, Identifiable {
        case general, sensitivity, words, apps, tryIt
        var id: String { rawValue }

        var title: String {
            switch self {
            case .general: "ทั่วไป"
            case .sensitivity: "ความไว"
            case .words: "คลังคำ"
            case .apps: "ยกเว้น"
            case .tryIt: "ลองดู"
            }
        }

        var symbol: String {
            switch self {
            case .general: "gearshape"
            case .sensitivity: "dial.medium"
            case .words: "text.book.closed"
            case .apps: "square.grid.2x2"
            case .tryIt: "text.cursor"
            }
        }
    }

    var body: some View {
        NavigationSplitView {
            List(Pane.allCases, selection: $pane) { item in
                Label(item.title, systemImage: item.symbol).tag(item)
            }
            .navigationSplitViewColumnWidth(min: 168, ideal: 176, max: 200)
            .safeAreaInset(edge: .bottom) {
                VersionFooter(updates: updates)
            }
            .task { updates.check() }
        } detail: {
            VStack(spacing: 0) {
                if !status.state.isLive {
                    StatusBanner(state: status.state)
                }
                Group {
                    switch pane {
                    case .general: GeneralPane(settings: settings, layoutSummary: layoutSummary, status: status)
                    case .sensitivity: SensitivityPane(settings: settings)
                    case .words: WordsPane(settings: settings)
                    case .apps: AppsPane(settings: settings)
                    case .tryIt: TryItPane(corrector: corrector, log: log)
                    }
                }
            }
            .navigationTitle(pane.title)
        }
        .frame(minWidth: 680, minHeight: 480)
    }
}

/// Says when the tool is not watching the keyboard, and what fixes it.
private struct StatusBanner: View {
    let state: RuntimeStatus.State

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: state.symbol)
                .foregroundStyle(state == .previewOnly ? AnyShapeStyle(.secondary) : AnyShapeStyle(.orange))
            VStack(alignment: .leading, spacing: 2) {
                Text(state.title).bold()
                Text(state.detail).font(.callout).foregroundStyle(.secondary)
            }
            Spacer()
            if state == .needsPermission {
                Button("เปิดการตั้งค่า") {
                    let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
                    NSWorkspace.shared.open(url)
                }
                .buttonStyle(.glass)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.35))
    }
}

/// Title with a quiet line of explanation underneath.
private func caption(_ title: String, _ detail: String) -> some View {
    VStack(alignment: .leading, spacing: 2) {
        Text(title)
        Text(detail).font(.callout).foregroundStyle(.secondary)
    }
}

// MARK: - General

private struct GeneralPane: View {
    @ObservedObject var settings: Settings
    let layoutSummary: String
    @ObservedObject var status: RuntimeStatus
    @State private var openAtLogin = SMAppService.mainApp.status == .enabled
    var body: some View {
        Form {
            Section {
                LabeledContent("สถานะ") {
                    Label(status.state.title, systemImage: status.state.symbol)
                        .foregroundStyle(status.state.isLive ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
                }
                Toggle("เปิดใช้งาน", isOn: $settings.enabled)
                Toggle("แก้ให้อัตโนมัติ", isOn: $settings.autoFix)
            }

            Section("ทิศทางที่แก้") {
                Picker("", selection: $settings.direction) {
                    ForEach(Settings.Direction.allCases) { direction in
                        Text(direction.title).tag(direction)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }

            Section("จังหวะที่แก้") {
                Toggle("แก้ทันทีที่หยุดพิมพ์", isOn: $settings.idleFix)
                if settings.idleFix {
                    LabeledContent("หยุดนานเท่าไหร่") {
                        HStack(spacing: 12) {
                            Slider(value: Binding(
                                get: { Double(settings.idleDelayMilliseconds) },
                                set: { settings.idleDelayMilliseconds = Int($0) }
                            ), in: 150...2000, step: 50)
                            Text("\(settings.idleDelayMilliseconds) ms")
                                .monospacedDigit().foregroundStyle(.secondary)
                                .frame(width: 64, alignment: .trailing)
                        }
                    }
                }
                Toggle("สลับกลางคำ ไม่ต้องรอจบคำ", isOn: $settings.liveSwitch)
                Toggle("สลับแป้นให้หลังแก้", isOn: $settings.switchInputSource)
            }

            Section {
                Toggle("เปิดเองตอน login", isOn: $openAtLogin)
                    .onChange(of: openAtLogin) { _, wanted in
                        do {
                            wanted ? try SMAppService.mainApp.register() : try SMAppService.mainApp.unregister()
                        } catch {
                            NSLog("wmp-ไทย login item: \(error)")
                            openAtLogin = SMAppService.mainApp.status == .enabled
                        }
                    }
                LabeledContent("เลย์เอาต์", value: layoutSummary)
                LabeledContent("ย้อนการแก้ล่าสุด", value: "⌃⌥Z")
                LabeledContent("สลับคำล่าสุดเอง", value: "⌃⌥L")
                LabeledContent("สนับสนุน") {
                    Link("ko-fi.com/memorist", destination: URL(string: "https://ko-fi.com/memorist")!)
                }
            }
        }
        .formStyle(.grouped)
    }
}

/// Version and, only when there is one, the update. Sits under the sidebar so
/// it is visible from every pane without taking a row in any of them.
private struct VersionFooter: View {
    @ObservedObject var updates: UpdateChecker

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Divider()
            HStack {
                Text("เวอร์ชัน \(updates.currentVersion)")
                    .font(.callout).foregroundStyle(.secondary)
                Spacer()
                if case .checking = updates.state {
                    ProgressView().controlSize(.small)
                }
            }
            if case .available(let version, let url) = updates.state {
                if updates.canInstall {
                    Button("อัปเดตเป็น \(version)") { updates.installUpdate() }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                } else {
                    Link("ดาวน์โหลด \(version)", destination: url)
                        .font(.callout)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 10)
    }
}

// MARK: - Sensitivity

private struct SensitivityPane: View {
    @ObservedObject var settings: Settings
    @State private var showsAdvanced = false

    var body: some View {
        Form {
            Section {
                Picker("", selection: Binding(
                    get: { settings.sensitivity ?? .balanced },
                    set: { settings.apply($0) }
                )) {
                    ForEach(Settings.Sensitivity.allCases) { preset in
                        Text(preset.title).tag(preset)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()

                Text(settings.sensitivity?.detail ?? "ปรับเอง")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            Section {
                Toggle(isOn: $settings.guessWhenUnreadable) {
                    caption("เดาให้ถ้าอ่านไม่ออก", "ช่วยพวกชื่อเฉพาะและคำแสลงที่ไม่มีในคลังคำ")
                }
            }

            Section {
                DisclosureGroup("ปรับเอง", isExpanded: $showsAdvanced) {
                    slider("คำที่แปลงแล้วต้องมั่นใจอย่างน้อย", value: $settings.minimumReplacementScore)
                    slider("คำที่พิมพ์ไปต้องดูไม่เป็นภาษาเกิน", value: $settings.maximumOriginalScore)
                    slider("ต้องชนะกันอย่างน้อย", value: $settings.minimumGap)
                    stepper("สั้นกว่านี้ไม่แก้", value: $settings.minimumLength, range: 2...8)
                    stepper("ยาวเกินนี้ไม่แก้", value: $settings.maximumLength, range: 10...100)
                    stepper("รอกี่ตัวก่อนสลับกลางคำ", value: $settings.minimumPrefixLength, range: 2...8)
                }
            } footer: {
                HStack {
                    Text("ค่าที่ปรับมีผลทันที ดูผลได้ที่หน้า \"ลองดู\"")
                        .font(.callout).foregroundStyle(.secondary)
                    Spacer()
                    Button("คืนค่าเริ่มต้น") { settings.resetThresholds() }
                }
                .padding(.top, 6)
            }
        }
        .formStyle(.grouped)
    }

    private func slider(_ title: String, value: Binding<Double>) -> some View {
        LabeledContent(title) {
            HStack(spacing: 12) {
                Slider(value: value, in: 0...1, step: 0.05)
                Text(String(format: "%.2f", value.wrappedValue))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .frame(width: 36, alignment: .trailing)
            }
        }
    }

    private func stepper(_ title: String, value: Binding<Int>, range: ClosedRange<Int>) -> some View {
        Stepper(value: value, in: range) {
            LabeledContent(title, value: "\(value.wrappedValue)")
        }
    }
}

// MARK: - Excluded apps

private struct AppsPane: View {
    @ObservedObject var settings: Settings
    @State private var selection: String?
    @State private var newHost = ""
    @State private var hostSelection: String?

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    Toggle(isOn: $settings.skipSensitiveFields) {
                        caption("ข้ามช่องรหัสผ่าน อีเมล ชื่อผู้ใช้", "ดูจากชนิดและชื่อของช่อง ใช้ได้ทั้งเว็บและแอป")
                    }
                }
            }
            .formStyle(.grouped)
            .frame(height: 96)

            Divider()
            HStack(spacing: 8) {
                TextField("ยกเว้นเว็บ เช่น bank.co.th", text: $newHost)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { addHost() }
                Button("เพิ่ม") { addHost() }
                    .disabled(newHost.trimmingCharacters(in: .whitespaces).isEmpty)
                Button {
                    guard let hostSelection else { return }
                    settings.excludedHosts.removeAll { $0 == hostSelection }
                    self.hostSelection = nil
                } label: {
                    Image(systemName: "minus").frame(width: 16, height: 16)
                }
                .disabled(hostSelection == nil)
            }
            .buttonStyle(.glass)
            .padding(12)

            if !settings.excludedHosts.isEmpty {
                List(selection: $hostSelection) {
                    ForEach(settings.excludedHosts, id: \.self) { host in
                        Label(host, systemImage: "globe").tag(host)
                    }
                }
                .listStyle(.inset)
                .frame(height: 90)
                Divider()
            }

            if settings.excludedBundleIDs.isEmpty {
                ContentUnavailableView(
                    "ยังไม่ได้ยกเว้นแอปไหน",
                    systemImage: "square.grid.2x2",
                    description: Text("แอปที่เพิ่มตรงนี้จะไม่ถูกแตะเลย")
                )
            } else {
                List(selection: $selection) {
                    ForEach(settings.excludedBundleIDs, id: \.self) { bundleID in
                        row(for: bundleID).tag(bundleID)
                    }
                }
                .listStyle(.inset)
            }

            Divider()
            HStack(spacing: 8) {
                Button { addApp() } label: {
                    Image(systemName: "plus").frame(width: 16, height: 16)
                }
                .help("เพิ่มแอป")
                Button {
                    guard let selection else { return }
                    settings.excludedBundleIDs.removeAll { $0 == selection }
                    self.selection = nil
                } label: {
                    Image(systemName: "minus").frame(width: 16, height: 16)
                }
                .help("เอาแอปที่เลือกออก")
                .disabled(selection == nil)
                Spacer()
            }
            .buttonStyle(.glass)
            .padding(12)
        }
    }

    private func row(for bundleID: String) -> some View {
        let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
        return HStack(spacing: 10) {
            if let url {
                Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
                    .resizable().frame(width: 22, height: 22)
            } else {
                Image(systemName: "questionmark.app.dashed")
                    .frame(width: 22, height: 22)
                    .foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(url.map { FileManager.default.displayName(atPath: $0.path) } ?? bundleID)
                Text(bundleID).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.vertical, 3)
    }

    private func addHost() {
        // "google.com" should cover mail.google.com too, so store the bare host.
        var host = newHost.trimmingCharacters(in: .whitespaces).lowercased()
        if let url = URL(string: host), let parsed = url.host { host = parsed }
        host = host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
        guard !host.isEmpty, !settings.excludedHosts.contains(host) else { return }
        settings.excludedHosts.append(host)
        newHost = ""
    }

    private func addApp() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.allowsMultipleSelection = true
        guard panel.runModal() == .OK else { return }
        for url in panel.urls {
            guard let bundleID = Bundle(url: url)?.bundleIdentifier,
                  !settings.excludedBundleIDs.contains(bundleID) else { continue }
            settings.excludedBundleIDs.append(bundleID)
        }
    }
}

// MARK: - Try it

private struct TryItPane: View {
    let corrector: Corrector
    @ObservedObject var log: FixLog
    @State private var text = "l;ylfu ้ำสสน สวัสดี hello"

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                TextField("พิมพ์หรือวางข้อความ", text: $text, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(.title3)
                    .lineLimit(1...3)
                    .padding(12)
                    .background(.quaternary.opacity(0.4), in: .rect(cornerRadius: 12))
                Text("ดูว่าตอนนี้จะทำอะไรกับแต่ละคำ")
                    .font(.callout).foregroundStyle(.secondary)
            }

            ScrollView {
                LazyVStack(spacing: 8) {
                    ForEach(corrector.simulate(text)) { result in
                        verdict(for: result)
                    }
                }
            }

            if !log.entries.isEmpty {
                Divider()
                HStack {
                    Text("แก้ไปจริงล่าสุด").font(.callout).foregroundStyle(.secondary)
                    Spacer()
                    Button("ล้าง") { log.clear() }
                        .buttonStyle(.link)
                        .font(.callout)
                }
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 6) {
                        ForEach(log.entries) { entry in
                            HStack(spacing: 8) {
                                Image(systemName: entry.midWord ? "bolt" : "space")
                                    .foregroundStyle(.secondary).frame(width: 16)
                                Text(entry.original).foregroundStyle(.secondary)
                                Image(systemName: "arrow.right").font(.caption2).foregroundStyle(.tertiary)
                                Text(entry.replacement)
                                Spacer()
                            }
                        }
                    }
                }
                .frame(height: 92)
            }
        }
        .padding(20)
    }

    @ViewBuilder
    private func verdict(for result: Corrector.Simulation) -> some View {
        let touched = result.isTouched
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: touched ? (result.midWord != nil ? "bolt" : "space") : "minus")
                .foregroundStyle(touched ? AnyShapeStyle(.primary) : AnyShapeStyle(.tertiary))
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 8) {
                    Text(result.word).foregroundStyle(touched ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
                    if touched {
                        Image(systemName: "arrow.right").font(.caption2).foregroundStyle(.tertiary)
                        Text(result.outcome).bold()
                    }
                }
                Text(explanation(for: result))
                    .font(.callout).foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(touched ? 0.3 : 0.15), in: .rect(cornerRadius: 10))
    }

    private func explanation(for result: Corrector.Simulation) -> String {
        if let at = result.midWordAt, let midWord = result.midWord {
            return "สลับให้ตั้งแต่ตัวที่ \(at) จาก \(result.keys) (ตอนนั้นได้ \(midWord.replacement)) ที่เหลือพิมพ์ต่อได้เลย"
        }
        if result.atSpace != nil {
            return "แก้ให้ตอนเคาะ space"
        }
        return "ไม่แตะ"
    }
}

// MARK: - Word lists

/// The three layers of vocabulary.
private struct WordsPane: View {
    @ObservedObject var settings: Settings
    @State private var userWords: [String] = WordListBuilder.words(at: WordListBuilder.userListURL)
    @State private var newWord = ""
    @State private var selection: String?
    @State private var rebuilding = false
    @State private var builtCounts: (thai: Int, english: Int)?

    private var curatedCount: Int {
        WordListBuilder.words(at: WordListBuilder.curatedThaiURL).count
            + WordListBuilder.words(at: WordListBuilder.curatedEnglishURL).count
    }

    private var builtSummary: String {
        if rebuilding { return "กำลังสร้าง..." }
        if let counts = builtCounts { return "ไทย \(counts.thai) · อังกฤษ \(counts.english)" }
        guard WordListBuilder.isBuilt else { return "ยังไม่ได้สร้าง" }
        let thai = WordListBuilder.words(at: WordListBuilder.thaiListURL).count
        let english = WordListBuilder.words(at: WordListBuilder.englishListURL).count
        return "ไทย \(thai) · อังกฤษ \(english)"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Form {
                Section {
                    LabeledContent("จากเครื่องนี้") {
                        HStack(spacing: 10) {
                            Text(builtSummary).foregroundStyle(.secondary)
                            Button("สร้างใหม่") { rebuild() }.disabled(rebuilding)
                        }
                    }
                    Toggle(isOn: $settings.useSystemDictionary) {
                        caption("ใช้ดิกชันนารีไทยของ macOS", "+36,000 คำ แต่ต้องแกะไฟล์ลิขสิทธิ์ของ Apple")
                    }
                    .onChange(of: settings.useSystemDictionary) { _, _ in rebuild() }
                    LabeledContent("ที่มากับแอป", value: "\(curatedCount) คำ")
                    LabeledContent("ที่คุณเพิ่มเอง", value: "\(userWords.count) คำ")
                } footer: {
                    Text("คำที่กด ⌃⌥Z ย้อน จะถูกจำไว้ให้เอง")
                        .font(.callout).foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
            .frame(height: 190)

            Divider()

            if userWords.isEmpty {
                ContentUnavailableView(
                    "ยังไม่มีคำของคุณ",
                    systemImage: "text.book.closed",
                    description: Text("เพิ่มคำที่ไม่อยากให้แก้ หรือคำที่อยากให้รู้จัก")
                )
            } else {
                List(selection: $selection) {
                    ForEach(userWords, id: \.self) { word in
                        Text(word).tag(word)
                    }
                }
                .listStyle(.inset)
            }

            Divider()
            HStack(spacing: 8) {
                TextField("เพิ่มคำ", text: $newWord)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { add() }
                Button("เพิ่ม") { add() }
                    .disabled(newWord.trimmingCharacters(in: .whitespaces).isEmpty)
                Button { remove() } label: {
                    Image(systemName: "minus").frame(width: 16, height: 16)
                }
                .help("เอาคำที่เลือกออก")
                .disabled(selection == nil)
                Button("ล้างทั้งหมด") {
                    WordListBuilder.save(userWords: [])
                    refresh()
                }
                .disabled(userWords.isEmpty)
            }
            .buttonStyle(.glass)
            .padding(12)
        }
    }

    private func add() {
        WordListBuilder.addUserWord(newWord)
        newWord = ""
        refresh()
    }

    private func remove() {
        guard let selection else { return }
        WordListBuilder.removeUserWord(selection)
        self.selection = nil
        refresh()
    }

    private func rebuild() {
        rebuilding = true
        DispatchQueue.global(qos: .userInitiated).async {
            let counts = try? WordListBuilder.build(includeSystemDictionary: settings.useSystemDictionary)
            DispatchQueue.main.async {
                builtCounts = counts
                rebuilding = false
                NotificationCenter.default.post(name: .wmpWordListsRebuilt, object: nil)
            }
        }
    }

    private func refresh() {
        userWords = WordListBuilder.words(at: WordListBuilder.userListURL)
        NotificationCenter.default.post(name: .wmpWordListsRebuilt, object: nil)
    }
}
