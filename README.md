<p align="center"><img src="icon.png" width="128"></p>

<h1 align="center">放行 LetIn</h1>

<p align="center">一个轻量的 macOS 小工具，一键解除系统对未验证 App 的拦截。</p>

macOS 打开网上下载的 App 时，可能会弹出下面这些提示：

- “Apple 无法验证 “xxx” 是否包含可能危害 Mac 安全或泄漏隐私的恶意软件”
- “xxx 已损坏，无法打开。你应该将它移到废纸篓”
- “无法打开 xxx，因为无法验证开发者”

把这个 App 拖进「放行」，就能直接打开了。

## 功能

- 拖进窗口、点击选择，或者拖到 Dock 图标上都可以
- 清除隔离标记（效果等同于 `xattr -cr`）
- 可选：本地重新签名（`codesign --force --deep --sign -`），用于提示“已损坏”的情况
- 需要权限时弹出系统的管理员授权窗口
- 用 SwiftUI 写成，单个源文件，大小约 2 MB，同时支持 Apple Silicon 和 Intel

## 构建

需要 macOS 14 以上和 Xcode Command Line Tools。

```sh
./build.sh
cp -R "build/放行.app" /Applications/
```

## 注意

这个工具会绕过 Gatekeeper 的安全检查，请只用于来源可信的软件。

## License

MIT
