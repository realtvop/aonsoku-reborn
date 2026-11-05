# 标题

feat(ios): 添加原生 CarPlay 浏览与共享播放支持

# 正文

为原生 iOS 应用接入 CarPlay 系统模板，提供首页、资料库、下载内容和系统正在播放界面。CarPlay 与手机共用 AonsokuKit 的 AudioService、资料库、缓存和媒体会话，连接车辆不会创建第二个播放器或协调设备。

- 使用现有 GRDB 资料库提供分页浏览、收藏、历史、完整专辑／歌单上下文和可用下载内容。
- 列表保留逻辑条目身份，并按系统容量分页；下载播放校验完成状态、文件存在性及索引字节大小。
- 队列条目携带出现位置及队列版本，区分重复歌曲并拒绝过期选择。
- 选择准备设置 15 秒超时，取消立即完成行回调，迟到任务不能覆盖新的队列；远程播放投影禁用本机 CarPlay 操作。
- 账号和资料库变化触发刷新；读取图片直接复用上游缓存接口，不依赖锁屏封面的 helper。
- 添加 CarPlay 场景声明和签名配置，保留 Aonsoku 名称及现有包标识。

## 验证

- `bash scripts/test-ios-native.sh`：507 项原生测试通过，零失败，包含 CarPlay 浏览、系统模板、队列重复项／版本、分页和取消回调检查。
- arm64 iOS 模拟器应用构建通过。
- `node scripts/check-ios-strings.mjs` 通过。

真机签名需要 CarPlay Audio entitlement 和匹配的 provisioning profile。不具备能力的设备构建可设置 `AONSOKU_ENTITLEMENTS=Aonsoku/Resources/App.entitlements`；实际车机连接、音频路由及断连恢复仍需真机验收。
