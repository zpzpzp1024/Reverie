import Preferences

final class RootListController: PSListController {
    private var ruleSpecifierIDs: [String] {
        ["wakeOnCharge", "sleepOnUnplug", "休眠规则", "sleepOnlyWhenLocked", "sleepWithCarPlay"]
    }
    
    private var ruleCells: [JinxCell] {
        [
            ToggleCell(name: "接上电源时唤醒", key: "wakeOnCharge", defaultValue: true),
            ToggleCell(name: "拔掉电源时休眠", key: "sleepOnUnplug", defaultValue: true),
            GroupCell(
                name: "休眠规则",
                footerText: "Reverie 只在设备闲置时进入休眠。休眠会关闭 Wi-Fi 与蓝牙，要保住 CarPlay 会话就不要打开下面的选项。"
            ),
            ToggleCell(name: "仅在锁屏时休眠", key: "sleepOnlyWhenLocked", defaultValue: true),
            ToggleCell(name: "使用 CarPlay 时也休眠", key: "sleepWithCarPlay", defaultValue: false)
        ]
    }
    
    override var specifiers: NSMutableArray? {
        get {
            if let specifiers = value(forKey: "_specifiers") as? NSMutableArray {
                return specifiers
            }
            
            var specifiers: NSMutableArray = .init()
            
            SpecifierFactory.add([
                GroupCell(
                    name: "通用",
                    footerText: "接上电源自动退出休眠，拔掉电源后自动休眠。适用于长期放在车里的设备。"
                ),
                ToggleCell(name: "启用", key: "isEnabled", defaultValue: true)
            ], to: &specifiers, in: self)
            
            if PrefsHelper.getValue(for: "isEnabled", fallback: true) as? Bool == true {
                SpecifierFactory.add(ruleCells, to: &specifiers, in: self)
            }
            
            SpecifierFactory.add([
                GroupCell(name: "操作", footerText: ""),
                ButtonCell(name: "立即休眠", action: #selector(Self.sleepDart))
            ], to: &specifiers, in: self)
            
            setValue(specifiers, forKey: "_specifiers")
            return specifiers
        }
        
        set { super.specifiers = newValue }
    }
    
    override func viewDidLoad() {
        super.viewDidLoad()
        
        Metadata.developer = "Paisseon"
        Metadata.package = "lilliana.reverie"
        Metadata.tweakName = "Reverie"
        
        navigationItem.rightBarButtonItem = UIBarButtonItem(
            title: "应用",
            style: .done,
            target: self,
            action: #selector(respring)
        )
        
        table.tableHeaderView = HeaderView(style: .default, reuseIdentifier: "HeaderCell")
    }
    
    override func setPreferenceValue(_ value: Any, specifier: PSSpecifier) {
        super.setPreferenceValue(value, specifier: specifier)
        
        guard specifier.identifier == "isEnabled" else {
            return
        }
        
        if value as? Bool == true {
            var newSpecifiers: NSMutableArray = .init()
            
            SpecifierFactory.add(ruleCells, to: &newSpecifiers, in: self)
            
            self.insertContiguousSpecifiers(newSpecifiers as? [Any], afterSpecifierID: "isEnabled", animated: true)
        } else {
            let hiddenIDs: [Any] = self.specifiers(forIDs: ruleSpecifierIDs)
            self.removeContiguousSpecifiers(hiddenIDs, animated: true)
        }
        
        table.tableHeaderView = HeaderView(style: .default, reuseIdentifier: nil)
    }
    
    @objc private func respring() {
        PrefsHelper.write()
        PrefsHelper.respring(withView: view)
    }
    
    @objc private func sleepDart() {
        CFNotificationCenterPostNotification(
            CFNotificationCenterGetDarwinNotifyCenter(),
            CFNotificationName("lilliana.reverie.external" as CFString),
            nil,
            nil,
            true
        )
    }
}
