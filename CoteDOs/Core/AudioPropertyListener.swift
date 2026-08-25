import CoreAudio
import Foundation

/// A CoreAudio property listener that can actually be removed again.
///
/// The block-based pair (`AudioObjectAddPropertyListenerBlock` /
/// `…Remove…`) looks symmetric from Swift and is not: a Swift closure is bridged
/// to a *new* Objective-C block at every call boundary, so the block handed to
/// the remove call is never the one CoreAudio registered. Removal returns
/// `noErr` and leaves the listener in place. Measured 25.08.2026: every default
/// output device change left another live volume listener behind, and after
/// four days of uptime a single volume key press ran hundreds of listener
/// callbacks — each doing blocking CoreAudio IPC on the main thread — which
/// froze the notch (and the media-key tap with it) for ~100 ms per press.
///
/// The C-function API compares proc + context pointer, so it removes reliably.
/// `onChange` is always delivered on the main queue.
final class AudioPropertyListener {
    private let object: AudioObjectID
    private var address: AudioObjectPropertyAddress
    private let onChange: () -> Void
    private var registered = false

    init(object: AudioObjectID, address: AudioObjectPropertyAddress, onChange: @escaping () -> Void) {
        self.object = object
        self.address = address
        self.onChange = onChange
    }

    deinit { stop() }

    /// Registers the listener; returns whether the property exists and took it.
    @discardableResult
    func start() -> Bool {
        guard !registered, AudioObjectHasProperty(object, &address) else { return registered }
        guard AudioObjectAddPropertyListener(object, &address, Self.proc, Unmanaged.passUnretained(self).toOpaque()) == noErr else {
            return false
        }
        registered = true
        return true
    }

    func stop() {
        guard registered else { return }
        AudioObjectRemovePropertyListener(object, &address, Self.proc, Unmanaged.passUnretained(self).toOpaque())
        registered = false
    }

    /// Called on an arbitrary CoreAudio thread; hops to main like the block API did.
    private static let proc: AudioObjectPropertyListenerProc = { _, _, _, context in
        guard let context else { return noErr }
        let listener = Unmanaged<AudioPropertyListener>.fromOpaque(context).takeUnretainedValue()
        DispatchQueue.main.async { [weak listener] in listener?.onChange() }
        return noErr
    }
}
