# Cockpit

CarPlay 分屏实验。目标：**左半屏一个真实 App（滴滴车主端），右半屏系统 CarPlay 界面**，两边都能触控。

当前是 **里程碑 1**：探针 + 宿主验证。还没有做真正的分屏。

## 它现在做什么

1. 每 3 秒检查一次是否连上了 CarPlay（通过 `AVExternalDevice` 找车机画面）
2. 连上后，在**车机屏**上创建一个属于 SpringBoard 的窗口（`UIRootSceneWindow`），左半屏画一块蓝色区域，用来证明能画、能收触摸
3. 把 `UIScreen`、`UIWindowScene`、窗口层级等信息写进日志，供下一步实现使用
4. 如果配置了 `HostBundleID`，尝试把那个 App 的 scene 挂进左半屏（`SBApplicationSceneHandle` + `SBAppViewController`）

这些私有 API 的用法参考了开源项目 [carplay-cast](https://github.com/EthanArbuckle/carplay-cast)（Apache-2.0）。

## 安装

从 Actions 的 `cockpit-deb` artifact 下载，然后：

```sh
scp lilliana.cockpit_*_iphoneos-arm64.deb root@<iphone-ip>:/var/mobile/
ssh root@<iphone-ip>
/var/jb/usr/bin/dpkg -i /var/mobile/lilliana.cockpit_*_iphoneos-arm64.deb
killall -9 SpringBoard
```

> 会注入 SpringBoard。如果出现无限重启，用 Dopamine 关闭 tweak 注入后重启，或删掉
> `/var/jb/Library/MobileSubstrate/DynamicLibraries/Cockpit.dylib`。

## 配置

配置文件：`/var/mobile/Library/Preferences/lilliana.cockpit.plist`

```xml
<dict>
    <key>Enabled</key>
    <true/>
    <key>SplitRatio</key>
    <real>0.5</real>
    <key>HostBundleID</key>
    <string>com.sdu.didi.gsui</string>
</dict>
```

改完 `killall -9 SpringBoard` 生效。

- `Enabled`：总开关，默认开
- `SplitRatio`：左半屏占比，0.25–0.75
- `HostBundleID`：要挂到左半屏的 App，留空就只显示探针色块

   也可以不用 plist，直接建一个纯文本文件，内容只写包名：

   ```
   /var/mobile/Library/Preferences/lilliana.cockpit.host
   ```

`HostBundleID` 不知道的话，用 Filza 找到那个 App 的 `.app` 目录，看里面 `Info.plist` 的 `CFBundleIdentifier`；或者在 SSH 里：

```sh
for p in /var/containers/Bundle/Application/*/*.app; do
  echo "$p $(/var/jb/usr/bin/plutil -extract CFBundleIdentifier raw "$p/Info.plist" 2>/dev/null)"
done | grep -i didi
```

## 没有车机怎么测（手机屏测试模式）

有两种开启方式，任选其一：

1. 建一个空文件（推荐，Filza 里「新建文件」即可）：

```
/var/mobile/Library/Preferences/lilliana.cockpit.test
```

2. 或者在 plist 里写 `<key>TestOnMainScreen</key><true/>`

车不在旁边时，CarPlay 相关的部分测不了（没有会话就找不到车机屏），但**宿主 App 那段最容易出错的代码可以测**。

重启 SpringBoard 后，不需要 CarPlay，手机上会直接在**屏幕左半边**出现蓝色探针区域：

- 屏幕左半边被一块半透明蓝色盖住 → 窗口创建、布局、渲染链路通了
- 再填宿主包名，那个 App 会被缩放进左半边 → scene 宿主链路通了，触摸也能操作它
- 右上角的 `✕` 用来关掉浮层（控件会挡住 SpringBoard，关掉后要重启 SpringBoard 才会再出现）
- 右半边的触摸会正常传给下面的 SpringBoard（测试窗口只占左半边）

这个模式**测不到**的东西：车机 `CADisplay` 的发现、`AVExternalDevice` 会话、车机屏上的窗口、以及右半屏系统 CarPlay 界面的缩放/触控穿透。这几项只能等车在旁边。

## 紧急关闭

创建空文件即可，下次 SpringBoard 启动时完全不加载逻辑：

```sh
touch /var/mobile/Library/Preferences/lilliana.cockpit.off
```

## 日志

`/var/mobile/Library/Logs/Cockpit.log`（256 KB 轮转），记录：

- `--- Cockpit 0.0.4 loaded ---`：tweak 被加载
- `probe: screens`：车机屏是否被识别，`car=1` / `carplay=1`
- `make window: ...`：窗口是否创建成功，frame 是多少
- `ui: no HostBundleID set, probe only`：没有配置宿主的 App
- `host: ...`：宿主 App 的每一步，失败会停在哪一步

## 路线图

| 里程碑 | 内容 | 状态 |
| --- | --- | --- |
| 1 | 车机屏上建窗口 + 宿主 App + 探针 | 进行中 |
| 2 | 把握住的 App 缩放到左半屏，右侧留出系统界面 | 待做 |
| 3 | 系统 CarPlay 窗口缩放/裁切到右半屏，触控穿透 | 待做 |
| 4 | 布局设置、启用开关、开机自动恢复 | 待做 |

里程碑 1 的日志能告诉我们 iOS 16.3 上哪些类还在、窗口怎么挂，后面几步全部依赖这些结论。
