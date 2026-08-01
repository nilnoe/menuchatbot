# macOS SwiftUI 踩坑记录

> 本文沉淀本项目在 macOS SwiftUI 交互问题上的真实排查经验（2026-07-31 ~
> 2026-08-01 侧栏快捷按钮 / 置顶交互），供后续开发参考。每条都先给结论，
> 再给复现与验证方法——避免再次把时间花在"玄学"上。

## 1. ZStack 重叠按钮：点击被下层按钮吃掉

**现象**：整行 Button 与叠在它上面的快捷 Button（ZStack + trailing alignment）
重叠时，快捷按钮点击无效。

**根因**：macOS 上 SwiftUI 对重叠的 Button 做命中测试时，点击落到最上层的
整行 Button（下层按钮无法获得事件）。视觉上按钮"看得见、点不动"。

**规避**：不要用 ZStack 叠放可点击控件；行内容与操作按钮用并排 HStack
（`HStack { rowButton; quickActions }`），天然无命中冲突。

## 2. `.borderless` 按钮在 ScrollView + LazyVStack 中点击无响应

**现象**：快捷操作图标按钮（`Button { Image } .buttonStyle(.borderless)`）
在侧栏滚动列表里点击无效；同结构下 `.plain` / `.bordered` 均正常。

**根因**：macOS 26 实测，`borderless` 样式的按钮在 ScrollView + LazyVStack
中鼠标事件进入 SwiftUI 手势追踪后 action 不触发；Accessibility 的 AXPress
同样无效（说明不是鼠标命中问题，而是按钮 action 链路本身）。

**规避**：滚动列表内的图标按钮用 `.plain`（与行主体按钮一致），不要用
`borderless`。如果必须用 borderless，先做样式对照实验验证。

**教训**：修改问题时一次只动一个变量。本项目曾把 plain 误改成 borderless
（与 ZStack 修复同时进行），把"ZStack 重叠"的失败样本记到了 plain 头上，
导致修复后 bug 依旧、还新增了一个坏样式。

## 3. 嵌套 ForEach + LazyVStack：跨组移动保留过期行快照

**现象**：会话被置顶、从「今天」组移入「置顶」组后，行上的快捷按钮状态
与闭包数据仍是移动前的（按钮 help 还是「置顶」、闭包捕获的 `isPinned`
还是 false），导致：无法取消置顶（再次置顶 = 无操作）、重命名拿到旧标题、
选中态卡在第一个置顶会话（行不重渲染，`isSelected` 不更新）。

**根因**：`ForEach(分组) { ForEach(会话) { 行 } }` 的嵌套结构 + LazyVStack，
在子项跨外层 ForEach 实例移动时，SwiftUI 保留了旧位置的视图快照，行内容
与闭包捕获值不随数据更新。

**规避**：列表拍平为**单一** `ForEach`，组头与行作为同一数组的两种条目
（`SidebarItem` 枚举：`case header(String)` / `case session(ChatSession)`，
identity 分别为 `header-<title>` / 会话 id）。跨组移动变成同一 ForEach 内部
的 identity 移动，SwiftUI 会正确更新行内容。

**双保险**：闭包不捕获数据快照，需要时从 store 读当前值再操作：

```swift
onTogglePin: {
    let current = sessionStore.session(id: session.id)
    sessionStore.setPinned(id: session.id, pinned: !(current?.isPinned ?? false))
}
```

## 4. 验证方法论：不依赖真机的 SwiftUI 交互验证

SwiftUI 按钮在 xctest 环境（窗口非 key、应用未激活）不响应合成事件，
无法用单测覆盖点击链路。以下方法可在**真实应用进程内**完成交互验证，
无需辅助功能权限：

1. **在真实应用里注入 AppKit 事件**：DEBUG 参数启动应用 → 显示面板 →
   用 `window.sendEvent` 投递 mouseDown / mouseUp。普通按钮（plain /
   bordered）在窗口 key 且应用激活时响应。
2. **追踪循环陷阱**：部分 SwiftUI 按钮的 mouseDown 会进入事件追踪循环，
   从应用事件队列读取下一个事件。同步补发 mouseUp 会死锁——先把 mouseUp
   用 `NSApp.postEvent(up, atStart: false)` 投进队列，再发送 mouseDown，
   让追踪循环从队列取到 mouseUp（最后再显式 `sendEvent(up)` 兜底）。
3. **AXPress 是第二通道**：`AXUIElementPerformAction(element, kAXPressAction)`
   对同进程元素无需权限。行按钮（AX 命中）可用它驱动选中，避开鼠标注入
   的差异。
4. **坐标空间**：AX 位置是**屏幕左上原点**坐标；AppKit 是屏幕左下原点。
   换算 `appKitPoint = (axX, screenHeight - axY)`，再
   `panel.convertPoint(fromScreen:)` 转窗口坐标。
5. **用状态验证，不用视觉**：点完按钮查 `sessionStore` 的真实状态（isPinned
   是否翻转、标题是否变更），不要依赖截图 / AX 文本。选中态可用「选中行
   快捷按钮常显」的规则，数 AX 中 help 匹配的按钮数量观察。

### 附加调试坑

- **stdout 缓冲**：重定向到文件时 stdout 全缓冲，应用挂起会看不到日志。
  `setbuf(stdout, nil)` 关缓冲后再打印。
- **钥匙串阻塞**：无签名调试二进制反复启动会触发钥匙串授权等待，
  `SecItemCopyMatching` 卡住主线程导致应用无法启动。调试自检时通过
  DEBUG 分支跳过 Keychain 读取。
- **数据目录隔离**：测试用 `mv` 移走真实数据目录时，若目标已存在同名目录，
  `mv` 会嵌套而不是覆盖，多次运行会产生深层嵌套。先删除目标再移入，或
  每次用带时间戳的新目录名。

## 5. 排查心法

- 症状"点击没反应"至少有三种可能：事件没到（命中链）、事件到了但 action
  没触发（样式 / 追踪循环）、action 触发了但数据没变（过期闭包 / 存储）。
  用埋点逐步二分，先确认 action 闭包有没有被调用。
- 视图显示的是数据快照，闭包捕获的也是快照；跨容器移动、条件渲染的视图
  都可能持有旧快照。凡依赖"当前值"的操作，一律从数据源读。
- 修一个"玄学" bug 前，先做对照实验（同结构换样式、换容器、加/删修饰器），
  用排除法锁定唯一变量。
