// Whether the Mac is in a call: a microphone in use, by any app.
import CoreAudio
import Foundation

/// Says when the default microphone starts and stops being used by any app (a call, a recording). CoreAudio tells this
/// without access to the microphone itself, so no permission is asked.
/// Limit: the default input only; a call on another microphone (a headset not made the default) isn't seen.
@MainActor
final class CallWatch {
    var onChange: ((Bool) -> Void)?
    private(set) var inCall = false
    private var device = AudioObjectID(kAudioObjectUnknown)
    private var running = address(kAudioDevicePropertyDeviceIsRunningSomewhere)
    private var defaultInput = address(kAudioHardwarePropertyDefaultInputDevice)
    private lazy var runningChanged: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
        MainActor.assumeIsolated { self?.read() }   // CoreAudio calls it on the main queue it was handed
    }
    private lazy var deviceChanged: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
        MainActor.assumeIsolated { self?.follow() }   // CoreAudio calls it on the main queue it was handed
    }

    func start() {
        AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject), &defaultInput, .main, deviceChanged)
        follow()
    }

    /// Onto the default input, which a headset plugged in changes.
    private func follow() {
        if device != kAudioObjectUnknown {
            AudioObjectRemovePropertyListenerBlock(device, &running, .main, runningChanged)
        }
        var found = AudioObjectID(kAudioObjectUnknown), size = UInt32(MemoryLayout<AudioObjectID>.size)
        AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &defaultInput, 0, nil, &size, &found)
        device = found
        if device != kAudioObjectUnknown {
            AudioObjectAddPropertyListenerBlock(device, &running, .main, runningChanged)
        }
        read()
    }

    private func read() {
        var on = UInt32(0), size = UInt32(MemoryLayout<UInt32>.size)
        let read =
            device != kAudioObjectUnknown && AudioObjectGetPropertyData(device, &running, 0, nil, &size, &on) == noErr
        let now = read && on != 0
        guard now != inCall else { return }
        inCall = now
        onChange?(now)
    }

    private static func address(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    }
}
