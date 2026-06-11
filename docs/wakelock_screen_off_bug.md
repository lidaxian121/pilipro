# 播放中熄屏 Bug：wakelock 多实例竞争问题

> 日期：2026-06-12
> 状态：**已修复**，真机验证通过
> 影响版本：2.0.0+45 及之前（wakelock 逻辑位于 PLVideoPlayer 生命周期的所有版本）
> 修复改动：`lib/plugin/pl_player/controller.dart`、`lib/plugin/pl_player/view.dart`

---

## 一、表现形式（用户视角）

视频**正在播放**时，屏幕仍按系统熄屏时间（本机 30 秒）自动熄灭，无法保持常亮。特征：

- **全屏时最容易察觉**：全屏看视频不碰屏幕，30 秒后熄屏；
- **时好时坏**：同样是全屏播放，有时常亮正常、有时必熄屏，看似无规律；
- **暂停一下就好了**：手动暂停再播放后，该播放会话的常亮恢复正常；
- 旧版中**小窗（应用内悬浮窗）播放时也会熄屏**。

## 二、稳定复现路径（真机验证）

四步走，**必现**：

1. 打开任意视频（自动播放），此时常亮正常；
2. 按返回退出视频页，视频进入应用内小窗继续播放（此步常亮通常仍正常）；
3. **点小窗两下将其"扩大"回视频页** ← 丢锁发生在这一步，必现；
4. 进入全屏（或停留在页面），30 秒内不碰屏幕 → **屏幕熄灭，而视频还在播放**。

实测时间线（设备 ColorOS，熄屏 30 秒，用 `dumpsys` 监测）：

| 时间 | 步骤 | KEEP_SCREEN_ON | 播放状态 |
|---|---|---|---|
| 04:52:02 | ① 打开视频+全屏 | ✅ | PLAYING |
| 04:52:41 | ② 退出成小窗 | ✅ | PLAYING |
| 04:53:31 | ③ 小窗扩大+全屏 | ❌ **丢失** | PLAYING |
| 04:54:15 | 距最后触屏约 30s | ❌ | PLAYING |
| 04:54:15 起 | **屏幕熄灭（Awake→Dozing），视频仍在播放** | ❌ | PLAYING |

验证命令：

```bash
# 是否持有常亮锁（fl= 行包含 KEEP_SCREEN_ON 即为持有）
adb shell "dumpsys window windows | grep -A 5 'com.example.pilipro/com.example.pilipro.MainActivity}:' | grep fl="
# 播放状态
adb shell "dumpsys media_session | grep -m1 'state=PlaybackState'"
# 屏幕状态
adb shell "dumpsys power | grep mWakefulness="
```

## 三、根本原因

### 3.1 缺陷结构

修复前，屏幕常亮锁（`wakelock_plus`，本质是 Activity 窗口的 `FLAG_KEEP_SCREEN_ON`，**全局唯一开关**）的开关逻辑绑在每个 `PLVideoPlayer` widget 实例的生命周期上（`pl_player/view.dart`）：

- `initState`：若正在播放则 `WakelockPlus.enable()`，并监听 `player.stream.playing` 切换锁；
- `dispose`：`WakelockPlus.enabled.then((i) { if (i) WakelockPlus.disable(); })`。

而播放器 widget 会在 **视频页 ↔ 应用内小窗 ↔ 新视频页** 之间交接，交接时全局锁同时被两个实例操作。

### 3.2 为什么"小窗扩大"必丢锁

小窗扩大回页面时，新旧两个 `PLVideoPlayer` 的 GlobalKey 不同（`videoPlayerKey` 是每个页面 State 自己的字段），无法做 GlobalKey 状态搬运，只能"新建一个 + 销毁一个"。Flutter 框架保证了如下同帧顺序：

1. **build 阶段**：新页面 `PLVideoPlayer.initState` → 正在播放 → `enable()` 发出（开锁）；
2. **帧末 finalizeTree**：小窗旧 `PLVideoPlayer.dispose` → 读 `WakelockPlus.enabled`（读到 true，因为刚被上一步打开）→ `disable()` 发出（关锁）。

平台通道按序执行：enable → 读 true → **disable 最后落地** → 锁被关掉。这个顺序是框架时序决定的，**必然发生**。

### 3.3 为什么丢了就不会自己恢复

重新开锁只由 `stream.playing` 的**状态变化**触发。丢锁后视频一直在播、状态不变，监听器永远不被唤醒 → 锁永久丢失，直到下一次暂停/播放（这就是"暂停一下就好了"的原因，也是排查时难以稳定观察的原因——任何一次暂停/恢复测试都会无意中"治好"它）。

### 3.4 为什么"时好时坏"

- 步骤②（页面→小窗）：小窗的 builder 是原页面 State 的闭包，用**同一个** GlobalKey，通常发生状态搬运（reparent），锁不被碰 → 不丢；偶尔 reparent 跨帧失败时退化为"新建+销毁"竞态 → 偶尔丢。
- 步骤③（小窗扩大）：必丢（见 3.2）。
- 丢锁后的所有页面/全屏都继承无锁状态 → "从小窗扩大之后的所有页面都会熄屏"。

## 四、排查过程（要点）

1. 静态排查：全工程仅 `view.dart` 两处 `WakelockPlus.disable`（监听器 false 分支、dispose），锁定嫌疑范围；
2. 真机实测基础机制健康：竖屏/全屏播放、暂停恢复，锁开关都正确；
3. **抓到现场**：`dumpsys` 显示媒体会话 PLAYING 而窗口无 KEEP_SCREEN_ON，且持续数分钟不恢复；
4. 判别实验：丢锁状态下暂停→恢复，锁立即回来 → 证明监听器健在，问题是"被人多关了一次且无人再开"；
5. 用户提供稳定复现路径（开视频→退小窗→小窗扩大→全屏），逐步记录锁状态，定位丢锁点为步骤③；
6. 结合 `_tryEnterPipMode`（view.dart:2281，小窗 builder 复用页面闭包/GlobalKey）与 Flutter 帧末 dispose 时序，解释全部现象（必现、时好时坏、暂停自愈、首次小窗不熄屏）。

## 五、解决方案

**原则：锁收归单一所有者，只跟"是否在播放"这一个事实走，与 widget 生命周期完全解耦。**

最小化修改（净增约 6 行）：

### `lib/plugin/pl_player/controller.dart`

1. 新增 import：`package:wakelock_plus/wakelock_plus.dart`；
2. 私有构造函数中恢复（原本被注释掉的）状态监听：

```dart
// wakelock 由单例 controller 按播放状态统一管理；
// 不能放在 PLVideoPlayer 的生命周期里，否则页面/小窗/全屏交接时
// 旧实例 dispose 的 disable 会晚于新实例的 enable 落地，导致播放中丢锁
_playerEventSubs = onPlayerStatusChanged.listen((PlayerStatus status) {
  if (status == PlayerStatus.playing) {
    WakelockPlus.enable();
  } else {
    WakelockPlus.disable();
  }
});
```

3. `dispose()`（播放器真正销毁、`_playerCount` 归零的路径）中加 `WakelockPlus.disable();` 兜底。

### `lib/plugin/pl_player/view.dart`

删除三处与 wakelock 相关的代码：

- `initState` 中的 enable + `stream.playing` 监听；
- `dispose` 中的 `WakelockPlus.enabled.then(... disable)`；
- `wakeLock` 字段与 `wakelock_plus` import。

### 修复效果（真机验证，2026-06-12 05:10）

同样的四步复现路径：步骤③后锁保持持有（旧版必丢），全屏放置 60+ 秒（远超 30 秒熄屏时间）屏幕保持常亮、视频连续播放；**小窗播放也能正确常亮**（附带修复）。

## 六、遗留事项

`lib/common/widgets/interactiveviewer_gallery/interactiveviewer_gallery.dart:364` 使用了 media_kit 自带的 `Video` widget，其内部有独立的引用计数 wakelock，dispose 时也会全局 `WakelockPlus.disable()`，理论上可踩掉播放器的锁（路径：播放中打开图廊内嵌视频再关闭）。属边缘场景，未在本次修改范围内；如遇到，暂停/播放一次即可恢复。彻底解决可改用 `SimpleVideo` 或给该 `Video` 传 `wakelock: false`。

## 七、经验教训

- **全局唯一资源（wakelock、音频焦点等）不要绑在可多实例、可交接的 widget 生命周期上**，应由单例按状态管理；
- Flutter 中"新 widget 的 initState 在 build 阶段、旧 widget 的 dispose 在帧末"是固定顺序——任何"dispose 里做全局清理、initState 里做全局申请"的配对，在交接场景下都会出现"清理盖掉申请"；
- 排查这类 bug 时注意：**测试动作本身（暂停/恢复）会治愈症状**，要先用只读手段（`dumpsys`）抓现场，再做干预性实验。
