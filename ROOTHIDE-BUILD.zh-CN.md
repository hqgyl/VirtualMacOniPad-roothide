# RootHide 版本 —— 作者署名与当前功能

> English version: [ROOTHIDE-BUILD.md](ROOTHIDE-BUILD.md)

本分支（`codex/roothide-compat`）在 Virtual Mac 之上做两件事：适配
**RootHide（Dopamine-roothide）**，以及把安装包改为**在 iPad 本机上直接构建**
（不再依赖 Mac）。标准 Dopamine/Taurine 安装的行为没有任何改变，标准包仍然走上游
的构建流程。

## 署名

- **Virtual Mac on iPad** —— [nfzerox/VirtualMacOniPad](https://github.com/nfzerox/VirtualMacOniPad)，
  原作者项目：基于 Virtualization 的 macOS 运行时、UIKit 宿主、Guest Tools 以及
  共享框架的提取，全部来自上游；本分支只增加了越狱兼容层和设备端构建。
- **RootHide / Dopamine 兼容** —— 上游 PR #78（yyyr-p），本分支的起点：
  `VZHostCompat.dylib`、`VirtualMacPaths.dylib` 路径重定向、RootHide 安装器打标
  和 roothide 打包。
- **RootHide / Dopamine-roothide** —— 提供 bootstrap、`libroothide` 与 `jbctl`，
  让 ad-hoc 签名的包能在非平台签名环境里运行。
- 本分支的设备端构建移植是在 iPad Pro 11 英寸（M2，iPad14,4）+ iPadOS 16.1.1 +
  Dopamine-roothide 上编写并验证的。

## 本分支做了什么

1. **RootHide 包** `com.mac.virtual`（`iphoneos-arm64e`），以官方 1.2.3 deb 为
   快照构建：Apple 的 payload 和 App 资源来自该 deb，而宿主 App、
   `VZHostCompat.dylib`、`VirtualMacPaths.dylib`、`runtime-processes`、
   `legacy-storage`、`install-launcher`、`install-macos`、`MetalCompat`、
   `LaunchServicesCompat`、`InstallationCompat`、键盘直通 tweak 和
   `virtualmac-diagnostics` 都在本机编译。
2. **可以在设备上构建**：`scripts/build-roothide-deb.sh` 不再需要 `xcrun`、
   `ditto`、`shasum`、`python3`、`plutil`、`rsync`、`awk`。改用设备上的
   clang/SDK、`cp -a`、`sha256sum`、GNU sed，并用 `scripts/lib/macho.sh`
   （od/dd）完成原本由 `vz/patches/add_macho_dylib.py` 做的 LC_LOAD_DYLIB 注入。
   在 Mac 上行为保持不变。
3. **launchd 能接受的守护进程**：NetworkSharing 作业以 `vzi.apple.NetworkSharing`
   发布——这正是 roothide 的 launchd 给 bootstrap 里的 `com.apple.NetworkSharing`
   分配的标签；postinst 与 stop-runtime 同时识别两种标签。
4. **更顺的宿主输入**：滚动合帧的 `CADisplayLink` 请求 60–120Hz（默认只有 60），
   并且每两秒把 guest 实际出帧率写进日志（`guest frames N/s`）。

## 已在设备上验证

测试环境：iPad Pro 11 英寸 M2 / iPadOS 16.1.1 / Dopamine-roothide。

- 包可以安装；`postinst` 会建立私有状态目录、迁移旧库、用 `jbctl` 把每个 Mach-O
  加入信任缓存并注册 App；
- App 启动并显示虚拟机资料库；
- macOS 15.6.1（24G90）还原安装可以跑到 `INSTALL_SUCCEEDED`；
- 该虚拟机可冷启动：payload 里的 VMM 运行、`[GuestPolicy] guest CSR policy
  complete`、12 次 `IOSurfaceCreate`、`PVG frame=1..3`，键盘与指针事件送达
  guest，运行中会写它的磁盘；
- 实测 guest 画面最高约 30fps（开机阶段峰值 33.8），桌面闲置时几乎不出帧——
  这个上限来自 Virtualization 框架的 framebuffer 刷新率，不是 App 的绘制循环，
  所以虚拟机画面做不到 120Hz；
- 设定 `NetworkMode = NAT` 时，`InternetSharing` 与 `bootpd` 能被 launchd 拉起，
  guest 从 vmnet 拿到 `192.168.64.2` 的租约。

## 未验证

- `en0`（Wi‑Fi）桥接：能配置成功，但 guest 拿不到租约；可用的是 NAT。
- 键盘直通 tweak、在 iPadOS 16 上的 iPadOS 15 运行时变体、挂起/恢复、共享文件夹、
  音频和外接显示器。
- 120Hz 滚动只能用触控板或鼠标体感验证，本机未实际测试。

## 构建

在设备上（或在 Mac 上，命令不变）：

```sh
VZ_BASE_DEB=/path/to/VirtualMac_1.2.3.deb \
VZ_ROOTHIDE_SDK=/path/to/roothide-sdk/devkit \
bash VirtualMac/scripts/build-roothide-deb.sh
```

`VZ_BASE_DEB` 指定「从已发布 deb 取快照」的构建方式；不设置时会先跑各组件构建。
RootHide devkit 只需要一个 `roothide.h`（`jbroot`/`rootfs`/`jbrand`）和一个
`libroothide.tbd` 存根，安装名是
`@loader_path/.jbroot/usr/lib/libroothide.dylib`。设备端的坑记录在 `AGENTS.md`。
