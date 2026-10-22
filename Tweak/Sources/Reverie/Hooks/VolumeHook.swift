import ObjectiveC

struct VolumeHook: Hook {
    typealias T = @convention(c) (AnyObject, Selector, Any?) -> Void
    
    let cls: AnyClass? = objc_lookUpClass("SBVolumeHardwareButton")
    let sel: Selector = sel_registerName("volumeIncreasePress:")
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
