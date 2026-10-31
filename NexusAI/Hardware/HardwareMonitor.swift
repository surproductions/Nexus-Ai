import Foundation
import UIKit
import Metal
import os

enum HardwareTier: String, Codable, CaseIterable, Sendable {
    case low = "Low resource"
    case balanced = "Balanced"
    case high = "High performance"

    var detail: String {
        switch self {
        case .low: return "Lightweight models, 2K context, minimal background work."
        case .balanced: return "3–4B models, 4K context, thinking and tools."
        case .high: return "Largest compatible models, 8K+ context, multi-agent Max mode."
        }
    }
}

struct DeviceInfo: Sendable {
    var identifier: String
    var marketingName: String
    var chip: String
    var physicalMemory: UInt64
    var cpuCores: Int
    var performanceCores: Int
    var gpuName: String
    var gpuFamily: String
    var gpuRecommendedWorkingSet: UInt64
    var osVersion: String
}

/// Memory, thermal, battery and storage telemetry used for model admission and adaptive behaviour.
/// All measurements stay on device.
@MainActor
final class HardwareMonitor: ObservableObject {
    static let shared = HardwareMonitor()

    let device: DeviceInfo
    @Published private(set) var availableMemory: UInt64 = 0
    @Published private(set) var appFootprint: UInt64 = 0
    @Published private(set) var thermalState: ProcessInfo.ThermalState = .nominal
    @Published private(set) var batteryLevel: Float = -1
    @Published private(set) var batteryState: UIDevice.BatteryState = .unknown
    @Published private(set) var lowPowerMode = false
    @Published private(set) var freeStorage: Int64 = 0
    @Published private(set) var memoryWarnings = 0

    private var timer: Timer?
    private var pressureSource: DispatchSourceMemoryPressure?

    private init() {
        device = Self.detectDevice()
        UIDevice.current.isBatteryMonitoringEnabled = true
        refresh()
        NotificationCenter.default.addObserver(forName: ProcessInfo.thermalStateDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        NotificationCenter.default.addObserver(forName: .NSProcessInfoPowerStateDidChange, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        NotificationCenter.default.addObserver(forName: UIApplication.didReceiveMemoryWarningNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                self?.memoryWarnings += 1
                NotificationCenter.default.post(name: .nexusMemoryPressure, object: nil)
            }
        }
        let source = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical], queue: .main)
        source.setEventHandler {
            NotificationCenter.default.post(name: .nexusMemoryPressure, object: nil)
        }
        source.resume()
        pressureSource = source
    }

    /// Start periodic sampling (only while dashboards are visible or inference is running — saves battery when idle).
    func startSampling(interval: TimeInterval = 1.0) {
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    func stopSampling() {
        timer?.invalidate()
        timer = nil
    }

    func refresh() {
        availableMemory = UInt64(os_proc_available_memory())
        appFootprint = Self.currentFootprint()
        thermalState = ProcessInfo.processInfo.thermalState
        batteryLevel = UIDevice.current.batteryLevel
        batteryState = UIDevice.current.batteryState
        lowPowerMode = ProcessInfo.processInfo.isLowPowerModeEnabled
        if let values = try? URL(fileURLWithPath: NSHomeDirectory()).resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]),
           let cap = values.volumeAvailableCapacityForImportantUsage {
            freeStorage = cap
        }
    }

    /// The memory the app could use in total right now: what it already holds plus what iOS will still grant.
    var memoryBudget: UInt64 { availableMemory + appFootprint }

    var tier: HardwareTier {
        let gb = Double(device.physicalMemory) / 1_073_741_824
        var tier: HardwareTier = gb >= 7.5 ? .high : (gb >= 5.5 ? .balanced : .low)
        if thermalState == .serious || thermalState == .critical || lowPowerMode {
            tier = tier == .high ? .balanced : .low
        }
        return tier
    }

    var thermalLabel: String {
        switch thermalState {
        case .nominal: return "Nominal"
        case .fair: return "Fair"
        case .serious: return "Serious"
        case .critical: return "Critical"
        @unknown default: return "Unknown"
        }
    }

    /// Context length suggested for a tier and mode.
    func suggestedContext(for mode: IntelligenceMode) -> Int {
        switch (tier, mode) {
        case (.low, _): return 2048
        case (.balanced, .instant): return 3072
        case (.balanced, _): return 4096
        case (.high, .instant): return 4096
        case (.high, .thinking): return 8192
        case (.high, .max): return 16384
        }
    }

    /// Admission control: refuses any load that would likely exceed the app's memory limit.
    /// `currentlyLoaded` is the footprint that will be freed if the active model is unloaded first.
    func canLoad(_ entry: ModelEntry, context: Int, vision: Bool, reclaimable: UInt64) -> (ok: Bool, required: UInt64, available: UInt64) {
        refresh()
        let required = entry.estimatedMemory(context: context, withVision: vision)
        let available = availableMemory + reclaimable
        let safety: Double = thermalState == .critical ? 0.6 : 0.82
        return (Double(required) < Double(available) * safety, required, available)
    }

    /// Largest context that fits for a model (halving down to 1024).
    func fittingContext(for entry: ModelEntry, preferred: Int, vision: Bool, reclaimable: UInt64) -> Int? {
        var ctx = min(preferred, entry.nativeContext)
        while ctx >= 1024 {
            if canLoad(entry, context: ctx, vision: vision, reclaimable: reclaimable).ok { return ctx }
            ctx /= 2
        }
        return nil
    }

    nonisolated static func currentFootprint() -> UInt64 {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return kr == KERN_SUCCESS ? UInt64(info.phys_footprint) : 0
    }

    private static func sysctlInt(_ name: String) -> Int {
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        return sysctlbyname(name, &value, &size, nil, 0) == 0 ? Int(value) : 0
    }

    private static func detectDevice() -> DeviceInfo {
        var sys = utsname()
        uname(&sys)
        let identifier = withUnsafeBytes(of: &sys.machine) { raw -> String in
            let bytes = raw.prefix { $0 != 0 }
            return String(decoding: bytes, as: UTF8.self)
        }
        let (name, chip) = lookup(identifier)
        let mtl = MTLCreateSystemDefaultDevice()
        var family = "Apple GPU"
        if let mtl {
            if mtl.supportsFamily(.apple9) { family = "Apple 9 (A17 Pro / A18 or newer)" }
            else if mtl.supportsFamily(.apple8) { family = "Apple 8 (A15 / A16)" }
            else if mtl.supportsFamily(.apple7) { family = "Apple 7 (A14)" }
            else { family = "Apple 6 or earlier" }
        }
        let perf = sysctlInt("hw.perflevel0.physicalcpu")
        return DeviceInfo(identifier: identifier, marketingName: name, chip: chip,
                          physicalMemory: ProcessInfo.processInfo.physicalMemory,
                          cpuCores: ProcessInfo.processInfo.processorCount,
                          performanceCores: perf > 0 ? perf : 2,
                          gpuName: mtl?.name ?? "Unknown", gpuFamily: family,
                          gpuRecommendedWorkingSet: mtl?.recommendedMaxWorkingSetSize ?? 0,
                          osVersion: UIDevice.current.systemVersion)
    }

    private static func lookup(_ id: String) -> (String, String) {
        let table: [String: (String, String)] = [
            "iPhone14,2": ("iPhone 13 Pro", "A15 Bionic"), "iPhone14,3": ("iPhone 13 Pro Max", "A15 Bionic"),
            "iPhone14,4": ("iPhone 13 mini", "A15 Bionic"), "iPhone14,5": ("iPhone 13", "A15 Bionic"),
            "iPhone14,6": ("iPhone SE (3rd gen)", "A15 Bionic"), "iPhone14,7": ("iPhone 14", "A15 Bionic"),
            "iPhone14,8": ("iPhone 14 Plus", "A15 Bionic"), "iPhone15,2": ("iPhone 14 Pro", "A16 Bionic"),
            "iPhone15,3": ("iPhone 14 Pro Max", "A16 Bionic"), "iPhone15,4": ("iPhone 15", "A16 Bionic"),
            "iPhone15,5": ("iPhone 15 Plus", "A16 Bionic"), "iPhone16,1": ("iPhone 15 Pro", "A17 Pro"),
            "iPhone16,2": ("iPhone 15 Pro Max", "A17 Pro"), "iPhone17,1": ("iPhone 16 Pro", "A18 Pro"),
            "iPhone17,2": ("iPhone 16 Pro Max", "A18 Pro"), "iPhone17,3": ("iPhone 16", "A18"),
            "iPhone17,4": ("iPhone 16 Plus", "A18"), "iPhone17,5": ("iPhone 16e", "A18"),
            "iPhone18,1": ("iPhone 17 Pro", "A19 Pro"), "iPhone18,2": ("iPhone 17 Pro Max", "A19 Pro"),
            "iPhone18,3": ("iPhone 17", "A19"), "iPhone18,4": ("iPhone Air", "A19 Pro"),
        ]
        if let hit = table[id] { return hit }
        if id.hasPrefix("iPad") { return ("iPad (\(id))", "Apple silicon") }
        return (id, "Apple silicon")
    }
}

extension Notification.Name {
    static let nexusMemoryPressure = Notification.Name("nexus.memory.pressure")
}
