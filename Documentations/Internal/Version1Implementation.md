# SwiftyXPC 1.0：实现说明

> 配套提案见 [Swift Concurrency 现代化与 1.0 缺陷修复](../Evolutions/draft-swift-concurrency-1-0.md)。
> 本文记录**实际落地的实现**、与提案的差异，以及当前覆盖范围与已知降级。面向维护者。

## 背景与目标

1.0 做了三件事：修掉消息回复与编解码里的缺陷；把消息派发改成「每个连接一个串行执行器、按到达顺序启动 handler」，并按 Swift 6 并发模型重做公开 API；接入 macOS 12 之后新增的 XPC 对端校验与连接失效原因。约束是不引入 Foundation、部署目标 macOS 12、与 0.5.x 对端线上互通。完整动机与取舍在提案里。

## 关键设计决策

### 一、派发：自写串行执行器的 actor，「弹出最旧的 job」保证顺序

`MessageDispatcher` 是一个 actor，执行器是一条串行 dispatch 队列，这条队列同时是连接的 XPC target queue。每条消息变成一个 job，追加到加锁的 FIFO；随后为它创建一个隔离到 dispatcher 的任务，任务开始时**弹出最旧的 job** 并同步运行到第一个挂起点。

- **顺序不依赖任务的运行顺序。** 弹出和启动在 actor 上一气呵成，所以无论任务以什么顺序被调度，job 都按到达顺序启动。这是有意为之：下面几条路径对「任务按创建顺序运行」的保证各不相同，这样设计就不必依赖任何一条。
- **否决 default actor。** default actor 按优先级调度 job，而 XPC 以发送方的 QoS 递送每条消息，同一发送方的消息会因 QoS 不同而被重排。`DispatchTests` 里相邻消息交替使用高低 QoS，就是为了守住这一点。
- **否决在事件处理器里 `assumeIsolated`。** 这是提案原来的设计。macOS 15 之前的运行时在没有任务上下文的 dispatch block 里判断隔离时直接返回 false（Swift 5.10 `Actor.cpp` 的 `swift_task_isCurrentExecutorImpl`：无 `ExecutorTrackingInfo` 时只认主线程），`assumeIsolated` 随即 trap。
- **用部分应用把任务直接排进 actor 的执行器。** `Task(operation: self.startOldestJob)` 里的 `self.startOldestJob` 隔离到 `self`（SE-0431），`Task.init` 是 `@_alwaysEmitIntoClient`，会把它作为初始执行器传给运行时；5.5–5.9 的运行时把这个 kind 0 的 task option 解释为 `Executor`，同样直接入队。
- **macOS 26+ 用 `Task.immediate`。** 事件处理器本身就在 dispatcher 的队列上，运行时能确认隔离（`DispatchSerialQueue` 的执行器实现了隔离检查），job 在事件处理器里同步启动，省一次排队。
- **执行器选择。** macOS 14+ 用 `DispatchSerialQueue` 自带的执行器；12–13 用自写的 `QueueExecutor`（`enqueue(_: UnownedJob)` 投递到同一条队列，`runSynchronously(on:)` 执行，`checkIsolated()` 用 `dispatchPrecondition`）。

### 二、`MessageDispatcher.Strategy`：让新系统也能走旧路径

本机是 macOS 27，`automatic` 永远走 `DispatchSerialQueue` + `Task.immediate`，在这条路径上待启动的 job 永远只有一个，「弹出最旧」是否正确根本测不出来。`Strategy` 的另外两个值强制走 macOS 14–25（`serialQueueExecutor`）和 12–13（`queueExecutor`）的路径，`XPCConnection` / `XPCListener` 通过内部初始化方法传入，`DispatchTests` 对 `Strategy.allCases` 参数化。

做过两次变异检查确认测试的灵敏度：把弹出最旧改成弹出最新，两条非 `automatic` 路径失败；把派发改成严格串行（不在 `await` 处交错），三条路径都超时失败。

### 三、handler 的返回值不标 `sending`，泛型参数要求 `SendableMetatype`

- **返回值不标 `sending`。** Swift 6.4 拒绝把「返回普通值的函数」转换成「返回 `sending` 值的函数类型」，即使返回类型本身是 `Sendable`（`converting a value of type ... to type ... -> sending String risks causing data races`）。这会让 README 推荐的 `handler: self.sayHello` 写法在 Swift 6 下编不过。去掉之后仍然安全：handler 类型在本模块里默认是 `nonisolated(nonsending)`，在连接的执行器上运行，响应也在那里编码，不跨隔离域；若调用方传入隔离到别处（例如 `@MainActor`）的函数，编译器会在转换处要求响应是 `Sendable`。请求参数保留 `sending`，因为「普通参数 → `sending` 参数」方向的转换总是允许的。
- **`SendableMetatype`。** handler 闭包在连接的执行器上调用 `Request.self` 解码、`Response` 编码，捕获了泛型元类型；SE-0470 要求这些元类型可跨隔离域。普通类型都自动满足，被排除的只有 Codable 一致性隔离到某个 actor 的类型——这种一致性本来就不能在连接的执行器上调用。

### 四、`sendMessage` 在调用方解码回复

回复处理块在 XPC 的线程上运行。若在那里解码，就要捕获 `Response.Type`，从而给 `Response` 加上 `SendableMetatype` 约束。改为把原始回复装进 `@unchecked Sendable` 的盒子经 continuation 交回调用方，在调用方的隔离域里解码（`sendMessage` 是 `nonisolated(nonsending)`），`Response` 只需 `Decodable`。

`XPCDecoder.decode(type:from:)` 返回 `sending T`，内部用 `nonisolated(unsafe)` 局部变量跳过区域检查：解码出的值完全由消息内容新建，与 `xpcObject` 共享的只能是 endpoint 之类不可变、线程安全的 XPC 对象。

### 五、锁：`LockedState` 类层次

`LockedState<State: Sendable>` 是一个非 final 基类，`make(_:)` 在 macOS 15+ 返回包着 `Mutex` 的子类，以下返回包着堆上 `os_unfair_lock` 的子类。

- 不用 `any P<State>` 做类型擦除：带主关联类型的存在类型需要 macOS 13 运行时。
- `State` 与 `withLock` 的 `Result` 都要求 `Sendable`：`Mutex.withLock` 的闭包参数是 `inout sending`、返回 `sending`，只有 `Sendable` 类型能免于区域检查地穿过去。
- 锁不可重入，闭包里不调用用户代码。`XPCErrorRegistry.encodeError` 原来持锁编码错误（会在锁内运行任意 `encode(to:)`），已改为不持锁。

### 六、库 target 停在 Swift 5 语言模式

Swift 6 模式下 Swift 6.4 编这个库时在 IRGen 崩溃。用最小探针定位了触发面：**本模块不导入 Foundation 时，任何需要 XPC 对象类型元数据的用法**都会触发——存储属性、enum 关联值、`[xpc_object_t]`、把 `xpc_object_t?` 传给泛型函数、`as?` 转换到 XPC 类型。闭包捕获、函数参数与返回值、装进 `AnyObject` 再 `unsafeBitCast` 回来则不触发。原因是 `ImportObjcForwardDeclarations`（SE-0384）把只有前向声明的 `NSString` 导入成占位类型，IRGen 为 `OS_xpc_object` 继承的 `NSObjectProtocol` 懒生成 ObjC 协议元数据时，在 `description` 的 getter 描述上崩溃。

要在 Swift 6 模式下绕开，就得在整个库里禁止上述所有写法，每违反一次就是一次编译器崩溃——这个约束太宽、太隐蔽，不值得。于是按提案的退路：库 target 用 Swift 5 模式，加上除 `ImportObjcForwardDeclarations` 之外的全部 14 个 Swift 6 特性，数据竞争检查与 Swift 6 模式相同。测试、helper、共享测试代码导入了 Foundation，不受影响，用 Swift 6 模式。所有 target 打开 `NonisolatedNonsendingByDefault`。

探针结果（`swiftc -swift-version 6 -target arm64-apple-macos12.0 -c`）：

| 写法 | 结果 |
|------|------|
| struct / class 的 `xpc_object_t` / `xpc_endpoint_t` / `xpc_connection_t` 存储属性 | 崩溃 |
| enum 关联值是 `xpc_object_t` | 崩溃 |
| `[xpc_object_t]` | 崩溃 |
| `withExtendedLifetime(xpc_object_t?)` | 崩溃 |
| `value as? xpc_object_t` | 崩溃 |
| 闭包捕获 `xpc_object_t` | 正常 |
| 函数参数 / 返回 `xpc_endpoint_t` | 正常 |
| 存成 `AnyObject`，用 `unsafeBitCast` 取回 | 正常 |
| 同样的存储属性在 Swift 5 模式 | 正常 |

### 七、对端校验：统一用 macOS 14.4 的公开 setter；`senderSatisfies` 用 `dlsym`

- macOS 26 的 `xpc_connection_set_peer_requirement` 与整个 `xpc_peer_requirement_*` 系列在 SDK 里标了 `XPC_SWIFT_NOEXPORT`，Swift 看不见；Apple Swift overlay 的 `XPCPeerRequirement` 也不公开底层对象。14.4 起的 `xpc_connection_set_peer_*_requirement` 没有弃用、语义相同、本机即可测试，所以所有系统统一用它们。代码签名要求在 12+ 用 `xpc_connection_set_peer_code_signing_requirement`。
- `senderSatisfies(_:)`（macOS 26+）的非代码签名分支需要 `xpc_peer_requirement_create_*` 与 `xpc_peer_requirement_match_received_message`。这些函数在 26 之前不存在，`@_silgen_name` 声明是强引用，dyld 在库加载时就要解析，会让 12–25 上**所有**使用本库的程序无法启动，所以用 `dlsym(RTLD_DEFAULT, …)` 运行时查找。代码签名分支没有对应的 `xpc_peer_requirement_t` 构造函数，用 Security 的 `SecCodeCreateWithXPCMessage` + `SecCodeCheckValidity`。
- 私有 SPI `xpc_dictionary_get_audit_token`（给每条消息取审计令牌）在 macOS 12.0.1、13.0 的 shared cache 里确认有导出，可以用 `@_silgen_name` 强引用。

### 八、listener 与已接受连接共享 handler 表

listener 把 handler 与 error handler 存在一个 `HandlerTable` 里，已接受的连接在查自己的表之后、消息到达时再查它。于是 listener 上后设的 handler 对已经连上的对端也生效，没有自己 error handler 的连接使用 listener 的。这替代了原来「接受连接时拷贝一份」以及匿名 listener 的 `isMulti` 特例。

### 九、初始化失败时先激活再取消

XPC 把「释放一个从未激活过的连接」视为 API 误用并崩溃。原来只有 Mach service 连接在校验条件被拒时做了「设空 handler → activate → cancel」，端点和 bundle 连接会崩溃（回归测试在旧代码上确认 signal 5）。现在指定初始化方法对所有连接统一处理。

### 十、识别 0.5 的「多余回复」

0.5 的接收方对每条单向消息都会回发一条只带 body 的无名消息（1.0 修掉的缺陷一）。1.0 的发送方把「无名、无协议版本号、有 body、无回复上下文」的消息静默丢弃。1.0 自己从不发无名消息，所以不会误伤。带 error 键的无名消息是 0.5 接收方报告单向 handler 的错误，照常交给 `errorHandler`。

## 模块结构

```
Sources/SwiftyXPC/
├── XPCConnection.swift            # 连接、handler 注册、发送、事件处理、回复与错误回传
├── XPCListener.swift              # 三种 listener、接受连接、xpc_main 的全局槽位
├── XPCMessageContext.swift        # 每条消息的上下文与 senderSatisfies(_:)
├── XPCPeerRequirement.swift       # 对端校验条件及其应用
├── XPCObjectRepresentable.swift   # 以 XPC 对象本身传输的值的协议
├── XPCEncoder.swift / XPCDecoder.swift
├── XPCError.swift / XPCErrorRegistry.swift
├── XPCEndpoint.swift / XPCFileDescriptor.swift / XPCNull.swift / XPCType.swift
├── Extensions/String+SwiftyXPC.swift
└── Internal/
    ├── MessageDispatcher.swift    # 每连接的串行执行器与按序派发、QueueExecutor
    ├── HandlerTable.swift         # 加锁的 handler 表
    ├── LockedState.swift          # Mutex / os_unfair_lock
    └── PrivateXPCInterfaces.swift # 无 Swift 声明的 libxpc 函数（@_silgen_name 与 dlsym）
```

## 核心算法与数据流

**收到消息**（全部在 dispatcher 的队列上开始）：

1. `handleEvent`：listener 自己的连接交给 `listenerEventHandler`（接受新连接或报告 listener 级错误）；字典进入 `receive`；错误对象转成 `XPCError`（`connectionInvalid` 带上 `xpc_connection_copy_invalidation_reason`）交给 `errorHandler`。
2. `receive`：带 error 键 → 解码后交给 `errorHandler`（0.5 回传的单向错误）；创建回复字典（`nil` 即单向消息）；0.5 多余回复 → 丢弃；按名字找 handler，找不到 → 报告本地并在有回复上下文时回复 `missingMessageName` / `unexpectedMessage`。
3. 构造 `XPCMessageContext`（逐条消息的审计令牌），`dispatcher.dispatch(job)`。
4. job 在 actor 上运行 handler；结束后 `complete`：有回复上下文就写入协议版本号与 body / error 并发送，error 编码失败则只发域与错误码、本地报告编码失败；单向消息的错误交给本地 `errorHandler`。

**发送请求**：在调用方隔离域编码请求、写入名字与协议版本号 → `xpc_connection_send_message_with_reply` → continuation 交回原始回复 → 在调用方解码（错误对象、error 键、缺 body、`XPCNull` 捷径）。

## 与提案的差异

| 提案 | 实际 | 原因 |
|------|------|------|
| 事件处理器经 `dispatcher.assumeIsolated` 进入 actor 后创建任务 | 加锁 FIFO + 部分应用 `self.startOldestJob` 创建隔离任务，弹出最旧的 job | macOS 15 前 `assumeIsolated` 在 dispatch block 中 trap，见决策一 |
| 无 | `MessageDispatcher.Strategy`，测试覆盖三条路径 | 决策二 |
| handler 返回 `sending Response` | 返回普通 `Response` | 方法引用无法转换，见决策三 |
| 泛型参数只要求 `Decodable` / `Encodable` | handler 的泛型参数另加 `SendableMetatype` | 决策三 |
| 响应在回复处理块里解码 | 在调用方解码 | 避免给 `Response` 加 `SendableMetatype`，见决策四 |
| macOS 26+ 构造 `xpc_peer_requirement_t` 并调用 `xpc_connection_set_peer_requirement` | 所有系统统一用 14.4 的 setter；`senderSatisfies` 才用 26 的函数，经 `dlsym` 查找 | SDK 对 Swift 隐藏这些函数，强引用会让 12–25 无法加载，见决策七 |
| `senderSatisfies` 统一用 `xpc_peer_requirement_match_received_message` | 代码签名分支用 Security | 26 的 API 没有代码签名要求的构造函数 |
| 语言模式优先 Swift 6 | 库 target 用退路配置，其余 target 用 Swift 6 | 编译器崩溃无法局部绕开，见决策六 |
| listener 的 handler 在接受连接时拷贝 | 共享 `HandlerTable`，消息到达时查找 | 决策八 |
| `XPCEndpoint`、`XPCFileDescriptor` 遵循 `XPCObjectRepresentable` | `XPCNull` 也遵循 | 统一三种「以 XPC 对象本身传输」的值，编解码器少一处特判 |
| 落地步骤 3（缺陷修复）在步骤 4（平台升级）之前 | 先升平台再修缺陷 | 避免为 macOS 10.15 / 11 再写一套修复（`Errno` 等需要 macOS 11）|
| 互通验证：用 0.5.105 构建一个对端 | 另把验证程序提交到 `Tests/Interop/`（两个客户端 + README），并在 `WireCompatibilityTests` 用 C API 模拟 0.5 对端做常驻测试 | 让「与 0.5 互通」可以随时复现 |
| 只修提案列出的四个协议缺陷与并发问题 | 另修了实现中发现的同类缺陷，见下 | 用户要求「潜在的 Bug 也要修」 |

提案之外修掉的缺陷（每个都先在旧代码上确认失败或崩溃，再提交修复与回归测试）：

- 解码器在对端可控的输入上 trap：读超出打包字节数据的末尾（`Index out of range`）、遇到接收方不认识的 key（`Couldn't convert string … into key`，新版本对端多出的 enum case 就会触发）、键值容器包着非字典对象（XPC API 误用）。
- `UnkeyedDecodingContainer.decodeNil()` 对非 null 值抛错而不是返回 `false`，`decodeIfPresent(_:)` 因此不能用。
- 解码时第二次请求容器（先试单值、再退回键值表示的常见写法）触发前置条件崩溃。
- `superEncoder()` 写 `super` 键时触发前置条件崩溃，`superDecoder(forKey:)` 读错键，`Codable` 类继承无法往返。
- `XPCEncoder(replyingTo:)` 每次调用都触发前置条件崩溃。
- 错误负载解不出来（例如新版本对端多出的错误 case）时整个错误解码失败；现在退回到域与错误码。
- 端点 / bundle 连接遇到无法解析的签名要求时崩溃（决策九）。
- `XPCType(rawType:)` 漏了 `XPC_TYPE_SHMEM`。

## 验证

- `swift test`：54 个测试，6 个 suite。`MessageDeliveryTests`、`DispatchTests`、`CoderRoundTripTests`、`WireCompatibilityTests`、`SenderRequirementTests` 在测试进程内用匿名 listener 跑；`SwiftyXPCTests` 经 launchd 加载 `TestHelper` 跑跨进程场景（含 14.4 的对端校验与 LWCR）。
- `swift test --sanitize=thread`：全部通过，无竞争报告。
- 缺陷回归测试：先以 `withKnownIssue` 提交证明能复现，会崩溃的则在修复前单独运行确认崩溃，修复后去掉标注。
- 变异检查：见决策二。
- 与 0.5.105 的端到端互通：`Tests/Interop/README.md` 的步骤，2026-10-14 在 macOS 27.2 上两个方向各 8 项检查全部通过。
- Example App：迁到新 API、改为本地包引用与 Swift 6 模式，`xcodebuild … CODE_SIGNING_ALLOWED=NO build` 零警告通过（未做签名与运行验证）。

## 已知降级

- **macOS 12–14.3 只能用代码签名要求。** 其余校验条件的工厂方法在编译期标为 14.4 可用，旧系统上写不出来，不会在运行时静默失效。
- **`senderSatisfies(_:)` 只在 macOS 26+ 可用。**
- **0.5 对端遇到不认识的 `XPCError` / `XPCConnection.Error` case 会崩溃**（0.5 解码器的 `allKeys` 前置条件）。1.0 新增的 `invalidPeerRequirement` 只在初始化时抛出，正常不会经由 handler 传到对端；README 提醒不要让它从 0.5 对端调用的 handler 里逃出去。
- **12–13 的 `QueueExecutor` 路径与 14–25 的入队路径只在 macOS 27 上经 `Strategy` 测过**，没有在真实的旧系统上跑过。
- **取消不传递。** 取消等待 `sendMessage` 的任务不会取消已发出的消息，连接取消也不会取消正在运行的 handler。
- **与 Apple `XPC` 模块重名。** 同时导入 Foundation（或 XPC）与 SwiftyXPC 的文件，在类型位置必须写 `SwiftyXPC.XPCListener` 等。

## 后续工作

- 编译器崩溃修复后，把库 target 切到 Swift 6 语言模式。是否向 swiftlang/swift 报告由用户决定；最小复现见决策六的探针。
- 2.0 删除 `init(type:codeSigningRequirement:)`。

## 延伸阅读

- 配套提案：[Swift Concurrency 现代化与 1.0 缺陷修复](../Evolutions/draft-swift-concurrency-1-0.md)
- 面向使用者的契约：仓库根目录 `README.md` 的 *How handlers run*、*Peer requirements*、*Talking to peers that still use 0.5* 各节
- 互通验证：`Tests/Interop/README.md`
- 术语：[术语表](../Glossary.md)
