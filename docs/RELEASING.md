# 发布流程

> 发布与版本管理相关文档索引见 [README.md](README.md)（文档地图）。

当前为 Beta 阶段，发布步骤：

1. **更新版本信息**
   - `scripts/make-app.sh` 中 Info.plist 的 `CFBundleShortVersionString` / `CFBundleVersion`
   - `CHANGELOG.md` 按 Keep a Changelog 风格记录本次变更
   - 同步 README（功能表 / 测试数量）与 docs/（含 TESTING.md 支持 API 手册）
2. **质量门**
   - `swift build` 无警告
   - `swift test` 全绿
   - `swift-format lint --recursive --strict Sources Tests` 零违规
3. **打 tag 触发 CI 出包**
   ```bash
   git tag -a v0.3.0 -m "Beta 0.3"
   git push origin v0.3.0
   ```
   GitHub Actions 的 `release` job 会自动构建并上传 `DeepSeek Chat.app` 产物。
4. **发布 GitHub Release**
   - 把 CI 产物附件到 Release，标题与 tag 一致，正文贴 CHANGELOG 摘要。
   - 目前为 ad-hoc 签名，需提示用户首次打开时右键 → 打开。

## 正式版（1.0）补项

- Developer ID 证书签名 + 公证（notarization）
- dmg 安装包（如 `create-dmg` 等开源工具）
- Sparkle 自动更新（复用开源更新框架）
