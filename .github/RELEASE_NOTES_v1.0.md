# 微信截图恢复 1.0

为 macOS 官方微信恢复窗口截图能力。此发布包为 Apple Silicon 与 Intel Mac 通用构建。

## 验证范围

实测环境：macOS 27.0.1、Apple Silicon。

- WeChat 4.1.15（build 270135）
- WeChat 4.2.0.12；安装包元数据为 `CFBundleShortVersionString=4.2.0`、`CFBundleVersion=270348`

其他版本不会仅因版本号被硬性拦截，但结构预检通过不表示该版本已验证。

## 安装前请注意

- 安装器会备份原版微信并修改安装包签名与运行时加载设置；可能影响登录、钥匙串、应用组或官方更新。
- 安装或回滚后，微信自带截图可能需要在“屏幕与系统音频录制”中重新添加微信授权，并完全退出、重开微信。
- App 使用 ad-hoc 签名，未经 Apple 公证；首次打开时 macOS 可能提示无法验证开发者。
- 详细安装、验收与回滚步骤见 [README](https://github.com/Aanlik/wechat-screenshot-restore/blob/main/README.md)。
