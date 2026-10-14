# 术语表

本项目专有名词与约定用法。

跨项目通用的术语收录在全局术语表中，本表只收本项目特有的，不重复登记。全局表不在本仓库内，位于 iCloud Global 镜像的 `Documentations/Glossary.md`。

## 维护约定

提案或专题文章引入新术语时，**同批次**登记进本表。文档里首次出现该术语时展开一次并链到这里，之后不必每篇重复解释。

## 术语

按英文名 / 标识符字母序排列。

### Arrival-order start（按到达顺序启动）

同一个连接上的消息，其 handler 按消息到达的顺序**开始**执行；每个 handler 在连接的串行执行器上运行到第一个挂起点（`await`）为止，挂起时下一条消息的 handler 才可能开始。它**不是**严格串行：handler 可以在挂起点交错，后到消息的 handler 可能先结束。

- **主要出现在**：`Sources/SwiftyXPC/Internal/MessageDispatcher.swift`、`Tests/SwiftyXPCTests/DispatchTests.swift`
- **延伸阅读**：[实现说明](Internal/Version1Implementation.md) 决策一

### Dispatch strategy（派发策略）

`MessageDispatcher.Strategy`：一个连接用哪种执行器、是否用 `Task.immediate` 启动 job。`automatic` 由系统版本决定；`serialQueueExecutor`、`queueExecutor` 分别模拟 macOS 14–25 与 12–13 的路径，只供测试在新系统上覆盖旧路径。

- **主要出现在**：`Sources/SwiftyXPC/Internal/MessageDispatcher.swift`
- **延伸阅读**：[实现说明](Internal/Version1Implementation.md) 决策二

### LWCR（lightweight code requirement，轻量代码要求）

Apple 在 macOS 14.4 起用于 XPC 对端校验的条件格式：一个 XPC 字典，写法与 launch constraint 相同，可以用 `$or` 等操作符组合多个条件。在本项目里对应 `XPCPeerRequirement.lightweightCodeRequirement(_:)`，与代码签名要求字符串（`.codeSigning(_:)`）是两种不同的语言。

- **主要出现在**：`Sources/SwiftyXPC/XPCPeerRequirement.swift`
- **延伸阅读**：Apple 文档 *Defining launch environment and library constraints*

### Protocol version（协议版本号）

1.0 起每条消息与回复都带的 `com.charlessoft.SwiftyXPC.XPCEventHandler.ProtocolVersion` 键，值为 `int64` 1。接收方不要求它存在，目前也不据此改变行为；它只为日后的格式变更留出判断依据。0.5.x 不发送它。

- **主要出现在**：`Sources/SwiftyXPC/XPCConnection.swift`、`Tests/SwiftyXPCTests/WireCompatibilityTests.swift`

### Stray answer（0.5 多余回复）

0.5.x 的接收方在处理完一条**单向**消息后回发的那条无名消息（只带 body，没有名字、协议版本号与回复上下文）。它源于 0.5.x 的缺陷，不携带任何有用信息；1.0 不再发送，并在收到时静默丢弃。同样由 0.5.x 回发、但带 error 键的无名消息不算多余回复，它报告的是单向 handler 的错误。

- **主要出现在**：`Sources/SwiftyXPC/XPCConnection.swift` 的 `isStrayAnswerFromVersion05(_:)`
- **延伸阅读**：[实现说明](Internal/Version1Implementation.md) 决策十

### Wire compatibility（线上互通）

不同版本的 SwiftyXPC 进程之间能互相收发消息：消息字典的键、各类型的编码方式、错误的封装格式都保持一致。本项目承诺 1.0 与 0.5.x 线上互通，因为特权 helper 常常与它的主 App 分开更新。注意它与源码兼容性（source compatibility）无关：1.0 的公开 API 有破坏性改动，线上格式没有。

- **主要出现在**：`Tests/SwiftyXPCTests/WireCompatibilityTests.swift`、`Tests/Interop/README.md`
- **延伸阅读**：[提案](Evolutions/draft-swift-concurrency-1-0.md)
