# DouyinLiquidGlass（抖音液态玻璃插件）

借鉴 [winaviation-tweaks/liquidass](https://github.com/winaviation-tweaks/liquidass) 的"玻璃思路"（backdrop 实时模糊层 + 高光渐变 + 圆角 + 可配置），针对**抖音 App 内部 UI**（按钮、底部 tab 栏、搜索框等）做的独立插件。

- 编译产物：`.dylib`（App 注入用）+ `.deb`（Sileo 安装用）
- 只作用于抖音进程（bundle id：`com.ss.iphone.ugc.Aweme`），不碰 DYKiller，可共存
- 支持 iOS 14.0+

## 架构（0.5.6，稳定最终形态）

**不依赖 CydiaSubstrate / ElleKit 的 `%hook`**，用 Objective-C runtime 直接 swizzle。核心四点：

1. **悬浮胶囊（不改原生容器）**：底栏容器保持原生位置尺寸，玻璃画成"胶囊"垫在容器内部——原生 tab 项天然都在胶囊内（标签跟随），容器不动所以不碰进度条、不触 AutoLayout 冲突、切 tab 不消失；
2. **定向 Hook**：只对已套玻璃的类做定向 `layoutSubviews` Hook（性能优，不拖慢抖音）；
3. **稳定磨砂**：`UIVisualEffectView`（App 进程内稳定），自绘对角线高光 + 顶部亮边；右侧按钮/头像方形自动转**圆形胶囊**；
4. **保守清底 + 层级正确**：只隐藏"铺满且类名像背景/含 Blur、且内部无任何图标/文字"的视图；**任何含 UIImageView/UILabel 的子视图一律不隐藏**（头像/图标绝不误伤）；玻璃被原生重排移除时自动钉回底层。

**诊断开关写死关闭**：Debug / ShowClassTag / Heuristics 一律 `return NO`，**无视本地残留旧 plist**（此前真机红框/标签一直出现，是诊断时手动改过 plist 的残留值在作祟）。

同一份 dylib **两种装法都能跑**：
- 作为 **deb 装进 Dopamine（Sileo）**，由 ElleKit 注入抖音进程；
- 用 **TrollStore / TrollFools 直接注入抖音 IPA**（无需越狱运行时）。

## 配置（`/var/mobile/Library/Preferences/com.dy.liquidglass.plist`）

| Key | 默认 | 说明 |
|---|---|---|
| `Enabled` | YES | 总开关 |
| `Debug` | **NO（写死）** | 调试红框/日志（不再读配置，防旧 plist 污染） |
| `ShowClassTag` | **NO（写死）** | 红色类名标签（不再读配置） |
| `Heuristics` | **NO（写死）** | 几何盲猜（不再读配置，防全屏误伤） |
| `Floating` | YES | 底栏悬浮胶囊开关 |
| `FloatMargin` | 16 | 胶囊左右内缩(pt) |
| `FloatCornerRadius` | -1 | 胶囊圆角（-1=高度一半药丸） |
| `BlurStyle` | 59 | 磨砂样式（59=SystemThinMaterialDark） |
| `Gloss` | 0.7 | 高光强度 0~1 |
| `TargetClasses` | 内置 | 精确类名白名单：AWEFeedTopBarContainer（顶部导航）/ AWENormalModeTabBar（底部栏） |
| `TargetSubstrings` | 内置 | 右侧按钮猜测类名（AWEFeedLikeButton 等），**必须小尺寸+含图标才生效** |
| `ExcludedClasses` | 内置 | 排除：AWEFeedViewCell / AWEGradientView |

## 效果边界（重要，请务必理解）

| 能力 | 是否支持 | 说明 |
|---|---|---|
| 磨砂玻璃（实时背景模糊） | ✅ | `UIVisualEffectView`（App 内稳定） |
| 高光渐变 / 圆角 / 玻璃淡色底 / 悬浮药丸 | ✅ | 自绘 specular + 边缘亮边 + 悬浮重构 |
| 折射 / 色散（iOS26 液态玻璃签名效果） | ❌ | 那是 backboardd 渲染服务的自定义 Metal 着色器，App 进程内无入口 |

即：做出来是"**磨砂液态玻璃风格**"，不是逐像素折射/色散。这是 App 进程内能达到的效果上限。

## 目录结构

```
DouyinLiquidGlass/
├── Tweak.x                  # 主入口：轻量 didMoveToWindow 发现 + 命中路由（无 substrate）
├── DYGlassView.h/.m         # 玻璃视图（UIVisualEffectView 磨砂 + 自绘高光 + 淡色底）
├── DYGlassInjector.h/.m     # 注入/深度清底/悬浮重构/定向Hook/类名标签/移除
├── DYPrefsSupport.h/.m      # 偏好读取 + 命中判定缓存 + 热更新
├── Makefile / control / DouyinLiquidGlass.plist
└── Prefs/                   # 设置面板（preferenceloader，暂缓编译）
```

## 构建（GitHub Actions 云端编译，无需 Mac）

本项目用 `.github/workflows/build.yml` 在 GitHub 的 macOS runner 上编译，
自动产出 rootful + rootless 两种 deb（arm64 + arm64e 新 ABI，适配 Dopamine）。

推送/上传代码到仓库后，Actions 自动构建；构建产物在运行页底部 **Artifacts → deb** 下载。

## 安装（两种路线任选）

**路线 A：Dopamine（Sileo）装 deb**
1. 下载 `deb.zip` 解压出 `.deb`；
2. 传到手机，用 Filza 点击 → 安装（Sileo 完成）；
3. 注销（respring）→ 杀掉抖音 → 重开。

**路线 B：TrollStore / TrollFools 注入 dylib**
1. 编译产物里的 `DouyinLiquidGlass.dylib`（从 deb 中解出，或在 CI 里单独产物）；
2. 用 TrollFools 注入到已安装的抖音 App；
3. 杀掉抖音 → 重开。

> 本插件不依赖 substrate，因此路线 B（无越狱运行时）同样能跑。

## 命中逻辑（开箱即用 + 可调）

1. **排除名单**（`ExcludedClasses`）→ 最高优先，命中直接跳过；
2. **精确类名**（`TargetClasses`）→ 完全匹配即套玻璃；
3. **类名子串**（`TargetSubstrings`）→ 内置默认：`TabBar / TabBars / BottomBar / BottomNav / MainTabBar / ToolBar / BottomTab`，命中即套；
4. **底部横条启发式**（`Heuristics`）→ 宽 > 200pt、宽 > 2×高、贴底 <60pt 自动识别。

类名判定有**三级缓存**，抖音上千视图反复布局也不会卡。

## 调参（不需要重编译）

设置面板暂缓编译，但所有参数都走 plist 热更新。用 Filza 编辑：

```
/var/mobile/Library/Preferences/com.dy.liquidglass.plist
```

常用键：
- `Enabled`（BOOL，默认 YES）
- `Debug`（BOOL，默认 YES，套玻璃时会打 `[DouyinLiquidGlass] 套玻璃: 类名` 日志）
- `FilterType`（默认 `systemMaterialBlur`，iOS15 自动回退 `gaussianBlur`）
- `Blur`（高斯半径，0 = 用默认 25）
- `Gloss`（高光强度 0~1，默认 0.7）
- `Quality`（捕获质量，默认 1）
- `CornerRadius`（圆角，<0 跟随目标）
- `Heuristics`（启发式开关，默认 YES）
- `TargetClasses` / `TargetSubstrings` / `ExcludedClasses`（数组）

改完保存后（或执行 `notifyutil -p com.dy.liquidglass/Reload`）即时生效，无需重启抖音。

## 常见问题

- **某元素没变玻璃**：看日志有没有 `[DouyinLiquidGlass] 套玻璃: XXX`；没有 → 类名没命中，把它的类名加进 `TargetSubstrings`。
- **某个元素背景被误删/误套**：把类名加进 `ExcludedClasses`。
- **想要更精准的按钮类名**：用 class-dump 解你当前抖音版本的类名，填进 `TargetSubstrings`。
- **想恢复设置面板**：在根 `Makefile` 取消 `#SUBPROJECTS += Prefs` 的注释，重新编译一版即可。
