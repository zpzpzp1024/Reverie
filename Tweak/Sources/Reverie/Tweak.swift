import UIKit

struct Tweak {
    static func ctor() {
        guard Preferences.isEnabled else {
            return
        }
        
        BacklightHook().hook()
        VolumeHook().hook()
        
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            Coordinator.start()
            
            IPC.shared.observe("lilliana.reverie.external") { _ in
                DispatchQueue.main.async {
                    if Reverie.isSleeping {
                        Reverie.wake(reason: .userWoken)
                    } else {
                        Reverie.sleep(reason: .userSlept)
                    }
                }
            }
        }
    }
}

@_cdecl("jinx_entry")
func jinxEntry() {
    Tweak.ctor()
}
