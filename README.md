# DouyinLiquidGlass（抖音液态玻璃插件）

借鉴 [winaviation-tweaks/liquidass](https://github.com/winaviation-tweaks/liquidass) 的"玻璃思路"（backdrop 实时模糊层 + 高光渐变 + 圆角 + 可配置），针对**抖音 App 内部 UI**（按钮、底部 tab 栏、搜索框等）做的独立越狱插件。

- 编译产物：`.dylib`（App 注入用）+ `.deb`（Sileo/Zebra 安装用）
- 只作用于抖音进程（bundle id：`com.ss.iphone.ugc.Aweme`），不碰 DYKiller，可共存
- 支持 iOS 14.0+

## 效果边界（重要）

| 能力 | 是否支持 | 说明 |
|---|---|---|
| 磨砂玻璃（实时背景模糊） | ✅ | `CABackdropLayer` + `CAFilter`，App 进程内可用 |
| 高光渐变 / 圆角 / 深浅色 | ✅ | 与 LiquidAss 同款 specular 思路 |
| 折射 / 色散（iOS26 液态玻璃签名效果） | ❌ | 那是 backboardd 渲染服务的自定义 Metal 着色器，App 进程内无入口 |

即：做出来是"磨砂液态玻璃风格"，不是逐像素折射。

## 目录结构

```
DouyinLiquidGlass/
├── Tweak.x                  # 主入口：hook UIView 生命周期 + 命中路由
├── DYGlassView.h/.m         # 玻璃视图（CABackdropLayer + CAFilter + 高光）
├── DYGlassInjector.h/.m     # 玻璃注入 / 几何同步 / 移除
├── DYPrefsSupport.h/.m      # 偏好读取 + 命中判定 + 热更新
├── Makefile / control / DouyinLiquidGlass.plist
└── Prefs/                   # 设置面板（preferenceloader）
```

## 构建（需要 macOS + Theos，或 Linux + Theos）

```bash
# 1. 安装 Theos（Mac 上）
git clone --recursive https://github.com/theos/theos.git $THEOS
# 到项目目录：
cd DouyinLiquidGlass
export THEOS=~/theos
make clean && make package
# 新越狱（Dopamine/palera1n，rootless）：
make clean && make package THEOS_PACKAGE_SCHEME=rootless
```

产物在 `packages/` 下：`com.dy.liquidglass_0.1.0_iphoneos-arm.deb`。

## 安装

- **deb 方式**：把 `.deb` 传到手机，Sileo/Zebra/Filza 安装，重启抖音即可。
- **dylib 注入方式**（配合已注入 dylib 的抖音 IPA）：把编译出来的
  `DouyinLiquidGlass.dylib` 与你的注入工具（如爱思/自签 + dylib 注入）一起打进 IPA。

## 关键一步：告诉插件"抖音的哪些视图是按钮/tab栏"

插件内置了"底部横条启发式"（宽条贴底自动识别），开箱即可对抖音底部 tab 栏生效。
要更精准地对**按钮、搜索框**等生效，需要获取你当前抖音版本的类名：

```bash
# 用已解密抖音 IPA（或越狱机上 /var/containers/Bundle/Application/.../Aweme.app/Aweme）
class-dump -H Aweme -o dumped/
# 或 Mac 上用
python3 -m pip install ipatool ... (取包) 
# 然后搜你关心的元素类名：
grep -rn "class .*TabBar\|class .*Button\|class .*Search" dumped/ | head
```

把拿到的类名填进 **设置 → Douyin Liquid Glass → 精确类名 / 类名子串**（逗号分隔），保存后即时生效，无需重编译。

## 设置项

- `Enabled` 全局开关
- `Heuristics` 底部横条自动识别
- `Gloss` 高光强度 / `Blur` 高斯半径（0=系统材质）/ `Quality` 捕获质量 / `CornerRadius` 圆角
- `TargetClasses` / `TargetSubstrings` / `ExcludedClasses` 目标与排除
- 改动保存即热更新（Darwin 通知 `com.dy.liquidglass/Reload`）

## 常见问题

- **某元素没变玻璃**：多半是类名没填对 / 该元素不是背景型视图，先在 `TargetSubstrings` 里加宽范围试。
- **某个元素背景被误删**：把它的类名加进 `ExcludedClasses`，或在代码 `DYLooksLikeBackgroundSubview` 里收紧判断。
- **重启失效**：越狱环境加载插件需要看是否用了正确的 rootless/rootful 打包方式。
