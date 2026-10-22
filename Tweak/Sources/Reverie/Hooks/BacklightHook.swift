import ObjectiveC

struct BacklightHook: Hook {
    typealias T = @convention(c) (AnyObject, Selector, UInt64) -> Void
    
    let cls: AnyClass? = objc_lookUpClass("SBBacklightController")
    let sel: Selector = sel_registerName("turnOnScreenFullyWithBacklightSource:")
    let replace: T = { obj, sel, source in
        guard !Reverie.isSleeping else {
            return
        }
        
        orig(obj, sel, source)
    }
}
