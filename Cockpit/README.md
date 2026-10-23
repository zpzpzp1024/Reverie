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

## SSH 部署（推荐）

手机装一次 OpenSSH，之后每次迭代就是一条命令，不用再来回传包、翻 Filza。

**一次性准备：**

1. Sileo 里搜 `openssh` 安装（Procursus 源的 openssh，装完 sshd 就在 22 端口）
2. 查手机 IP：设置 → Wi-Fi → 点右边 `(i)` → IP 地址
3. 电脑上：

```powershell
ssh root@<手机IP>        # 默认密码 alpine
passwd                   # 进去后先把密码改掉
```

4. 配免密（强烈建议，否则脚本每次 ssh/scp 都会要密码）：

```powershell
ssh-keygen -t ed25519     # 已有 key 就跳过
type $env:USERPROFILE\.ssh\id_ed25519.pub | ssh root@<手机IP> "mkdir -p /var/root/.ssh; cat >> /var/root/.ssh/authorized_keys; chmod 700 /var/root/.ssh; chmod 600 /var/root/.ssh/authorized_keys"
```

**日常用法：**

```powershell
# 装最新一版（CI 每次构建都会更新 cockpit-latest 这个 release）
# 也可以先设一次 $env:COCKPIT_DEVICE="192.168.1.23"，之后省略 -Device
.\Cockpit\deploy.ps1 -Device 192.168.1.23 -Latest

# 装本地某个包
.\Cockpit\deploy.ps1 -Device 192.168.1.23 -Deb .\Cockpit\packages\lilliana.cockpit_0.0.4_iphoneos-arm64.deb

# 只看日志（不装包）
.\Cockpit\deploy.ps1 -Device 192.168.1.23 -LogOnly -Tail 120

# 实时跟日志
.\Cockpit\deploy.ps1 -Device 192.168.1.23 -LogOnly -Follow

# 装完不 respring（只换文件）
.\Cockpit\deploy.ps1 -Device 192.168.1.23 -Latest -NoRespring

# 顺手把日志存到本地
.\Cockpit\deploy.ps1 -Device 192.168.1.23 -LogOnly -SaveLog .\cockpit.log
```

脚本做的事：确认能连上 → `scp` 到 `/var/mobile/cockpit.deb` → `dpkg -i` → 确认 dylib 落地 → `killall -9 SpringBoard` → 等 8 秒 → 打印 `/var/mobile/Library/Logs/Cockpit.log`。

**连不上时：**

- 手机和电脑必须同一 Wi-Fi，路由器别开 AP 隔离
- IP 变了（重连 Wi-Fi 常见），重新查一下
- 确认 sshd 在跑：`ssh root@<IP> "launchctl list | grep -i ssh"`
- 手机锁屏不影响 sshd，但省电模式可能断 Wi-Fi

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

如果托管时 SpringBoard 真的崩了，崩溃处理器会留下标记：

```
/var/mobile/Library/Preferences/lilliana.cockpit.crashed
```

下次启动看到它只显示蓝色探针、**不托管 App**，并自动删掉标记；再 respring 一次就会重新尝试托管。正常的 respring 不会写这个文件，所以不会误跳过。想立刻恢复托管，删掉它再 respring。

想让 App 用一个**独立的场景**而不是系统默认场景（避免和桌面上的同一个 App 抢），建这个文件再 respring：

```
/var/mobile/Library/Preferences/lilliana.cockpit.newscene
```

日志里会打 `host: newSceneIdentityForApplication: = ...`。iOS 16.3 上对不支持多窗口的 App（包括设置）它会直接返回默认场景 `-default`，也就是**没效果**。

## 场景断言过滤

SpringBoard 的场景控制器在「它认为场景应该在前台，但场景自己变成了后台」时会抛：

```
NSInternalInconsistencyException: Something changed the scene's (...) foreground status out from underneath us (current mode: Live)
```

把 App 挂进手机屏上的普通窗口一定会踩到它，然后整个 SpringBoard 被打死。0.0.10 起用 `NSException -raise` 钩子**只吞掉这一条**，日志里会写：

```
*** cockpit: swallowed scene foreground assertion
```

其它异常照常上报。这是原型阶段的妥协，等车机屏那条路验证完再考虑从根上避免。

## 日志

`/var/mobile/Library/Logs/Cockpit.log`（256 KB 轮转），记录：

- `--- Cockpit 0.0.10 loaded ---`：tweak 被加载
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
