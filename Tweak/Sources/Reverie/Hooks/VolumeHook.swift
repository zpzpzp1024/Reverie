import ObjectiveC

struct VolumeHook: Hook {
    typealias T = @convention(c) (AnyObject, Selector, Any?) -> Void
    
    // Five presses while Reverie considers the device asleep: the first few are
    // swallowed by the wake transition, so the counter only fires after the
    // fifth. Volume down is used because it is the least likely to be pressed by
    // accident while the phone sits in a mount.
    let cls: AnyClass? = objc_lookUpClass("SBVolumeHardwareButton")
    let sel: Selector = sel_registerName("volumeDecreasePress:")
    let replace: T = { obj, sel, a0 in
        if Reverie.isSleeping {
            if Reverie.wakePress > 3 {
                Reverie.wakePress = 0
                Reverie.wake(reason: .userWoken)
            } else {
                Reverie.wakePress += 1
            }
        } else {
            Reverie.wakePress = 0
        }
        
        orig(obj, sel, a0)
    }
}
