public import CoreAudio
import Foundation

public enum OutputDeviceError: Error, Equatable, Sendable { case coreAudio(Int32) }

/// Thin CoreAudio HAL wrapper for the system default output device.
public struct OutputDevice: Sendable, Equatable {
    public let id: AudioObjectID

    private static func address(_ selector: AudioObjectPropertySelector,
                                _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }

    public static func defaultOutput() -> OutputDevice? {
        var id = AudioObjectID(0)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        var addr = address(kAudioHardwarePropertyDefaultOutputDevice)
        let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &id)
        return status == noErr && id != 0 ? OutputDevice(id: id) : nil
    }

    public var name: String {
        var name: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        var addr = Self.address(kAudioObjectPropertyName)
        guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &name) == noErr, let value = name?.takeRetainedValue() else { return "" }
        return value as String
    }

    public var nominalSampleRate: Double {
        var rate = Float64(0)
        var size = UInt32(MemoryLayout<Float64>.size)
        var addr = Self.address(kAudioDevicePropertyNominalSampleRate)
        AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &rate)
        return rate
    }

    public var availableSampleRates: [Double] {
        var addr = Self.address(kAudioDevicePropertyAvailableNominalSampleRates)
        var size = UInt32(0)
        guard AudioObjectGetPropertyDataSize(id, &addr, 0, nil, &size) == noErr, size > 0 else { return [] }
        var ranges = [AudioValueRange](repeating: AudioValueRange(), count: Int(size) / MemoryLayout<AudioValueRange>.size)
        guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &ranges) == noErr else { return [] }
        return Array(Set(ranges.flatMap { [$0.mMinimum, $0.mMaximum] })).sorted()
    }

    public func setNominalSampleRate(_ rate: Double) throws {
        var value = Float64(rate)
        var addr = Self.address(kAudioDevicePropertyNominalSampleRate)
        let status = AudioObjectSetPropertyData(id, &addr, 0, nil, UInt32(MemoryLayout<Float64>.size), &value)
        guard status == noErr else { throw OutputDeviceError.coreAudio(status) }
    }

    public func bestRate(for source: Double) -> Double { Self.bestRate(for: source, among: availableSampleRates) }

    /// Exact match → bit-perfect. Otherwise the highest rate that divides the source evenly (cleanest
    /// resample, e.g. 176.4 → 88.2), otherwise the highest rate available.
    public static func bestRate(for source: Double, among rates: [Double]) -> Double {
        guard !rates.isEmpty else { return source }
        if rates.contains(source) { return source }
        if let divisor = rates.filter({ source.truncatingRemainder(dividingBy: $0) == 0 }).max() { return divisor }
        if let multiple = rates.filter({ $0.truncatingRemainder(dividingBy: source) == 0 }).min() { return multiple }
        return rates.max()!
    }
}
