# 标题

feat(ios): 支持锁屏沉浸式静态与动态封面

# 正文

为 iOS 26 的系统锁屏播放器提供沉浸式静态封面与动态封面。封面按系统要求生成 3:4 或 1:1 素材，先发布静态封面，再逐步升级为相机运动和 DAV2 深度视差视频；较旧系统继续使用普通封面。

- 复用 AonsokuKit 的 AudioService 和系统媒体会话，加载原始封面并防止缩略图覆盖原图。
- 支持 DAV2 Small FP16/P8/P6 自动或手动分档、按需下载、SHA256 校验及模型管理。
- 提供沉浸／动态开关、运动幅度与速度、资源保护设置及视频缓存管理。
- 生成受内存、温度、低电量和后台策略约束；素材租约防止正在使用的文件被缓存淘汰。
- 补充调试诊断、18 种语言的功能文案和原生回归检查，保留上游 Aonsoku 品牌。

## 验证

- iOS 模拟器应用构建通过（arm64、x86_64）。
- `node scripts/ios/test-lock-screen-artwork.mjs`：静态／动态素材、画面边缘、缓存复用／淘汰、租约保护、失败回退、取消和资源策略检查通过。
- `node scripts/ios/test-dynamic-cover-interface.mjs`：阶段选择、版本隔离和租约生命周期检查通过。
- `node scripts/artwork/test-resolution.mjs`：iOS 分辨率、不放大原图、对齐和资源预算检查通过。
- AonsokuKit `OriginalCoverTests` 通过：原图请求不带 size 参数，且不会被缩略图降级。
- `node scripts/check-ios-strings.mjs` 通过，18 个共享语言目录包含相同的 32 个功能顶层键。

系统锁屏实际呈现、设备资源压力和真实 DAV2 模型下载／推理仍需真机验收；本轮未启用模型下载测试。此 PR 不包含 macOS、Tauri、Electron 后端或原生全屏动态封面视图。
