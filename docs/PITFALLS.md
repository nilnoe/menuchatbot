# macOS SwiftUI 踩坑记录

> 本文是项目踩坑与开发经验的**单一权威来源**（2026-08 起合并自
> CHANGELOG「开发经验」章节与 0.3.0 实测修复记录）。每条先给结论，
> 再给复现与验证方法——避免再次把时间花在"玄学"上。
> 新增踩坑时补充到对应分类；CHANGELOG 只记版本变更，不再重复根因。

## 1. 点击与交互

### 1.1 ZStack 重叠按钮：点击被下层按钮吃掉

**现象**：整行 Button 与叠在它上面的快捷 Button（ZStack + trailing alignment）
重叠时，快捷按钮点击无效。

**根因**：macOS 上 SwiftUI 对重叠的 Button 做命中测试时，点击落到最上层的
整行 Button（下层按钮无法获得事件）。视觉上按钮"看得见、点不动"。

**规避**：不要用 ZStack 叠放可点击控件；行内容与操作按钮用并排 HStack
（`HStack { rowButton; quickActions }`），天然无命中冲突。

### 1.2 `.borderless` 按钮在 ScrollView + LazyVStack 中点击无响应

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

### 1.3 嵌套 ForEach + LazyVStack：跨组移动保留过期行快照

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

### 1.4 共享 hover 状态被跨行事件覆盖

**现象**：快捷按钮 hover 状态用共享 `hoveredSessionID` 时，鼠标跨行移动
leave/enter 顺序不定，后到的 nil 会把新行的 hover 覆盖——按钮闪现消失、
点击落空（「取消置顶有时不起作用」）。

**规避**：hover 状态改为每行自持（行内 `@State`），不再共享。

### 1.5 `.alert` 在 NSPanel 上延迟 / 不出现

**现象**：在 NSPanel 承载的面板内用 `.alert` 弹窗（如重命名输入）会延迟
或直接不出现。

**规避**：需要即时输入的操作改行内编辑（输入框 + Enter 确定 / Esc 取消 /
✓✗ 按钮），与主区操作行为一致。

## 2. 布局与测量

### 2.1 SwiftUI `.frame(maxWidth:)` 的两种反直觉行为

- 放在 **HStack + Spacer 里的气泡**上：贪婪扩展到 maxWidth，短文本也撑满整行 → 气泡过长。
- 放在 **VStack 内层**包内容：理想宽度为 0，容器直接塌陷。

**结论**：聊天气泡要「贴合文字 + 限宽换行」，用**行级限宽**——限制整行宽度，
气泡在行内自然贴合。行为用 GeometryReader 探针实测验证
（`BubbleLayoutTests` 固化该规则），不要凭直觉改布局。

### 2.2 ScrollView 自身的 background GeometryReader 实测回报 0×0

**现象**：用 ScrollView 自身的 `.background(GeometryReader)` 测视口尺寸，
永远拿到 0×0——preference 拿不到真实尺寸，空状态因此从未真正居中、
短会话顶置的 minHeight 也未生效。

**规避**：用 GeometryReader 包裹 ScrollView，直接取真实消息区尺寸再传给内容。

## 3. 滚动与列表

### 3.1 LazyVStack 程序化滚动到未物化区域 = 空白

长内容下 `proxy.scrollTo("bottom")` 的目标可能从未被 LazyVStack 物化，
滚动落点渲染成空白，且**只有用户手动滚动才触发物化**（Apple 论坛 741406
同款问题）。

试过的错误方案：

- 把底部锚点挪出 LazyVStack 常驻物化：目标有效了，但**视口里仍是未物化的
  消息行**，空白依旧。
- 把最后几条消息移出 LazyVStack 用外层 VStack 常驻：空白解决，但 **VStack
  需要 LazyVStack 的完整高度 → 懒加载被杀死**，每次分片刷新 260ms、每次
  resize 330ms（基准实测），全应用卡顿。

**最终方案**：倒置聊天列表（inverted ScrollView）——`ForEach(messages.reversed())`，
容器与每行各旋转 180°（双重旋转让文本/选区恢复正向）。新消息天然落在视觉
底部，「滚动到底」变成滚动到相邻且必然已物化的一行，LazyVStack 保持直接
子级、懒加载完好。

## 4. 数据与状态

### 4.1 `@Published` 对数组的就地修改也会逐字段发布

`@Published var sessions: [ChatSession]` 下，`sessions[i].messages[j].content = x`
这类就地元素修改**同样会触发 objectWillChange**（每个字段一次）。最初实现
「流式静默写回存储」时因此白做了假设，测试计数（6 次发布 = 5 字段 +
updatedAt）才暴露。

**结论**：需要「写回但不刷新 UI」时，把 setter 改为 `private(set)` 并显式
控制 `objectWillChange.send()`；`@Published` 只留给真正需要自动发布的值。

### 4.2 Swift String 写时复制 + 写回共享缓冲 = 隐藏的 O(n²)

`state.content += chunk` 本身是均摊 O(1)；但一旦把 `state.content` 复制给存储
（两个引用共享同一缓冲区），下一次追加就会触发整块 CoW 拷贝，每分片一次
全文复制，长回复退化成 O(n²)。

**结论**：流式写回不要逐分片做；配合聚合窗口（40ms）把写回频率压到固定值，
CoW 摊薄到可忽略。

### 4.3 每 token 一次全文重排

即使每消息有独立 ViewModel，分片直接追加仍会让 SwiftUI `Text` 对累积全文
重新排版。

**结论**：增量先进 pending 缓冲，按固定时间窗口（30~60ms）聚合提交 UI。
这是所有流式聊天客户端的通用做法。

### 4.4 旧 Task 收尾覆盖新一轮流式状态（竞态）

`stop()` 取消任务后，任务要等网络栈把取消传播完才继续执行收尾代码；若用户
紧接着发送新消息，旧任务的收尾会把新任务的 `streamingSessionID /
streamingState` 清成 nil，新回复失去流式标记，长输出按最终路径每分片全文
解析 → 卡死。

**结论**：异步任务收尾写共享状态前，先校验状态仍属于自己（如
`streamingState === 本次 state`）；再给消息自身维护 `isStreaming` 标记兜底，
行内渲染不依赖可能被覆盖的外部状态。

### 4.5 `URL.resolvingSymlinksInPath()` 只对已存在的完整路径生效

**现象**：`PathScope` 的 symlink 逃逸测试
（`root/link/secret.txt`，`link` 是指向根目录外目录的符号链接）用
`resolvingSymlinksInPath()` 做包含判断时**放行**，误判为"仍在根目录内"。

**根因**：`resolvingSymlinksInPath()` 只在**最终路径存在**时解析 symlink；
当目标文件尚不存在（纯路径包含检查、未真正读取前）时，路径前缀里的目录
symlink 不被解析，返回字面路径。

**规避**：先对「最长存在的祖先」解析 symlink，再把剩余组件拼回，最后做
前缀包含判断：

```swift
var probe = url.standardizedFileURL
var suffix: [String] = []
while !FileManager.default.fileExists(atPath: probe.path) {
    suffix.insert(probe.lastPathComponent, at: 0)
    probe.deleteLastPathComponent()
}
let resolved = probe.resolvingSymlinksInPath().path
    + (suffix.isEmpty ? "" : "/" + suffix.joined(separator: "/"))
```

`PathScope.canonicalized(_:)` 即此实现；`PathScopeTests` 覆盖 `..` 逃逸、
symlink 逃逸、根目录拒绝（ACCEPTANCE T4-1b 的前置契约）。

**教训**：路径安全逻辑不能依赖"路径存在时才正确"的系统 API；先用真实
目录 + symlink 做 shell 实验锁定 API 行为，再写实现。

## 5. 窗口与面板

### 5.1 NSPanel autosave 把窗口拽窄后无法恢复

**现象**：设置页曾固定 420pt 宽——内容固有宽度会把 NSPanel 拽窄，autosave
还会记住窄尺寸，返回主界面后窗口无法恢复原大小。

**规避**：页面「撑满窗口 + 内容限宽居中」（表单限宽 420 居中），打开 / 返回
设置页窗口尺寸保持不变；`SettingsWindowSizeTests` 回归守护（复现：切到设置页
窗口从 1000 被拽到 420）。

## 6. 验证方法论

### 6.1 不依赖真机的 SwiftUI 交互验证

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

### 6.2 渲染与性能验证

- **真实视图挂窗渲染测试**：把完整视图挂进 `NSHostingView` + `NSWindow`，
  强制布局后 `cacheDisplay` 截图，用「非背景像素占比」判断消息区是否空白；
  强制浅色外观让指标有效（深色模式下空白背景也是深色，指标失真）。
- **系统日志取证**：`/usr/bin/log show --predicate 'process == "DeepSeekChat"'`
  配合数据库更新时间，能还原用户操作时序（如 -999 取消流与复现时刻吻合）。
- **对照实验**：怀疑某改动导致回归时，临时还原旧实现跑同一测试/基准，
  确认测试真的能抓到问题，再恢复修复。
- **基准先行**：性能回归用可量化的布局耗时对比（流式 flush / resize 毫秒数），
  不要靠感觉。

### 6.3 附加调试坑

- **stdout 缓冲**：重定向到文件时 stdout 全缓冲，应用挂起会看不到日志。
  `setbuf(stdout, nil)` 关缓冲后再打印。
- **钥匙串阻塞**：无签名调试二进制反复启动会触发钥匙串授权等待，
  `SecItemCopyMatching` 卡住主线程导致应用无法启动。调试自检时通过
  DEBUG 分支跳过 Keychain 读取。
- **数据目录隔离**：测试用 `mv` 移走真实数据目录时，若目标已存在同名目录，
  `mv` 会嵌套而不是覆盖，多次运行会产生深层嵌套。先删除目标再移入，或
  每次用带时间戳的新目录名。

### 6.4 AsyncStream 测试时序：消费者挂上前的发布会被缓冲

**现象**：`SessionStoreIndexEventTests` 里，`AsyncStream` 会把消费者挂上
之前 `yield` 的事件全部缓冲——测试因此拿到 setup 阶段的旧事件；改用
"先 drain 再收集"的写法时，drain 的 `for await` 在 `Task.cancel()` 后
**不会退出**（AsyncStream 迭代不检查取消），把被测事件也吃掉，收集结果
恒为空。

**根因**：AsyncStream 无界缓冲 + 多消费者语义不确定；
`Task.cancel()` 不会中断 `for await` 循环。

**规避**：让**所有被测操作都发生在收集窗口内**——先启动消费者 Task，
再执行操作，最后 sleep 等事件到达再 cancel：

```swift
var events: [IndexEvent] = []
let task = Task { for await event in store.indexEvents { events.append(event) } }
try? await Task.sleep(for: .milliseconds(20))
body()   // 被测操作全部放在这里
try? await Task.sleep(for: .milliseconds(50))
task.cancel()
```

不要断言 setup 阶段的事件，也不要试图"排空后再收集"（drain 停不下来）。

**教训**：AsyncStream 的"先发布后消费"语义适合生产（不丢事件），不适合
直接做测试断言；测试要显式控制事件窗口。

## 7. 排查心法

- 症状"点击没反应"至少有三种可能：事件没到（命中链）、事件到了但 action
  没触发（样式 / 追踪循环）、action 触发了但数据没变（过期闭包 / 存储）。
  用埋点逐步二分，先确认 action 闭包有没有被调用。
- 视图显示的是数据快照，闭包捕获的也是快照；跨容器移动、条件渲染的视图
  都可能持有旧快照。凡依赖"当前值"的操作，一律从数据源读。
- 修一个"玄学" bug 前，先做对照实验（同结构换样式、换容器、加/删修饰器），
  用排除法锁定唯一变量。
