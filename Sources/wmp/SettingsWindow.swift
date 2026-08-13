import AppKit
import ServiceManagement
import SwiftUI
import WmpCore

/// The settings window: a sidebar and a grouped form, the shape System Settings
/// uses, so it reads as part of the system rather than a utility bolted on.
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

    @State private var pane: Pane = .general

    enum Pane: String, CaseIterable, Identifiable {
        case general, sensitivity, apps, tryIt
        var id: String { rawValue }

        var title: String {
            switch self {
            case .general: "ทั่วไป"
            case .sensitivity: "ความไว"
            case .apps: "ยกเว้นแอป"
            case .tryIt: "ลองดู"
            }
        }

        var symbol: String {
            switch self {
            case .general: "gearshape"
            case .sensitivity: "dial.medium"
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
        } detail: {
            VStack(spacing: 0) {
                if !status.state.isLive {
                    StatusBanner(state: status.state)
                }
                Group {
                    switch pane {
                    case .general: GeneralPane(settings: settings, layoutSummary: layoutSummary, status: status)
                    case .sensitivity: SensitivityPane(settings: settings)
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

/// Says out loud when the tool is not actually watching the keyboard, with the
/// one action that fixes it.
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

/// Title with a quiet line of explanation underneath: enough that no setting
/// needs a manual, few enough words to stay out of the way.
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
    @StateObject private var updates = UpdateChecker()
    @State private var openAtLogin = SMAppService.mainApp.status == .enabled
    @State private var rebuilding = false
    @State private var wordListCounts: (thai: Int, english: Int)?

    private var wordListSummary: String {
        if rebuilding { return "กำลังสร้าง..." }
        if let counts = wordListCounts { return "ไทย \(counts.thai) · อังกฤษ \(counts.english) คำ" }
        return WordListBuilder.isBuilt ? "สร้างจากเครื่องนี้แล้ว" : "ยังไม่ได้สร้าง"
    }

    /// Worth offering: installing a new dictionary or a new app adds vocabulary
    /// the lists were built without.
    private func rebuildWordLists() {
        rebuilding = true
        DispatchQueue.global(qos: .userInitiated).async {
            let counts = try? WordListBuilder.build()
            DispatchQueue.main.async {
                wordListCounts = counts
                rebuilding = false
                NotificationCenter.default.post(name: .wmpWordListsRebuilt, object: nil)
            }
        }
    }

    var body: some View {
        Form {
            Section {
                LabeledContent("สถานะ") {
                    Label(status.state.title, systemImage: status.state.symbol)
                        .foregroundStyle(status.state.isLive ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
                }
                Toggle("เปิดใช้งาน", isOn: $settings.enabled)
                Toggle(isOn: $settings.autoFix) {
                    caption("แก้ให้อัตโนมัติ", "ปิดไว้ = ตรวจจับและบันทึกไว้เฉย ๆ ไม่แตะข้อความ")
                }
            }

            Section("ทิศทางที่แก้") {
                Picker("", selection: $settings.direction) {
                    ForEach(Settings.Direction.allCases) { direction in
                        Text(direction.title).tag(direction)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                Text(settings.direction.detail)
                    .font(.callout).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            Section("จังหวะที่แก้") {
                Toggle(isOn: $settings.idleFix) {
                    caption("แก้ทันทีที่หยุดพิมพ์", "ไม่ต้องรอเคาะ space")
                }
                if settings.idleFix {
                    LabeledContent("หยุดนานแค่ไหนถึงถือว่าหยุด") {
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
                Toggle(isOn: $settings.liveSwitch) {
                    caption("สลับกลางคำ", "ไม่ต้องรอเคาะ space ปกติจับได้ภายใน 3-5 ตัว")
                }
                Toggle(isOn: $settings.switchInputSource) {
                    caption("สลับแป้นให้หลังแก้", "คำถัดไปจะได้พิมพ์ถูกภาษาต่อเลย")
                }
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
                LabeledContent("เวอร์ชัน") {
                    HStack(spacing: 10) {
                        switch updates.state {
                        case .checking:
                            Text("\(updates.currentVersion) · กำลังตรวจ...").foregroundStyle(.secondary)
                        case .upToDate:
                            Text("\(updates.currentVersion) · ใหม่ล่าสุดแล้ว").foregroundStyle(.secondary)
                        case .available(let version, let url):
                            Text("\(updates.currentVersion) · มี \(version) ใหม่")
                            Link("ดาวน์โหลด", destination: url)
                        case .failed(let reason):
                            Text("\(updates.currentVersion) · \(reason)").foregroundStyle(.secondary)
                        case .idle:
                            Text(updates.currentVersion).foregroundStyle(.secondary)
                        }
                        Button("ตรวจหาอัปเดต") { updates.check() }
                    }
                }
                LabeledContent("คลังคำ") {
                    HStack(spacing: 10) {
                        Text(wordListSummary).foregroundStyle(.secondary)
                        Button("สร้างใหม่") { rebuildWordLists() }
                            .disabled(rebuilding)
                    }
                }
                LabeledContent("เลย์เอาต์", value: layoutSummary)
                LabeledContent("ย้อนการแก้ล่าสุด", value: "⌃⌥Z")
                LabeledContent("สลับคำล่าสุดเอง", value: "⌃⌥L")
            }
        }
        .formStyle(.grouped)
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
                    caption("เดาให้ถ้าอ่านไม่ออก",
                            "คำที่อ่านไม่ออกในภาษาที่กำลังพิมพ์ ให้ถือว่าเป็นอีกภาษาได้เลย ไม่ต้องรอให้ตรงคลังคำ ช่วยพวกชื่อเฉพาะและคำแสลง")
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

    var body: some View {
        VStack(spacing: 0) {
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
                Button { addApp() } label: { Label("เพิ่มแอป", systemImage: "plus") }
                Button {
                    guard let selection else { return }
                    settings.excludedBundleIDs.removeAll { $0 == selection }
                    self.selection = nil
                } label: {
                    Label("เอาออก", systemImage: "minus")
                }
                .disabled(selection == nil)
                Spacer()
            }
            .labelStyle(.iconOnly)
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
                Text("ดูว่าเกณฑ์ตอนนี้จะทำอะไรกับแต่ละคำ")
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
