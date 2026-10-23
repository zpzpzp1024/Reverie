# Reverie

让一台越狱 iPhone 能长期待在车里：**车通电就唤醒，车断电就休眠**，避免停车期间被后台任务和常亮屏幕把电耗光。

当前版本 `0.1.2`，界面全中文。

## 使用范围

适用于：

- 固定在车里（支架 + 车载 USB 供电）的越狱 iPhone
- 越狱环境：Dopamine、palera1n 等 **rootless** 越狱，iOS 13 及以上
- 有线、无线 CarPlay 都可以用，不需要为休眠牺牲 CarPlay

前提假设：**熄火后车的 USB 口会断电**。如果那口是常电（不少车会延时断电甚至一直供电），手机会一直处于"充电中"，永远不会休眠。

不太适合：

- 日常主力机。休眠会挂起整机，期间后台活动、远程指令、定位全部停止
- 需要随时用"查找"定位的设备。休眠期间设备不可达

## 工作原理

| 事件 | 动作 |
| --- | --- |
| 插上电源 | 退出休眠，屏幕保持熄灭 |
| 拔电 + 锁屏 + 没有 CarPlay + 9 秒宽限 | 进入休眠 |
| 连按音量减 5 次、控制中心开关、设置页按钮 | 手动唤醒：亮屏、解锁，90 秒内不再自动休眠 |
| 自动唤醒（插电） | 20 秒内不再自动休眠，留出 CarPlay 重连时间 |

细节：

- **9 秒宽限** = 3 秒轮询 × 3 次，用来等车机走完关机流程；期间一旦插电或 CarPlay 还在，计数清零
- **休眠** 调用 `IOPMSleepSystem` 挂起应用处理器（AP），相当于 iOS 自己的锁屏待机状态，只是由我们主动发起，不必等系统空闲
- **不动射频**：不切飞行模式、不关 Wi-Fi/蓝牙。切飞行模式断开的正是无线 CarPlay 依赖的蓝牙握手和 Wi-Fi 传输，唤醒后会连不上车机
- **CarPlay 检测** 通过 SpringBoard 多出来的外接 `UIScreen` 判断，带 2 秒缓存
- 休眠期间 `IOPMSleepSystem` 不可达（查找、SSH、远程推送全部停止），插电是唯一可靠的自动唤醒源

## 设置项

设置 → Reverie。

| 设置项 | 默认 | 说明 |
| --- | --- | --- |
| 启用 | 开 | 总开关，关闭后所有自动行为停止 |
| 接上电源时唤醒 | 开 | 检测到充电立即退出休眠。这是整套方案的核心，建议保持开启 |
| 拔掉电源时休眠 | 开 | 断电后按规则进入休眠 |
| 仅在锁屏时休眠 | 开 | 亮屏使用中不休眠，防止正在操作时被挂起 |
| 使用 CarPlay 时也休眠 | 关 | 开启后忽略 CarPlay 会话强制休眠，**CarPlay 必然断开**。只在完全不用 CarPlay，或怀疑 CarPlay 检测误判导致永不休眠时才打开 |
| 立即休眠 | 按钮 | 主动挂起，之后插电或连按音量减 5 次唤醒 |
| 应用（右上角） | — | 保存配置并 Respring |

判定顺序：总开关 → 是否充电 → 是否在保护期内 → 是否锁屏 → 是否有 CarPlay → 宽限计数。

## 安装

### 从 Sileo 源

添加源 <https://zpzpzp1024.github.io/Reverie/>，安装 Reverie。

### 手动安装 deb

用 Filza 打开 `.deb` 选安装，或 SSH：

```sh
scp packages/lilliana.reverie_*_iphoneos-arm64.deb root@<iphone-ip>:/var/mobile/
ssh root@<iphone-ip>   # 默认密码 alpine
/var/jb/usr/bin/dpkg -i /var/mobile/lilliana.reverie_*_iphoneos-arm64.deb
sbreload
```

安装完必须 Respring。控制中心模块需要在"设置 → 控制中心"里手动添加，名字显示为"休眠"。

依赖：`mobilesubstrate`（ElleKit 可提供）、`preferenceloader`、`ccsupport`，iOS 13+。

> 包名 `lilliana.reverie` 与上游 Paisseon 的包相同。同时添加两个源时会被识别为同一个包的版本更新。

## 验证

所有事件同时写入 `/var/mobile/Library/Logs/Reverie.log`，可直接在 Filza 里打开，超过 256 KB 自动清空重写。

实时查看（日志是 info 级别，**必须加 `--info`**）：

```sh
log stream --info --style compact --predicate 'subsystem == "lilliana.reverie"'
```

注意：**USB 线也算充电**，接着电脑永远不会休眠。要在电池状态下测，事后再读日志文件。

锁屏状态下拔电，预期序列：

```
charger state changed, charging = false
sleeping, reason = autoSlept
IOPMSleepSystem
```

插电后：

```
charger state changed, charging = true
waking, reason = autoWoken
```

判读：

| 日志现象 | 含义 |
| --- | --- |
| 没有 `coordinator started` | tweak 没加载：检查包是否装上、ElleKit 是否正常 |
| 有启动日志但从不出现 `sleeping` | 没锁屏、一直在充电，或处于保护期内 |
| `sleeping` 后没有 `IOPMSleepSystem` | 被 CarPlay 拦截，或 IOPM 连接没建立（看上一条 `IORegisterForSystemPower connect = 0`） |
| 反复 `carplay is active, staying awake` 但并没在用车机 | CarPlay 误判，可临时打开"使用 CarPlay 时也休眠" |
| `IOPMSleepSystem` 后立刻 `waking` | 刚睡就被叫醒，多半是供电接触不良或车机反复试探 |

> `IOPMSleepSystem` 这行是调用前写入的，代表"请求已发出"，不构成内核确认。真要确认睡实了，看日志时间戳的空档、SSH 是否冻结、以及一夜掉电（正常 1–3%）。

## 常见问题

**睡死了叫不醒**

连按音量减 5 次（前几次会被唤醒过程吃掉，所以是 5 次）；或直接插充电线（会自动唤醒但屏幕不亮）；都不行就快按音量加、再快按音量减，然后长按电源键直到出现苹果标志，Dopamine 需要重新引导。

**一夜掉电超过 5%**

先查熄火后 USB 是否还供电（充电中就永不休眠）；再翻日志，看是没睡，还是睡了被反复叫醒。

**为什么休眠不关 Wi-Fi 和蓝牙**

有意为之。关射频省不了多少电（AP 挂起才是大头），却会在唤醒后破坏无线 CarPlay 的重连路径，而且一旦唤醒链路异常，设备会卡在离线状态、只能手动恢复。

**和普通锁屏待机有什么区别**

睡眠档位相同（iOS 没有更深的挂起到磁盘），区别在于时机和确定性：拔电锁屏 9 秒就睡，不等系统空闲计时；有后台任务拖着也照睡；被误唤醒后还能重新睡回去。

## 从源码构建

macOS + Theos + `iPhoneOS16.5.sdk` + `ldid`：

```sh
make setup          # 拉取 Jinx 与 JinxPrefs
make package FINALPACKAGE=1
```

产物在 `packages/`。CI（`.github/workflows/build.yml`）在每次推送时构建并上传 artifact；推送 `v*` 标签还会创建 Release 并把 `.deb` 挂上去，同时更新 `gh-pages` 上的 Sileo 源。

## 致谢

基于 [Paisseon/Reverie](https://github.com/Paisseon/Reverie)，设置界面使用 [Jinx](https://github.com/Paisseon/Jinx) 与 [JinxPrefs](https://github.com/Paisseon/JinxPrefs)。
