import Combine
import Foundation
import WmpCore

/// User-visible knobs, stored in UserDefaults so they survive restarts.
///
/// Observable so the settings window and the running engine stay in step: the
/// window edits this, the app delegate pushes the result into the corrector.
final class Settings: ObservableObject {
    private let defaults = UserDefaults.standard

    private enum Key {
        static let enabled = "enabled"
        static let autoFix = "autoFix"
        static let switchInputSource = "switchInputSource"
        static let liveSwitch = "liveSwitch"
        static let direction = "direction"
        static let guessWhenUnreadable = "guessWhenUnreadable"
        static let useSystemDictionary = "useSystemDictionary"
        static let idleFix = "idleFix"
        static let idleDelay = "idleDelayMilliseconds"
        static let excluded = "excludedBundleIDs"
        static let excludedHosts = "excludedHosts"
        static let skipSensitiveFields = "skipSensitiveFields"
        static let minimumReplacementScore = "minimumReplacementScore"
        static let maximumOriginalScore = "maximumOriginalScore"
        static let minimumGap = "minimumGap"
        static let minimumLength = "minimumLength"
        static let minimumPrefixLength = "minimumPrefixLength"
        static let maximumLength = "maximumLength"
    }

    @Published var enabled: Bool { didSet { defaults.set(enabled, forKey: Key.enabled) } }
    /// Off means: detect and log, but never touch the text.
    @Published var autoFix: Bool { didSet { defaults.set(autoFix, forKey: Key.autoFix) } }
    /// After a fix, also switch the keyboard so the next word lands right.
    @Published var switchInputSource: Bool { didSet { defaults.set(switchInputSource, forKey: Key.switchInputSource) } }
    /// Switch mid-word instead of waiting for the space bar.
    @Published var liveSwitch: Bool { didSet { defaults.set(liveSwitch, forKey: Key.liveSwitch) } }
    /// Act on words no dictionary holds, when what was typed simply cannot be
    /// read in the language it landed in.
    @Published var guessWhenUnreadable: Bool { didSet { defaults.set(guessWhenUnreadable, forKey: Key.guessWhenUnreadable) } }
    /// Fix as soon as typing pauses, without waiting for the space bar.
    /// Off by default: see WordListBuilder.build for why.
    @Published var useSystemDictionary: Bool { didSet { defaults.set(useSystemDictionary, forKey: Key.useSystemDictionary) } }
    @Published var idleFix: Bool { didSet { defaults.set(idleFix, forKey: Key.idleFix) } }
    /// How long a pause counts as "stopped typing", in milliseconds.
    @Published var idleDelayMilliseconds: Int { didSet { defaults.set(idleDelayMilliseconds, forKey: Key.idleDelay) } }
    @Published var direction: Direction { didSet { defaults.set(direction.rawValue, forKey: Key.direction) } }
    @Published var excludedBundleIDs: [String] { didSet { defaults.set(excludedBundleIDs, forKey: Key.excluded) } }
    /// Websites to stay out of, matched on host.
    @Published var excludedHosts: [String] { didSet { defaults.set(excludedHosts, forKey: Key.excludedHosts) } }
    /// Leave login and payment boxes alone, wherever they are.
    @Published var skipSensitiveFields: Bool { didSet { defaults.set(skipSensitiveFields, forKey: Key.skipSensitiveFields) } }

    @Published var minimumReplacementScore: Double { didSet { defaults.set(minimumReplacementScore, forKey: Key.minimumReplacementScore) } }
    @Published var maximumOriginalScore: Double { didSet { defaults.set(maximumOriginalScore, forKey: Key.maximumOriginalScore) } }
    @Published var minimumGap: Double { didSet { defaults.set(minimumGap, forKey: Key.minimumGap) } }
    @Published var minimumLength: Int { didSet { defaults.set(minimumLength, forKey: Key.minimumLength) } }
    @Published var minimumPrefixLength: Int { didSet { defaults.set(minimumPrefixLength, forKey: Key.minimumPrefixLength) } }
    @Published var maximumLength: Int { didSet { defaults.set(maximumLength, forKey: Key.maximumLength) } }

    init() {
        let stock = CorrectorThresholds()
        defaults.register(defaults: [
            Key.enabled: true,
            Key.autoFix: true,
            Key.switchInputSource: true,
            Key.liveSwitch: true,
            Key.direction: Direction.both.rawValue,
            Key.guessWhenUnreadable: true,
            Key.useSystemDictionary: false,
            Key.idleFix: true,
            Key.idleDelay: 400,
            Key.excluded: ["com.apple.keychainaccess", "com.1password.1password", "com.agilebits.onepassword7"],
            Key.excludedHosts: [String](),
            Key.skipSensitiveFields: true,
            Key.minimumReplacementScore: stock.minimumReplacementScore,
            Key.maximumOriginalScore: stock.maximumOriginalScore,
            Key.minimumGap: stock.minimumGap,
            Key.minimumLength: stock.minimumLength,
            Key.minimumPrefixLength: stock.minimumPrefixLength,
            Key.maximumLength: stock.maximumLength,
        ])
        enabled = defaults.bool(forKey: Key.enabled)
        autoFix = defaults.bool(forKey: Key.autoFix)
        switchInputSource = defaults.bool(forKey: Key.switchInputSource)
        liveSwitch = defaults.bool(forKey: Key.liveSwitch)
        guessWhenUnreadable = defaults.bool(forKey: Key.guessWhenUnreadable)
        useSystemDictionary = defaults.bool(forKey: Key.useSystemDictionary)
        idleFix = defaults.bool(forKey: Key.idleFix)
        idleDelayMilliseconds = defaults.integer(forKey: Key.idleDelay)
        direction = Direction(rawValue: defaults.string(forKey: Key.direction) ?? "") ?? .both
        excludedBundleIDs = defaults.stringArray(forKey: Key.excluded) ?? []
        excludedHosts = defaults.stringArray(forKey: Key.excludedHosts) ?? []
        skipSensitiveFields = defaults.bool(forKey: Key.skipSensitiveFields)
        minimumReplacementScore = defaults.double(forKey: Key.minimumReplacementScore)
        maximumOriginalScore = defaults.double(forKey: Key.maximumOriginalScore)
        minimumGap = defaults.double(forKey: Key.minimumGap)
        minimumLength = defaults.integer(forKey: Key.minimumLength)
        minimumPrefixLength = defaults.integer(forKey: Key.minimumPrefixLength)
        maximumLength = defaults.integer(forKey: Key.maximumLength)
    }

    /// Which way corrections may run. Not everyone forgets both switches.
    enum Direction: String, CaseIterable, Identifiable {
        case both, toThai, toLatin
        var id: String { rawValue }

        var title: String {
            switch self {
            case .both: "ทั้งสองทาง"
            case .toThai: "ABC → ก ข ค"
            case .toLatin: "ก ข ค → ABC"
            }
        }

        var detail: String {
            switch self {
            case .both: "แก้ให้ทั้งตอนลืมสลับเป็นไทยและลืมสลับกลับเป็นอังกฤษ"
            case .toThai: "แก้เฉพาะตอนตั้งใจพิมพ์ไทยแต่แป้นยังเป็นอังกฤษ"
            case .toLatin: "แก้เฉพาะตอนตั้งใจพิมพ์อังกฤษแต่แป้นยังเป็นไทย"
            }
        }

        var targets: Set<Script> {
            switch self {
            case .both: [.thai, .latin]
            case .toThai: [.thai]
            case .toLatin: [.latin]
            }
        }
    }

    func isExcluded(_ bundleID: String?) -> Bool {
        guard let bundleID else { return false }
        return excludedBundleIDs.contains(bundleID)
    }

    /// Matches the host itself and anything under it, so "google.com" covers
    /// "mail.google.com".
    func isExcluded(host: String?) -> Bool {
        guard let host = host?.lowercased() else { return false }
        return excludedHosts.contains { entry in
            let pattern = entry.lowercased().trimmingCharacters(in: .whitespaces)
            guard !pattern.isEmpty else { return false }
            return host == pattern || host.hasSuffix("." + pattern)
        }
    }

    var thresholds: CorrectorThresholds {
        var thresholds = CorrectorThresholds()
        thresholds.minimumReplacementScore = minimumReplacementScore
        thresholds.maximumOriginalScore = maximumOriginalScore
        thresholds.minimumGap = minimumGap
        thresholds.minimumLength = minimumLength
        thresholds.minimumPrefixLength = minimumPrefixLength
        thresholds.maximumLength = maximumLength
        return thresholds
    }

    /// Three ready-made settings so the sliders stay an "advanced" detail
    /// rather than the first thing anyone has to understand.
    enum Sensitivity: String, CaseIterable, Identifiable {
        case careful, balanced, eager
        var id: String { rawValue }

        var title: String {
            switch self {
            case .careful: "ระวังตัว"
            case .balanced: "สมดุล"
            case .eager: "ไว"
            }
        }

        var detail: String {
            switch self {
            case .careful: "แก้เฉพาะตอนมั่นใจจริง ๆ พลาดบ้างแต่แทบไม่แก้ผิด"
            case .balanced: "ค่าเริ่มต้น จับได้เกือบหมดโดยยังไม่กวน"
            case .eager: "จับเร็วและบ่อยขึ้น แลกกับโอกาสแก้ผิดที่มากขึ้น"
            }
        }

        var thresholds: CorrectorThresholds {
            var thresholds = CorrectorThresholds()
            switch self {
            case .careful:
                thresholds.minimumReplacementScore = 0.9
                thresholds.maximumOriginalScore = 0.15
                thresholds.minimumGap = 0.65
                thresholds.minimumLength = 4
                thresholds.minimumPrefixLength = 4
            case .balanced:
                break
            case .eager:
                thresholds.minimumReplacementScore = 0.6
                thresholds.maximumOriginalScore = 0.35
                thresholds.minimumGap = 0.35
                thresholds.minimumLength = 3
                thresholds.minimumPrefixLength = 3
            }
            return thresholds
        }
    }

    /// Which preset the current numbers match, if any.
    var sensitivity: Sensitivity? {
        Sensitivity.allCases.first { preset in
            let t = preset.thresholds
            return t.minimumReplacementScore == minimumReplacementScore
                && t.maximumOriginalScore == maximumOriginalScore
                && t.minimumGap == minimumGap
                && t.minimumLength == minimumLength
                && t.minimumPrefixLength == minimumPrefixLength
        }
    }

    func apply(_ preset: Sensitivity) {
        let t = preset.thresholds
        minimumReplacementScore = t.minimumReplacementScore
        maximumOriginalScore = t.maximumOriginalScore
        minimumGap = t.minimumGap
        minimumLength = t.minimumLength
        minimumPrefixLength = t.minimumPrefixLength
    }

    func resetThresholds() {
        let stock = CorrectorThresholds()
        minimumReplacementScore = stock.minimumReplacementScore
        maximumOriginalScore = stock.maximumOriginalScore
        minimumGap = stock.minimumGap
        minimumLength = stock.minimumLength
        minimumPrefixLength = stock.minimumPrefixLength
        maximumLength = stock.maximumLength
    }
}

extension Notification.Name {
    /// Posted when the word lists have been rebuilt, so the running scorer can
    /// pick them up without a restart.
    static let wmpWordListsRebuilt = Notification.Name("wmpWordListsRebuilt")
}

/// Whether the thing is actually watching the keyboard right now.
///
/// Worth showing plainly: the settings window looks identical whether the tap
/// is live or not, and "why is nothing being corrected" is otherwise invisible.
final class RuntimeStatus: ObservableObject {
    enum State {
        case running
        case buildingWordLists
        case previewOnly
        case needsPermission
        case noLayouts
        case tapFailed

        var isLive: Bool { self == .running }

        var title: String {
            switch self {
            case .running: "กำลังทำงาน"
            case .buildingWordLists: "กำลังสร้างคลังคำ"
            case .previewOnly: "โหมดดู UI เท่านั้น"
            case .needsPermission: "ยังไม่ได้สิทธิ์ Accessibility"
            case .noLayouts: "ไม่เจอเลย์เอาต์ไทยหรืออังกฤษ"
            case .tapFailed: "ติดตั้งตัวดักคีย์บอร์ดไม่สำเร็จ"
            }
        }

        var detail: String {
            switch self {
            case .running: "แก้การพิมพ์ให้อยู่ทุกแอป"
            case .buildingWordLists: "อ่านดิกชันนารีกับข้อความในเครื่องนี้ ครั้งเดียวตอนติดตั้ง ใช้เวลาราวครึ่งนาที"
            case .previewOnly: "รันด้วย --preview อยู่ ยังไม่ได้ดักคีย์บอร์ด ให้เปิดแอปจริงถึงจะแก้ให้"
            case .needsPermission: "เปิดสิทธิ์ให้ wmp-ไทย ใน Privacy & Security > Accessibility แล้วมันจะเริ่มทำงานเองทันที ไม่ต้องเปิดแอปใหม่"
            case .noLayouts: "เพิ่ม Thai และ ABC ใน Keyboard > Input Sources"
            case .tapFailed: "ลองเปิดแอปใหม่อีกครั้ง"
            }
        }

        var symbol: String {
            switch self {
            case .running: "checkmark.circle.fill"
            case .buildingWordLists: "clock"
            case .previewOnly: "eye"
            default: "exclamationmark.triangle.fill"
            }
        }
    }

    @Published var state: State = .previewOnly
}

/// The last few fixes, shown live in the settings window and the menu.
final class FixLog: ObservableObject {
    struct Entry: Identifiable {
        let id = UUID()
        let original: String
        let replacement: String
        let midWord: Bool
    }

    @Published private(set) var entries: [Entry] = []

    func record(_ correction: Correction, midWord: Bool) {
        entries.insert(Entry(original: correction.original, replacement: correction.replacement, midWord: midWord), at: 0)
        entries = Array(entries.prefix(20))
    }

    func clear() { entries = [] }
}
