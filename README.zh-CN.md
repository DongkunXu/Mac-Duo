<p align="center">
  <img src="Sources/MacDuo/Assets.xcassets/AppIcon.appiconset/icon_256@2x.png" width="128" height="128" alt="Mac Duo 应用图标">
</p>

<p align="center"><a href="README.md">English</a> | <b>简体中文</b></p>

# Mac Duo

Mac Duo 为 MacBook 的屏幕开合加入一段折叠过渡效果。合上屏幕时，桌面固定在你平时使用的角度上，屏幕则像一块磨砂玻璃从桌面前转开：靠近转轴的内容保持清晰，越往上越模糊。屏幕回到原来的角度时，画面重新变得清晰。

App 读取 MacBook 内置的屏幕角度传感器，用 GPU 在一个可点穿的叠加层里重绘实时桌面。屏幕处在正常使用角度时，画面保持原样。

<p align="center">
  <img src="docs/images/fold-88.png" width="49%" alt="屏幕在 88°：靠近转轴清晰，越往上越模糊">
  <img src="docs/images/fold-80.png" width="49%" alt="屏幕在 80°：同样的效果，磨砂更强">
</p>
<p align="center"><sub>示意图：把光学模型应用在一张示例桌面上。起效角度 95°，屏幕分别在 88°（左）和 80°（右）。</sub></p>

## 系统要求

- 带屏幕角度传感器的 Apple 芯片 MacBook。开发和测试使用的是 M5 Pro 的 MacBook Pro，设置里的“状态”页会显示是否找到了传感器。
- macOS 26 或更高版本。
- 编译需要 Xcode 26 或更高版本（含 Metal 工具链）和 [XcodeGen](https://github.com/yonaskolb/XcodeGen)。

## 安装

```sh
brew install xcodegen
git clone https://github.com/DongkunXu/Mac-Duo.git
cd Mac-Duo
Scripts/install.sh
```

脚本会编译 Release 版本、运行渲染自检，然后安装到 `/Applications/MacDuo.app` 并打开。以后更新时运行同一个脚本即可。

第一次启动时，macOS 会请求“屏幕录制”权限，Mac Duo 用它来重绘桌面。在“系统设置 → 隐私与安全性 → 屏幕录制”中打开权限，再到 Mac Duo 的“设置 → 状态”里点“重新启动”。新权限只对重新启动后的 App 生效。

### 签名

默认使用临时（ad hoc）签名，不需要 Apple 账号。这种签名下，macOS 会把“屏幕录制”权限绑定到某一次具体的构建上，每次更新后都要重新授权。如果想让权限在更新后保留，可以用自己的证书签名：把 `Config/Signing.local.xcconfig.example` 复制为 `Config/Signing.local.xcconfig`，填入自己的证书和团队 ID。这个文件会被 git 忽略。

### 卸载

退出 Mac Duo，删除 `/Applications/MacDuo.app`，运行 `defaults delete com.dongkunxu.macduo`，再到系统设置的“屏幕录制”列表里移除 Mac Duo。

## 使用

Mac Duo 只在菜单栏运行。

- **菜单栏面板**：开关、实时屏幕角度、当前状态、起效角度滑块、预设、暂停和设置。
- **起效角度**：低于这个角度时效果生效，达到或高于它时桌面保持原样。默认 95°，可以在 60° 到 120° 之间按 0.5° 调节。设成比平时使用角度稍低一点比较合适。
- **设置 → 调节**：运动模型和玻璃效果的全部参数。改动立即生效，可以一边开合屏幕一边调。
- **设置 → 预设**：保存和恢复整套参数。
- **暂停**：在任何地方按 ⌃⌥⌘D。
- **语言**：支持英文和简体中文，默认跟随系统语言，也可以在“设置 → 状态”里单独选择。

## 行为与保护

- 起效角度是硬性界限：叠加层只在它以下出现，而且任何设置都不能超过 120°。有专门的测试让每个运动模型经历各种真实的开合动作，检查这条规则。
- 屏幕在起效角度以下保持静止时（比如半合着用电脑），效果会在 2 秒后消失。小幅调整时效果保持消失，明确的开合动作会让它重新出现。
- 叠加层只负责显示，点击会落到下面的窗口上。遇到睡眠、锁屏、切换用户、显示器变化、传感器丢失、截屏失败或 GPU 错误时，叠加层会立即移除；它也只在第一帧画好之后才显示。
- 截取的画面只保存在内存里，从不写入磁盘。App 不发起任何网络请求。

## 功耗

屏幕大部分时间都处于静止状态，这时 Mac Duo 几乎关闭了所有工作。

- **休眠**（屏幕静止）：只运行屏幕角度传感器，以低优先级每秒读取 5 次。截屏、显示刷新回调和绘制都停止。30 秒后，叠加层占用的显存也会释放。
- **唤醒**：屏幕有明确的开合动作时启动。移动量从屏幕上一次停稳的位置算起，可以过滤掉磕碰、桌面晃动和打字。远高于起效角度时，屏幕的动作会被忽略。唤醒后约 25 毫秒开始截屏，传感器按 120 Hz 读取，叠加层跟随屏幕刷新率绘制。屏幕停下且没有画面需要绘制约 1 秒后，App 回到休眠。

在 MacBook Pro（M5 Pro）上屏幕静止时的实测：早期一直运行的版本，App 本身约占 7% CPU，另外 WindowServer 为持续截屏要占用约 13% 的单核。休眠状态下 App 约占 0.1–0.2% CPU，截屏处于关闭状态。App 唤醒期间，macOS 会显示屏幕录制指示图标。

## 限制

- 只作用于内建显示器，外接显示器保持原样。
- 锁屏界面始终保持原样。
- 受 macOS 保护、禁止截取的内容（例如部分视频）在叠加层里可能显示为黑色。
- 唤醒需要一次传感器读取（最多 0.2 秒）和约 25 毫秒的第一帧截屏，和一直运行的设计相比，效果开始得会稍晚一点。

## 开发

```sh
xcodegen generate
open MacDuo.xcodeproj
```

命令行：

```sh
# 单元测试：传感器解码、运动模型、起效角度规则、唤醒判定、参数、预设
xcodebuild -project MacDuo.xcodeproj -scheme MacDuo -derivedDataPath build/DerivedData test

# 离屏渲染自检：模糊校准、静止时画面不变、输出数值有效、GPU 耗时
build/DerivedData/Build/Products/Debug/MacDuo.app/Contents/MacOS/MacDuo --self-test
```

| 路径 | 内容 |
|---|---|
| `Sources/MacDuoKit` | 纯 Swift 逻辑：传感器报文、运动模型、功耗判定、参数、预设。 |
| `Sources/MacDuo` | App：传感器线程、截屏、叠加层、渲染、效果着色器、界面。 |
| `Tests/MacDuoKitTests` | MacDuoKit 的测试（Swift Testing）。 |
| `Scripts` | `install.sh`，以及绘制 App 图标的 `make-icon.swift`。 |
| `Config` | 代码签名设置。 |
| `docs` | [架构说明](docs/ARCHITECTURE.md)和[传感器说明](docs/sensor.md)（英文）。 |

界面文字保存在两个 target 的 String Catalog（`Localizable.xcstrings`）里，在 Xcode 中编译时会自动加入新增的文字。

## 致谢

光学模型来自 Madhav Oberoi 和 Elijah Semyonov 的 [FrostFold](https://github.com/askmaddyy/FrostFold)（MIT 协议），这是一个由陀螺仪驱动的 iOS 演示项目。它的思路是：内容平面固定、视点固定、玻璃随设备 1:1 转动、模糊程度与玻璃到内容的距离成正比。Mac Duo 针对 macOS 和屏幕角度传感器独立实现了这套光学模型，并加入了以毫米为单位的物理几何、方差匹配的模糊金字塔、对传感器 10 Hz 读数的平滑处理、起效角度保护逻辑，以及休眠/唤醒功耗管理。

## 许可

[MIT](LICENSE)。Mac Duo 是独立项目，与 Apple 没有关联。
