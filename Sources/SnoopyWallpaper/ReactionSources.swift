import AppKit
import CoreAudio
import EventKit
import SnoopyTVCore

/// The real-world events behind the tvOS reaction triggers (docs/REACTION_POSES.md §5),
/// mapped to what a Mac can observe:
///
/// | Trigger       | Source on the Mac                                        | Permission |
/// |---------------|----------------------------------------------------------|------------|
/// | `music`       | another process has been outputting audio for 8 s        | none       |
/// | `presence`    | the screen was unlocked, or the Mac woke from sleep      | none       |
/// | `environment` | the weather conditions changed (dawn and dusk included)  | none       |
/// | `alarm`       | a calendar event starts                                  | Calendars  |
/// | `doorbell`    | a download finished in ~/Downloads                       | Downloads  |
///
/// Each source is on or off in `SnoopyPreferences.reactionSourceEnabled`;
/// the coordinator starts and stops them to match, and fires each trigger at
/// most once every three minutes.
@MainActor
final class ReactionSourceCoordinator {
    static let triggers = [
        ReactionTrigger.music, ReactionTrigger.presence, ReactionTrigger.environment,
        ReactionTrigger.alarm, ReactionTrigger.doorbell,
    ]
    private static let minimumInterval: TimeInterval = 180

    private let fire: (String) -> Void
    private var sources: [String: ReactionSource] = [:]
    private var lastFired: [String: TimeInterval] = [:]

    init(fire: @escaping (String) -> Void) {
        self.fire = fire
    }

    func start() { reconfigure() }

    func stop() {
        for source in sources.values { source.stop() }
        sources.removeAll()
    }

    /// Start or stop sources so the running set matches the preferences.
    func reconfigure() {
        for trigger in Self.triggers {
            let wanted = SnoopyPreferences.reactionSourceEnabled(trigger)
            if wanted, sources[trigger] == nil {
                let source = makeSource(for: trigger)
                sources[trigger] = source
                source.start()
                NSLog("SnoopyWallpaper: reaction source %@ started", trigger)
            } else if !wanted, let source = sources[trigger] {
                source.stop()
                sources[trigger] = nil
                NSLog("SnoopyWallpaper: reaction source %@ stopped", trigger)
            }
        }
    }

    private func makeSource(for trigger: String) -> ReactionSource {
        let report: (String) -> Void = { [weak self] detail in
            DispatchQueue.main.async { self?.report(trigger, detail) }
        }
        switch trigger {
        case ReactionTrigger.music: return AudioOutputSource(onEvent: report)
        case ReactionTrigger.presence: return PresenceSource(onEvent: report)
        case ReactionTrigger.environment: return WeatherChangeSource(onEvent: report)
        case ReactionTrigger.alarm: return CalendarEventSource(onEvent: report)
        default: return DownloadsSource(onEvent: report)
        }
    }

    private func report(_ trigger: String, _ detail: String) {
        let now = ProcessInfo.processInfo.systemUptime
        if let last = lastFired[trigger], now - last < Self.minimumInterval {
            NSLog("SnoopyWallpaper: reaction source %@: %@ (suppressed, %.0fs since the last one)", trigger, detail, now - last)
            return
        }
        lastFired[trigger] = now
        NSLog("SnoopyWallpaper: reaction source %@: %@", trigger, detail)
        fire(trigger)
    }
}

protocol ReactionSource: AnyObject {
    func start()
    func stop()
}

// MARK: - music: another process is outputting audio

/// Polls CoreAudio's process objects every two seconds: `music` fires once
/// another process has been running audio output for eight seconds, and
/// re-arms after ninety seconds of silence. This app's own players never
/// count (the scene videos carry no audio anyway).
final class AudioOutputSource: ReactionSource {
    private let onEvent: (String) -> Void
    private var timer: DispatchSourceTimer?
    private var runningSince: TimeInterval?
    private var quietSince: TimeInterval?
    private var announced = false

    init(onEvent: @escaping (String) -> Void) { self.onEvent = onEvent }

    func start() {
        guard timer == nil else { return }
        let source = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        source.schedule(deadline: .now() + 2, repeating: 2)
        source.setEventHandler { [weak self] in self?.poll() }
        source.resume()
        timer = source
    }

    func stop() {
        timer?.cancel()
        timer = nil
    }

    private func poll() {
        let now = ProcessInfo.processInfo.systemUptime
        if Self.anotherProcessIsOutputtingAudio() {
            quietSince = nil
            if runningSince == nil { runningSince = now }
            if !announced, let since = runningSince, now - since >= 8 {
                announced = true
                onEvent("audio has been playing for 8 s")
            }
        } else {
            runningSince = nil
            if quietSince == nil { quietSince = now }
            if announced, let since = quietSince, now - since >= 90 { announced = false }
        }
    }

    private static func anotherProcessIsOutputtingAudio() -> Bool {
        let own = pid_t(ProcessInfo.processInfo.processIdentifier)
        if #available(macOS 14.2, *) {
            var address = AudioObjectPropertyAddress(
                mSelector: kAudioHardwarePropertyProcessObjectList,
                mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain
            )
            let system = AudioObjectID(kAudioObjectSystemObject)
            var size: UInt32 = 0
            guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr, size > 0 else { return false }
            var objects = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
            guard AudioObjectGetPropertyData(system, &address, 0, nil, &size, &objects) == noErr else { return false }
            for object in objects {
                var pidAddress = AudioObjectPropertyAddress(
                    mSelector: kAudioProcessPropertyPID,
                    mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain
                )
                var pid: pid_t = 0
                var pidSize = UInt32(MemoryLayout<pid_t>.size)
                guard AudioObjectGetPropertyData(object, &pidAddress, 0, nil, &pidSize, &pid) == noErr,
                      pid != own else { continue }
                var runningAddress = AudioObjectPropertyAddress(
                    mSelector: kAudioProcessPropertyIsRunningOutput,
                    mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain
                )
                var running: UInt32 = 0
                var runningSize = UInt32(MemoryLayout<UInt32>.size)
                if AudioObjectGetPropertyData(object, &runningAddress, 0, nil, &runningSize, &running) == noErr,
                   running != 0 {
                    return true
                }
            }
            return false
        }
        // Before 14.2: the default output device is running for somebody.
        var deviceAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain
        )
        var device = AudioObjectID(kAudioObjectUnknown)
        var deviceSize = UInt32(MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &deviceAddress, 0, nil, &deviceSize, &device) == noErr,
              device != kAudioObjectUnknown else { return false }
        var runningAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceIsRunningSomewhere,
            mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain
        )
        var running: UInt32 = 0
        var runningSize = UInt32(MemoryLayout<UInt32>.size)
        return AudioObjectGetPropertyData(device, &runningAddress, 0, nil, &runningSize, &running) == noErr && running != 0
    }
}

// MARK: - presence: you are back

/// `presence` fires when the screen is unlocked or the Mac wakes from sleep.
final class PresenceSource: ReactionSource {
    private let onEvent: (String) -> Void
    private var tokens: [(NotificationCenter, NSObjectProtocol)] = []

    init(onEvent: @escaping (String) -> Void) { self.onEvent = onEvent }

    func start() {
        guard tokens.isEmpty else { return }
        let distributed = DistributedNotificationCenter.default()
        tokens.append((distributed, distributed.addObserver(
            forName: Notification.Name("com.apple.screenIsUnlocked"), object: nil, queue: .main
        ) { [weak self] _ in self?.onEvent("screen unlocked") }))
        let workspace = NSWorkspace.shared.notificationCenter
        tokens.append((workspace, workspace.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in self?.onEvent("woke from sleep") }))
        tokens.append((workspace, workspace.addObserver(
            forName: NSWorkspace.sessionDidBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in self?.onEvent("session became active") }))
    }

    func stop() {
        for (center, token) in tokens { center.removeObserver(token) }
        tokens.removeAll()
    }
}

// MARK: - environment: the weather changed

/// `environment` fires when a new weather snapshot carries different
/// conditions than the previous one (sunrise and sunset included: `sunny`
/// is only reported by day).
final class WeatherChangeSource: ReactionSource {
    private let onEvent: (String) -> Void
    private var token: NSObjectProtocol?
    private var lastConditions: [String]?

    init(onEvent: @escaping (String) -> Void) { self.onEvent = onEvent }

    func start() {
        guard token == nil else { return }
        lastConditions = SnoopyPreferences.weatherSnapshot()?.conditions
        token = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in self?.check() }
    }

    func stop() {
        if let token { NotificationCenter.default.removeObserver(token) }
        token = nil
    }

    private func check() {
        guard let snapshot = SnoopyPreferences.weatherSnapshot() else { return }
        defer { lastConditions = snapshot.conditions }
        guard let last = lastConditions, last != snapshot.conditions else { return }
        onEvent("weather changed from \(last.joined(separator: ",")) to \(snapshot.conditions.joined(separator: ","))")
    }
}

// MARK: - alarm: a calendar event starts

/// `alarm` fires when a timed calendar event begins (checked every 30 s,
/// events that start within ±45 s of now, each once). Needs full calendar
/// access; the request is made when the source starts.
final class CalendarEventSource: ReactionSource {
    private let onEvent: (String) -> Void
    private let store = EKEventStore()
    private var timer: Timer?
    private var announced: Set<String> = []

    init(onEvent: @escaping (String) -> Void) { self.onEvent = onEvent }

    static var accessDescription: String {
        switch EKEventStore.authorizationStatus(for: .event) {
        case .fullAccess: return "Calendar access allowed."
        case .denied, .restricted: return "Calendar access denied in System Settings › Privacy & Security › Calendars."
        case .writeOnly: return "Calendar access is write-only; full access is needed."
        default: return "Asks for calendar access when enabled."
        }
    }

    func start() {
        guard timer == nil else { return }
        switch EKEventStore.authorizationStatus(for: .event) {
        case .fullAccess:
            schedule()
        case .notDetermined:
            store.requestFullAccessToEvents { [weak self] granted, _ in
                DispatchQueue.main.async { if granted { self?.schedule() } }
            }
        default:
            NSLog("SnoopyWallpaper: reaction source alarm: no calendar access")
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func schedule() {
        guard timer == nil else { return }
        let timer = Timer(timeInterval: 30, repeats: true) { [weak self] _ in self?.poll() }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        poll()
    }

    private func poll() {
        let now = Date()
        let predicate = store.predicateForEvents(
            withStart: now.addingTimeInterval(-45), end: now.addingTimeInterval(45), calendars: nil
        )
        for event in store.events(matching: predicate) where !event.isAllDay {
            guard let start = event.startDate, abs(start.timeIntervalSince(now)) <= 45,
                  let identifier = event.eventIdentifier, !announced.contains(identifier) else { continue }
            announced.insert(identifier)
            onEvent("calendar event starts: \(event.title ?? "untitled")")
        }
    }
}

// MARK: - doorbell: a delivery

/// `doorbell` fires when a new, complete file appears in ~/Downloads (partial
/// downloads and hidden files are ignored). Opening the folder asks for
/// access to Downloads the first time.
final class DownloadsSource: ReactionSource {
    private let onEvent: (String) -> Void
    private var source: DispatchSourceFileSystemObject?
    private var known: Set<String> = []
    private static let partialSuffixes = ["download", "crdownload", "part", "partial", "tmp"]

    init(onEvent: @escaping (String) -> Void) { self.onEvent = onEvent }

    private var directory: URL {
        FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
    }

    func start() {
        guard source == nil else { return }
        known = Self.completeFiles(in: directory)
        let descriptor = open(directory.path, O_EVTONLY)
        guard descriptor >= 0 else {
            NSLog("SnoopyWallpaper: reaction source doorbell: cannot watch %@", directory.path)
            return
        }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor, eventMask: .write, queue: .main
        )
        source.setEventHandler { [weak self] in self?.check() }
        source.setCancelHandler { close(descriptor) }
        source.resume()
        self.source = source
    }

    func stop() {
        source?.cancel()
        source = nil
    }

    private func check() {
        let current = Self.completeFiles(in: directory)
        let arrived = current.subtracting(known)
        known = current
        if let name = arrived.sorted().first {
            onEvent("download finished: \(name)")
        }
    }

    private static func completeFiles(in directory: URL) -> Set<String> {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        return Set(names.filter { name in
            guard !name.hasPrefix(".") else { return false }
            let suffix = (name as NSString).pathExtension.lowercased()
            return !partialSuffixes.contains(suffix)
        })
    }
}
