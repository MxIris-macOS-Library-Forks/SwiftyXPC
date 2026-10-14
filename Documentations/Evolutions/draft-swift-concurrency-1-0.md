# Draft - Swift Concurrency 现代化与 1.0 缺陷修复

- **状态**: In Progress
- **作者**: JH
- **创建日期**: 2026-10-13
- **最后更新**: 2026-10-14
- **所属愿景**: 无
- **关联提案**: 无
- **实现分支 / PR**: `feature/swift-concurrency-1.0`（worktree `.worktrees/SwiftyXPC-Concurrency`）
- **配套文档**: [实现说明](../Internal/Version1Implementation.md)（含与提案的差异）；[术语表](../Glossary.md)；面向使用者的契约写在仓库根目录 `README.md`；互通验证见 `Tests/Interop/README.md`

## 摘要

修掉消息收发与编码中已确认的缺陷（单向消息被「回复」、未知消息名不回复、Task 吞错、XPC 对象在转发包装下失效、可变状态无锁），把消息派发改成「每个连接一个串行执行器、按到达顺序启动 handler」，并用 Swift 6.0–6.2 的并发特性（`sending`、`nonisolated(nonsending)`、`@Sendable`、按区域的隔离检查）重做公开 API；同时接入 macOS 12 之后新增的 XPC 能力（细粒度对端校验、连接失效原因），以 1.0.0 发布。工具链要求升到 Swift 6.2 / Xcode 26，最低部署目标升到 macOS 12 / Mac Catalyst 15；与 0.5.x 对端保持线上互通。

## 动机

### 一、协议行为上的缺陷

1. **单向消息会被「回复」一条无名消息。** `respond(to:)` 在 handler 成功后调用 `sendOnewayRawMessage(..., asReplyTo: event)`（`Sources/SwiftyXPC/XPCConnection.swift:584`）。对用 `sendOnewayMessage` 发来的单向消息，`xpc_dictionary_create_reply` 返回 NULL（SDK `xpc/xpc.h`：「NULL if the object was not a dictionary with a reply context」），代码随即退回到新建字典并当成普通消息发出（`XPCConnection.swift:413-425`）。这条消息只有 body、没有 name，发送方的 `handleEvent` 把它交给 `respond(to:)`，以 `XPCConnection.Error.missingMessageName` 通知发送方自己的 `errorHandler`。
   - 现有测试抓不到：TestHelper 里接收这条消息的 `remoteConnection`、`testOnewayVsTwoWay` 里的 `conn` 都没有设置 `errorHandler`。
   - 来历：2021-12-28 的 `6e0ea87`（「Refactor to use `Codable` instead of dictionaries」）把「新建消息」和「回复」合并进同一个函数时引入；上游 CharlesJS/SwiftyXPC 截至 2026-10-13 仍是同样实现，也没有相关 issue。
2. **未知消息名不回复，发送方得到误导性的错误。** 消息缺 name 或没有对应 handler 时（`XPCConnection.swift:559-571`），只通知接收方本地的 `errorHandler`，不回复。逆向确认：消息没被回复就释放时，libxpc 在发送方的 reply 端口收到 send-once 通知，`_Xmach_notify_send_once` 以 `XPC_ERROR_CONNECTION_INTERRUPTED` 调用 reply handler（libxpc 3298.1.1，macOS 27.0；伪代码漏掉了这个参数，看汇编里的 `CSEL X2, _xpc_error_connection_interrupted, _xpc_error_connection_invalid` 才确认）。于是发送方的 `sendMessage` 抛 `connectionInterrupted`，看起来像对端崩溃，真正原因（名字拼错、对端版本没有这个 handler）被掩盖。
3. **Task 里抛出的错误被吞掉。** Swift 6.4 新诊断 `NoUseUnstructuredThrowingTask` 指出 `XPCConnection.swift:554` 的 `Task { … try self.sendOnewayError(…) }` 结果无人接收，回传错误失败时信息直接丢失。这也是当前默认构建唯一的一条警告。
4. **`XPCEndpoint` / `XPCFileDescriptor` 只在容器层被识别。** 编码器只在各容器的 `encode<T>` 里用 `as? XPCEndpoint`、`as? XPCFileDescriptor` 拦截（`Sources/SwiftyXPC/XPCEncoder.swift:113`、`:307`、`:430`），类型自身不参与。一旦中间隔了一层「把 `encode(to:)` 原样转发给内部值」的包装（属性包装器的惯用写法），拦截失效：
   - `XPCEndpoint.encode(to:)` 无条件抛 `CanOnlyBeEncodedByXPCEncoder`，即使编码器就是 `XPCEncoder`。
   - `XPCFileDescriptor` 用的是编译器合成的 Codable，会悄悄把 fd 的**数字**编码过去而不报错；接收端若同样经包装解码，会得到一个「拥有」本进程某个随机 fd 号的对象，析构时 `close()` 掉不相干的描述符。

### 二、被 `@unchecked Sendable` 掩盖的并发问题

这些问题编译器看不见：`XPCConnection` 标了 `@unchecked Sendable`，等于告诉编译器「这里我担保」。

1. **可变状态无锁。** `messageHandlers`、`errorHandler`、`customEventHandler` 是普通可变属性，每条消息都在 `Task {}` 里读取它们；调用方同时在别的线程注册 handler 或改 `errorHandler` 就是数据竞争。
2. **handler 闭包不要求 `@Sendable`。** 它们会被多个 Task 并发调用，捕获的非线程安全状态不会被诊断。
3. **每条消息一个独立 Task。** XPC 保证同一连接上的消息按序送达，但独立 Task 之后 handler 的执行顺序不再有保证；也没有背压和取消传递。
4. **handler 里读到的审计令牌可能属于后续消息。** 逆向确认 libxpc 每收到一条消息就由 `_xpc_connection_set_creds` 用该消息的令牌覆盖连接上缓存的那份（`_xpc_connection_mach_event` 调用，libxpc 3298.1.1）。handler 在 Task 里异步执行，读 `connection.auditToken` 时连接可能已经处理了后面的消息。

### 三、工具链现状

- Xcode 27.2 SDK 的 macOS 最低部署目标是 12.0、Mac Catalyst 是 13.1（`SDKSettings.plist` 的 `SupportedTargets`）。`Package.swift` 声明的 10.15 实际被拉到 12，`checkCallerCredentials` 那条 10.15/11 路径用当前工具链根本编不进去。
- 在 Swift 6 语言模式下，Swift 6.4 编译器编 `XPCEndpoint.swift` 时崩溃（见「前期调研」），所以现在没法升 Swift 6 模式。

### 四、新系统能力没有接入

macOS 14.4 起 XPC 支持按 entitlement、Team ID、平台二进制、LWCR（lightweight code requirement，轻量代码要求）限定对端；macOS 26 起有可组合复用的 `xpc_peer_requirement_t`；macOS 12 起可以用 `xpc_connection_copy_invalidation_reason` 拿到连接失效原因。SwiftyXPC 目前只支持代码签名要求字符串。

## 前期调研

### 构建验证矩阵（Swift 6.4，Xcode 27.2，均未修改源码，经 `-Xswiftc` 传参，覆盖全部 4 个 target）

| 配置 | 结果 |
|------|------|
| 默认 Swift 5 模式 | 通过，1 条警告（`NoUseUnstructuredThrowingTask`） |
| Swift 5 + `-strict-concurrency=complete` | 通过，2 条警告：上面那条，以及 `XPCConnection.swift:135` 把方法引用 `self.handleEvent` 转成 `@Sendable` 闭包 |
| Swift 6 模式 | 编译器崩溃 |
| Swift 5 + 只开 `ImportObjcForwardDeclarations` | 同样崩溃 |
| Swift 5 + 其余 14 个 Swift 6 默认特性 | 通过，1 条警告（`:135` 那条因 SE-0418 消失） |

- 崩溃位置：IRGen 为 `NSObjectProtocol` 懒生成 ObjC 协议元数据时（`emitLazyObjCProtocolDefinition` → `emitObjCProtocolData` → `emitObjCGetterDescriptor`）。触发特性是 SE-0384（`ImportObjcForwardDeclarations`，导入只有前向声明的 ObjC 类型）。**推测**：库不导入 Foundation，`objc/NSObject.h` 里 `description` 等属性的返回类型 `NSString` 只有前向声明，开了该特性后被导入成占位类型，生成 getter 描述时出错。尚未用最小复现验证。
- Swift 6 模式下该特性无法关闭：传 `-disable-upcoming-feature ImportObjcForwardDeclarations` 只得到「already enabled as of the Swift 6 language mode」警告。

### 新特性的版本与运行时要求（来源：Swift Evolution 索引 2026-10-13、Xcode 27.2 SDK 的 swiftinterface）

| 特性 | 编译器 | 运行时 / 系统 | 备注 |
|------|--------|---------------|------|
| SE-0430 `sending` | 6.0 | 无 | Swift 5 模式下可用，严格检查时报警告；对非 library evolution 库无 ABI 影响 |
| SE-0461 `nonisolated(nonsending)` / `@concurrent` | 6.2 | 无 | 默认值由 `NonisolatedNonsendingByDefault`（`MIGRATABLE_UPCOMING_FEATURE`，future 语言模式）切换；ABI 变化只影响 resilient 库 |
| SE-0472 `Task.immediate` | 6.2 | macOS 26 | `@available(anyAppleOS 26.0, *)` |
| SE-0433 `Mutex` | 6.0 | macOS 15 | |
| `DispatchSerialQueue` 作为 `SerialExecutor` | — | macOS 14 | `_DispatchSerialExecutorQueue : SerialExecutor`，`isIsolatingCurrentContext` 需 macOS 26 |
| `SerialExecutor.enqueue(_: UnownedJob)`、`UnownedJob.runSynchronously(on:)` | — | macOS 10.15 | 前者已标 deprecated 但公开可用，后者 `@_alwaysEmitIntoClient` |
| `Actor.assumeIsolated` | — | macOS 10.15 | `@_alwaysEmitIntoClient`，要求返回值 `Sendable` |

### XPC 公开 API 的可用性（来源：Xcode 27.2 SDK `usr/include/xpc/*.h`）

- `xpc_connection_copy_invalidation_reason`：macOS 12 / iOS 15（Catalyst 15）。
- `xpc_connection_set_peer_entitlement_exists_requirement`、`…_entitlement_matches_value_requirement`、`…_team_identity_requirement`、`…_platform_identity_requirement`、`…_lightweight_code_requirement`：macOS 14.4 / iOS 17.4（Catalyst 17.4）。`entitlement_matches_value` 的值只接受 `XPC_TYPE_BOOL`、`XPC_TYPE_STRING`、`XPC_TYPE_INT64`。
- `xpc_peer_requirement_create_*`、`xpc_connection_set_peer_requirement`、`xpc_peer_requirement_match_received_message`：macOS 26。
- `connection.h`：「It is a programming error to call multiple of the `xpc_connection_set_peer_*_requirement` family of functions on the same connection」—— 一个连接只能设一个校验条件；C 层没有与/或组合函数，组合只能写进代码签名要求字符串或 LWCR 字典。

### 私有 API（逆向结论，libxpc 3298.1.1 / macOS 27.0；与本机 27.2 的 3298.40.20 导出表只差一个无关符号）

- `void xpc_dictionary_get_audit_token(xpc_object_t message, audit_token_t *out)`：读取收到的这条消息附带的审计令牌；本地创建的字典得到全 `0xFF`、pid 为 0 的无效令牌；传入非字典会以 API misuse 崩溃。
- `void xpc_connection_get_audit_token(xpc_connection_t, audit_token_t *)`（库中已在用）：返回连接上缓存的、最近一条消息的令牌。
- 审计令牌字段按 libbsm 的约定解析：`val[1]` euid、`val[2]` egid、`val[5]` pid、`val[6]` asid（Apple 的 Swift overlay 也按此读取，见下）。

### Apple 自己的 Swift 封装（libswiftXPC 167.0.2，导出在 `/Volumes/DyldSharedCaches/macOS/27.2/libswiftXPC/`）

- handler 同步执行在 session 的队列上，返回值即回复；只在 `xpc_dictionary_expects_reply` 为真时才回复。
- 解码失败、同步消息未回复时，主动回一个只带 `_CodableError` 字符串的字典，发送方得到 `XPCRichError`，绝不让发送方空等或误判。
- `XPCCodableObject.encode(to:)` 由类型自己从 `encoder.userInfo[.xpcCodable]` 取出旁路数组、放入原始 XPC 对象、只编码下标；用在别的编码器上则抛 `CodingUserInfoKeyNotFound`。本提案的「XPC 对象自己配合编码器」即借鉴于此。
- 其消息体是一整块二进制（`_CodableBody`），本提案**不**借鉴这一点（见「替代方案考量」）。

### 依赖方（2026-10-13 检索 `/Volumes/Repositories`）

RuntimeViewer、LookInside、swift-helper-service、MachInjector、ReverseEngineeringToolbox、FinderSidebarIconFix、DockIconOverride 共 7 个项目依赖本 fork，均按版本号解析（锁定在 0.5.104 / 0.5.105）。swift-helper-service 写的是 `from: "0.5.104"`，即 `0.5.104..<1.0.0`，并声明 `.macOS(.v10_15), .macCatalyst(.v13)`。

## 提议方案

1. **工具链与平台**：`swift-tools-version:6.2`；`platforms: [.macOS(.v12), .macCatalyst(.v15)]`；删除 macOS 10.15/11 专用代码路径。语言模式优先 Swift 6（先绕开编译器崩溃）；绕不开则 Swift 5 + 除 `ImportObjcForwardDeclarations` 外的全部 Swift 6 特性。两种情况都打开 `NonisolatedNonsendingByDefault`。
2. **消息派发**：每个连接一个串行执行器，handler 按到达顺序启动、在 `await` 处可交错（与 XPC / `NSXPCConnection` 语义一致）。macOS 14+ 用 `DispatchSerialQueue`，12–13 用自写 `SerialExecutor`，26+ 用 `Task.immediate` 省掉一次排队。
3. **线程安全**：连接与 listener 的可变状态由内部锁保护（macOS 15+ `Mutex`，以下 `os_unfair_lock`）；activate 之后仍允许注册 handler。`XPCListener`、`XPCFileDescriptor` 改为 `Sendable`。
4. **公开 API**：handler 统一为 `@Sendable (XPCMessageContext, sending Request) async throws -> sending Response`；发送接口为 `nonisolated(nonsending)`、返回 `sending Response`，请求只要求 `Encodable`、响应只要求 `Decodable`；`ErrorHandler` 改为 `@Sendable`。
5. **缺陷修复**：单向消息不再回发任何东西，其 handler 的错误交给接收方本地 `errorHandler`；对在等回复的未知 / 缺名消息回复 `XPCConnection.Error.unexpectedMessage` / `.missingMessageName`；不再吞掉任何错误；XPC 对象由类型自己配合编码器。
6. **新能力**：`XPCPeerRequirement`（代码签名要求 + 14.4 起的细粒度条件，26 起用 `xpc_peer_requirement_t` 实现）；`XPCMessageContext`（含每条消息自己的审计令牌、26 起的 `senderSatisfies(_:)`）；`XPCError.connectionInvalid(reason:)`；公开协议 `XPCObjectRepresentable`；可选的协议版本号字段。
7. **测试与文档**：测试迁移到 Swift Testing，每个缺陷先有一个修复前失败的回归测试；更新 README、`CLAUDE.md`、Example App。

### 非目标

- 不改用 `xpc_session_t` / `xpc_listener_t` 作为底层（macOS 12 仍需要基于 connection 的实现，等于维护两套）。
- 不改消息格式：`name` / `body` / `error` 三个键及其编码保持不变，只新增一个可选的版本键。
- 不引入 Foundation，不改二进制消息体，不开启 library evolution。
- 不让 handler 跟随自身隔离（不做 `@isolated(any)` handler）。
- 不在 macOS 12–14.3 上模拟细粒度对端校验。
- 不在本次迁移 7 个依赖方；它们停留在 0.5.x，按需手动升级到 1.0。
- 不推送、不打 tag，除非用户点名。

## 详细设计

### Package.swift

```swift
// swift-tools-version:6.2
import PackageDescription

let concurrencySettings: [SwiftSetting] = [
    .enableUpcomingFeature("NonisolatedNonsendingByDefault")
]

let package = Package(
    name: "SwiftyXPC",
    platforms: [
        .macOS(.v12),
        .macCatalyst(.v15),
    ],
    products: [
        .library(name: "SwiftyXPC", targets: ["SwiftyXPC"])
    ],
    targets: [
        .target(name: "SwiftyXPC", swiftSettings: concurrencySettings),
        .target(name: "TestShared", dependencies: ["SwiftyXPC"], swiftSettings: concurrencySettings),
        .executableTarget(
            name: "TestHelper",
            dependencies: ["SwiftyXPC", "TestShared"],
            swiftSettings: concurrencySettings
        ),
        .testTarget(
            name: "SwiftyXPCTests",
            dependencies: ["SwiftyXPC", "TestHelper", "TestShared"],
            swiftSettings: concurrencySettings
        ),
    ],
    swiftLanguageModes: [.v6]
)
```

退路（Swift 6 模式绕不开崩溃时）：`swiftLanguageModes: [.v5]`，`concurrencySettings` 追加 `StrictConcurrency`、`ConciseMagicFile`、`ForwardTrailingClosures`、`BareSlashRegexLiterals`、`DeprecateApplicationMain`、`DisableOutwardActorInference`、`IsolatedDefaultValues`、`GlobalConcurrency`、`InferSendableFromCaptures`、`ImplicitOpenExistentials`、`RegionBasedIsolation`、`DynamicActorIsolation`、`NonfrozenEnumExhaustivity`、`GlobalActorIsolatedTypesUsability`。

### 消息上下文

```swift
/// Information about the message that a handler is currently processing.
public struct XPCMessageContext: @unchecked Sendable {
    /// The connection on which the message arrived.
    public let connection: XPCConnection
    /// The name the sender attached to the message.
    public let messageName: String
    /// The audit token of the process that sent this particular message.
    public let auditToken: audit_token_t
    /// Whether the sender is waiting for a reply.
    public let expectsReply: Bool

    /// The process identifier of the sender, read from `auditToken`.
    public var processIdentifier: pid_t { get }
    /// The effective user identifier of the sender, read from `auditToken`.
    public var effectiveUserIdentifier: uid_t { get }
    /// The effective group identifier of the sender, read from `auditToken`.
    public var effectiveGroupIdentifier: gid_t { get }
    /// The audit session identifier of the sender, read from `auditToken`.
    public var auditSessionIdentifier: au_asid_t { get }

    /// Returns whether the sender of this message satisfies `requirement`.
    @available(macOS 26.0, macCatalyst 26.0, *)
    public func senderSatisfies(_ requirement: XPCPeerRequirement) throws -> Bool
}
```

`@unchecked Sendable` 是因为它私下持有原始消息（`xpc_object_t`，供 `senderSatisfies` 调用 `xpc_peer_requirement_match_received_message`）；XPC 对象的线程安全由 libxpc 保证。`auditToken` 在消息到达时用 `xpc_dictionary_get_audit_token` 取得。

### handler 注册（`XPCConnection` 与 `XPCListener` 相同）

```swift
public func setMessageHandler(
    name: String,
    handler: @escaping @Sendable (XPCMessageContext) async throws -> Void
)

public func setMessageHandler<Request: Decodable>(
    name: String,
    handler: @escaping @Sendable (XPCMessageContext, sending Request) async throws -> Void
)

public func setMessageHandler<Response: Encodable>(
    name: String,
    handler: @escaping @Sendable (XPCMessageContext) async throws -> sending Response
)

public func setMessageHandler<Request: Decodable, Response: Encodable>(
    name: String,
    handler: @escaping @Sendable (XPCMessageContext, sending Request) async throws -> sending Response
)
```

- 打开 `NonisolatedNonsendingByDefault` 后，这些闭包默认在调用方（即连接的串行执行器）上运行；调用方传入 `@concurrent` 闭包时也安全，因为请求以 `sending` 交出、响应以 `sending` 交回。
- 请求是解码出来的新值，天然处于独立区域，所以可以 `sending` 交给 handler；响应在交回后立即编码，不需要 `Sendable`。

### 发送

```swift
public nonisolated(nonsending) func sendMessage(name: String) async throws
public nonisolated(nonsending) func sendMessage(name: String, request: some Encodable) async throws
public nonisolated(nonsending) func sendMessage<Response: Decodable>(name: String) async throws -> sending Response
public nonisolated(nonsending) func sendMessage<Response: Decodable>(
    name: String,
    request: some Encodable
) async throws -> sending Response

public func sendOnewayMessage(name: String, message: some Encodable) throws
```

- `nonisolated(nonsending)` 让编码发生在调用方的隔离域里，actor 内部可以直接传非 `Sendable` 的请求。
- 响应在 reply handler 里解码成新值，经 `withCheckedThrowingContinuation` 以 `sending` 交回调用方，因此不再要求 `Response: Sendable`。
- `sendOnewayMessage` 的 `name` 改为必填：没有 name 的消息接收方无法路由，只会报错。

### 错误处理

```swift
public typealias ErrorHandler = @Sendable (XPCConnection, any Error) -> Void

public enum XPCError: Error, Codable, Sendable {
    case connectionInterrupted
    /// `reason` comes from `xpc_connection_copy_invalidation_reason` when available.
    case connectionInvalid(reason: String?)
    case terminationImminent
    case invalidCodeSignatureRequirement
    /// A requirement other than a code signing requirement was rejected by XPC.
    case invalidPeerRequirement
    case unknown(String)
}
```

`connectionInvalid` 增加关联值后与 0.5.x 仍互通：合成的 Codable 对无关联值的 case 只取嵌套容器、不读键，旧版解码新格式时忽略 `reason`；新版用可选值解码旧格式得到 `nil`。落地时用测试双向验证。

### 对端校验

```swift
/// A requirement that the process on the other end of a connection must satisfy.
public struct XPCPeerRequirement: Sendable {
    /// A code signing requirement string, such as `anchor apple generic and identifier "com.example.helper"`.
    public static func codeSigning(_ requirement: String) -> XPCPeerRequirement

    @available(macOS 14.4, macCatalyst 17.4, *)
    public static func hasEntitlement(_ entitlement: String) -> XPCPeerRequirement

    @available(macOS 14.4, macCatalyst 17.4, *)
    public static func entitlement(_ entitlement: String, matches value: Bool) -> XPCPeerRequirement

    @available(macOS 14.4, macCatalyst 17.4, *)
    public static func entitlement(_ entitlement: String, matches value: String) -> XPCPeerRequirement

    @available(macOS 14.4, macCatalyst 17.4, *)
    public static func entitlement(_ entitlement: String, matches value: Int64) -> XPCPeerRequirement

    @available(macOS 14.4, macCatalyst 17.4, *)
    public static func isFromSameTeam(andMatchesSigningIdentifier signingIdentifier: String? = nil) -> XPCPeerRequirement

    @available(macOS 14.4, macCatalyst 17.4, *)
    public static func isPlatformCode(andMatchesSigningIdentifier signingIdentifier: String? = nil) -> XPCPeerRequirement

    /// A lightweight code requirement dictionary, which can combine several constraints.
    @available(macOS 14.4, macCatalyst 17.4, *)
    public static func lightweightCodeRequirement(_ requirement: xpc_object_t) -> XPCPeerRequirement
}

extension XPCConnection {
    public convenience init(type: ConnectionType, requirement: XPCPeerRequirement? = nil) throws
}

extension XPCListener {
    public convenience init(type: ListenerType, requirement: XPCPeerRequirement? = nil) throws
}
```

- 命名与 Apple Swift overlay 的 `XPCPeerRequirement` 一致。
- 版本限制放在工厂方法上，而不是带 `@available` 的枚举 case：带关联值的枚举 case 不能标为「可能不可用」。
- 内部实现：macOS 26+ 一律构造 `xpc_peer_requirement_t` 并调用 `xpc_connection_set_peer_requirement`；14.4–25 调用对应的 `xpc_connection_set_peer_*_requirement`；代码签名要求在 12+ 调用 `xpc_connection_set_peer_code_signing_requirement`。
- 每个连接只接受一个条件，组合条件请写进代码签名要求字符串或 LWCR。

### 携带任意 XPC 对象

```swift
/// A type whose values travel inside Codable messages as raw XPC objects.
public protocol XPCObjectRepresentable: Codable {
    /// The XPC type of the objects that represent values of this type.
    static var xpcType: XPCType { get }
    /// Creates a value from an XPC object whose type is `xpcType`.
    init(xpcObject: xpc_object_t) throws
    /// Returns an XPC object that represents this value.
    func makeXPCObject() throws -> xpc_object_t
}

extension XPCObjectRepresentable {
    public init(from decoder: any Decoder) throws
    public func encode(to encoder: any Encoder) throws
}

extension XPCEndpoint: XPCObjectRepresentable {}
extension XPCFileDescriptor: XPCObjectRepresentable {}
```

- 默认的 `encode(to:)` / `init(from:)` 识别 SwiftyXPC 内部的编码器 / 解码器，直接写入 / 读出原始对象；遇到其他编码器（例如 `JSONEncoder`）一律抛错。因此无论值经过多少层转发包装都能正确往返。
- 编码器、解码器里写死的 `XPCEndpoint` / `XPCFileDescriptor` 判断改为对 `any XPCObjectRepresentable` 的判断；`FileDescriptor`（System）仍按现有方式特判。
- `XPCFileDescriptor` 保持「拥有并在析构时关闭」的语义，改为 `Sendable`；删除只为 10.15 存在的分支。

### 消息派发（内部）

```swift
/// Starts handlers for one connection, in the order their messages arrive.
internal actor MessageDispatcher {
    nonisolated let queue: DispatchQueue
    nonisolated var unownedExecutor: UnownedSerialExecutor { get }
}
```

1. 连接创建时调用 `xpc_connection_set_target_queue(connection, dispatcher.queue)`，事件处理与 handler 启动都在这条串行队列上。
2. 事件处理器（已在该队列上）通过 `dispatcher.assumeIsolated { … }` 进入 actor 隔离，按到达顺序为每条消息创建继承隔离的 `Task`；macOS 26+ 用 `Task.immediate` 直接在当前队列上开始执行。
3. `unownedExecutor`：macOS 14+ 返回 `DispatchSerialQueue` 自身的执行器；12–13 返回一个把 `UnownedJob` 投递到同一队列、再以 `runSynchronously(on:)` 执行的自写 `SerialExecutor`。
4. handler 结束后：消息在等回复则回复（成功发 body，失败发 error）；否则成功时什么都不发，失败时交给本地 `errorHandler`。

### 协议版本号

新增可选键 `com.charlessoft.SwiftyXPC.XPCEventHandler.ProtocolVersion`，值为 `int64` 1。发送时总是写入；接收时不要求它存在、也不据此拒绝消息，只作为日后格式演进的判断依据。

### 私有 API 的组织

所有 `@_silgen_name` 声明集中到 `Sources/SwiftyXPC/PrivateXPCInterfaces.swift`，每个声明注明签名来源、用途和验证所用的系统版本。本次新增 `xpc_dictionary_get_audit_token`。

## 替代方案考量

- **部署目标升到 macOS 14 或 15**：可以少写一套执行器或锁的回退实现，但要求所有依赖方同步提高部署目标。否决：用可用性判断即可在 12 上享受新系统能力。
- **保持 10.15 声明**：用 Xcode 27 构建时这些代码路径本来就编不进去，保留只增加维护负担。否决。
- **严格串行执行 handler**：实现最简单，但一个慢请求会堵住同一连接的所有后续消息。否决。
- **保持完全并发、只补文档**：与 XPC 按序送达的语义相悖，也解决不了状态竞争。否决。
- **handler 跟随自身隔离（`@isolated(any)`）**：`@MainActor` handler 可直接在主线程运行，但同一连接的消息会分散到不同执行器，顺序只在同一隔离域内成立，实现复杂得多。否决。
- **发 0.6.0 并同步迁移 7 个依赖方**：没有版本分叉，但工作量大且会把依赖方的迁移绑进本次改动。否决，改为 1.0.0 让依赖方按需升级。
- **保持源码兼容（新旧 API 并存）**：不破坏任何人，但旧的非 `@Sendable` handler 签名无法安全保留——保留它就保留了数据竞争。否决。
- **不保证与 0.5.x 互通**：可以自由重设消息格式，但特权 helper 常常和主 App 分开更新，两端必须同时升级不现实。否决。
- **用 task-local 提供消息上下文**：签名不变，但不显眼、容易被忽略。否决。
- **单向消息的错误发回发送方 / 两边都给**：前者是当前（有缺陷的）行为的延续；后者让单向消息仍然产生回程流量。否决。
- **细粒度校验在旧系统上运行时抛错或自行校验**：前者把编译期能发现的问题推迟到运行时；后者要在 12–14.3 上用私有 API 重写一遍签名校验。否决。
- **不新增私有 API**：则无法提供逐条消息的审计令牌（macOS 26 前没有公开途径）。否决。
- **借鉴 Apple overlay 的二进制消息体**：零拷贝、一次分配，但对端只能是同样理解该格式的进程，`xpc_copy_description` 也看不到字段，且破坏与 0.5.x 的互通。否决；字节数组已打包为单个 `xpc_data`（`XPCEncoder.swift:377`），主要的性能场景已覆盖。
- **底层改用 session / listener 新 API**：见「非目标」。否决。

## 影响

### 源码兼容性（source compatibility）

**有破坏。** 需要修改的调用点：

| 改前 | 改后 |
|------|------|
| `XPCConnection(type: t, codeSigningRequirement: s)` | `XPCConnection(type: t, requirement: .codeSigning(s))`（旧签名保留一个版本，标 deprecated） |
| `XPCListener(type: t, codeSigningRequirement: s)` | `XPCListener(type: t, requirement: .codeSigning(s))`（同上） |
| `setMessageHandler(name:) { (connection: XPCConnection, request: R) in … }` | `setMessageHandler(name:) { (context: XPCMessageContext, request: R) in … }`，需要连接时用 `context.connection` |
| handler 闭包捕获非 `Sendable` 状态 | 必须改为 `Sendable` 的捕获（Swift 6 调用方会得到编译错误，这正是要暴露的数据竞争） |
| `errorHandler = { connection, error in … }` 捕获非 `Sendable` 状态 | 同上 |
| `sendOnewayMessage(message: m, name: n)` | `sendOnewayMessage(name: n, message: m)` |
| `sendOnewayMessage(name: nil, message: m)` | `name` 必填 |
| `case .connectionInvalid` 模式匹配 | `case .connectionInvalid` 仍可匹配；需要原因时用 `case .connectionInvalid(let reason)` |
| 依赖 `XPCFileDescriptor` 经非 XPC 编码器「成功」编码的代码 | 现在会抛错（原行为是缺陷） |

handler 签名的变化无法用 `@available(*, deprecated, renamed:)` 平滑过渡：旧签名的闭包不是 `@Sendable`，保留它就保留了数据竞争。

### ABI 兼容性

不适用 —— 本库以 SPM 源码分发，使用方每次重新编译。

### 下游影响

- 本仓库内：`TestShared`、`TestHelper`、`SwiftyXPCTests`、`Example App`（独立 Xcode 项目，含 `MessageSender.swift`、`XPCService.swift`）都要按新 API 修改。
- 下游仓库：RuntimeViewer、LookInside、swift-helper-service、MachInjector、ReverseEngineeringToolbox、FinderSidebarIconFix、DockIconOverride。由于发布为 1.0.0，它们在手动修改依赖声明前停留在 0.5.x，不会被自动拉入破坏性改动；升级时需要把自己的部署目标提到 macOS 12 / Catalyst 15，并完成上表中的修改。
- 线上：1.0 与 0.5.x 对端互通。行为差异只有两点：0.5.x 发送方向 1.0 接收方发单向消息时，不再收到对端 handler 的错误；向 1.0 接收方发送未知消息名时，收到 `unexpectedMessage` 而不是 `connectionInterrupted`。

### 文档与示例

- `README.md`（英文）：1.0 的 API、并发语义（按序启动、handler 运行位置）、对端校验、0.5 → 1.0 迁移说明。
- `CLAUDE.md`：tools 版本、部署目标、派发架构、私有 API 文件、测试框架。
- Example App 改用新 API；`MessageSender` 改用 `activate()`。

## API 演进与废弃策略

- `init(type:codeSigningRequirement:)`（连接与 listener）：标 `@available(*, deprecated, renamed: "init(type:requirement:)")` 保留整个 1.x，2.0 删除。
- `sendOnewayMessage(message:name:)`：0.5.x 已标 deprecated，1.0 直接删除。
- 旧的 `(XPCConnection, Request)` handler 签名：1.0 直接删除，理由见上。
- 需要 semver major 跃迁：发布为 1.0.0。

## 落地步骤

每一步都能单独构建通过；修缺陷的步骤先提交失败的回归测试，再提交修复。

1. 提案与文档目录（本文件、`Documentations/README.md`、`Documentations/Evolutions/README.md`）。
2. 测试迁移到 Swift Testing，行为不变（动手前先读 Apple 官方的 `modernize-tests` skill）。
3. 缺陷回归测试与修复：单向消息不回发、未知 / 缺名消息回复错误、Task 不吞错、XPC 对象自身配合编码（含 `XPCObjectRepresentable`）。
4. `Package.swift`：tools 6.2、macOS 12 / Catalyst 15、并发设置；删除 10.15/11 路径与 `XPCErrorRegistry` 的旧锁实现，改用共享的内部锁。
5. 可变状态加锁，`XPCListener` / `XPCFileDescriptor` 的 `Sendable` 化。
6. 每连接串行执行器与按序派发；新的 handler、发送、错误处理 API；`XPCMessageContext`（含私有 API 文件）。
7. `XPCPeerRequirement` 与 `XPCError.connectionInvalid(reason:)`。
8. 可选的协议版本号字段，以及与 0.5.x 互通的验证（用 0.5.105 构建一个对端做双向测试）。
9. Swift 6 模式：最小复现编译器崩溃（复现代码先给用户过目再运行），找到触发写法并改写；成功则 `swiftLanguageModes: [.v6]`，否则采用退路配置。是否向 swiftlang/swift 提交 issue 由用户决定。
10. Example App、README、`CLAUDE.md` 更新；判断是否需要使用指南（并发语义与对端校验很可能是「签名里看不出的契约」）与实现说明（派发执行器的选择）；判断是否需要术语表。

**收尾时必须判断两件事**（判断结果写进决策日志，不允许沉默跳过）：

- **要不要配套专题文章** —— 有「从 API 签名看不出来的调用方契约」就写使用指南；有「下次维护会踩、
  代码本身看不出来的决策」就写实现说明。写了就登记到头部的「配套文档」。
- **有没有引入新术语** —— 有就同批次登记进术语表（项目级 `Documentations/Glossary.md`，
  跨项目通用的登记到全局术语表）。

## 决策日志

| 日期 | 变更 | 说明 |
|------|------|------|
| 2026-10-13 | Created as Draft | 用户原始描述：「潜在的Bug也要修，还要结合最新的特性，例如sending」；此前用户选定「Swift 5 + 完整并发检查」作为起点 |
| 2026-10-13 | 定为完整档 | 包含破坏性 API 改动、派发模型变更与工具链升级；经三轮澄清提问后由用户确认共识 |
| 2026-10-13 | 工具链 Swift 6.2 / Xcode 26 | 用户选择。否决 Swift 6.0 / Xcode 16：拿不到 `nonisolated(nonsending)` |
| 2026-10-13 | 部署目标 macOS 12，新系统能力加可用性判断使用 | 用户选择（「macOS 12 + macOS 14，新版本的功能也要加」）。否决 14、15、保持 10.15 |
| 2026-10-13 | handler 按到达顺序启动、`await` 处可交错 | 用户选择。否决严格串行、保持完全并发 |
| 2026-10-13 | 发布 1.0.0，允许破坏性改动 | 用户选择。否决 0.6.0 并迁移依赖方、保持源码兼容 |
| 2026-10-13 | 新公开能力：细粒度对端校验、连接失效原因 | 用户选择。否决底层改用 session / listener API |
| 2026-10-13 | handler 在连接的串行执行器上运行，要求 `@Sendable` | 用户选择。否决 `@isolated(any)` 跟随 handler 隔离 |
| 2026-10-13 | 与 0.5.x 线上互通 | 用户选择。否决不保证互通 |
| 2026-10-13 | handler 首参改为 `XPCMessageContext` | 用户选择。否决 task-local、不做 |
| 2026-10-13 | 单向消息的错误交给接收方本地 `errorHandler` | 用户选择。否决发回发送方、两边都给 |
| 2026-10-13 | 细粒度校验用 `@available(macOS 14.4, *)` 在编译期限制 | 用户选择。否决运行时抛错、旧系统自行校验 |
| 2026-10-13 | 允许新增读取身份信息的私有 API | 用户选择。否决不新增 |
| 2026-10-13 | 附加范围：`XPCObjectRepresentable`、绕开编译器崩溃并切 Swift 6、测试迁移到 Swift Testing、可选协议版本号 | 用户全选 |
| 2026-10-13 | 技术细节经用户确认 | Catalyst 15；删除 10.15/11 路径；退路特性组合加 `NonisolatedNonsendingByDefault`；锁（15+ `Mutex`）；执行器（14+ `DispatchSerialQueue`、12–13 自写、26+ `Task.immediate`）；发送接口 `nonisolated(nonsending)` + `sending`；`ErrorHandler` `@Sendable`；每连接一个校验条件；`connectionInvalid(reason:)`；`XPCFileDescriptor` `Sendable`；删除已废弃的 `sendOnewayMessage(message:name:)`；私有 API 集中到一个文件；README / `CLAUDE.md` / Example App 同步；在 worktree `.worktrees/SwiftyXPC-Concurrency` 的 `feature/swift-concurrency-1.0` 分支上开发，不经点名不推送、不打 tag |
| 2026-10-14 | Accepted | 用户批准开工：「开工写完直接提交推送」；推送功能分支由此获得授权，打 tag 仍需另行点名 |
| 2026-10-14 | 库 target 采用语言模式退路 | Swift 6 模式的编译器崩溃无法局部绕开：本模块不导入 Foundation 时，任何需要 XPC 对象类型元数据的写法（存储属性、enum 关联值、数组、泛型实参、`as?`）都会触发，探针结果记在实现说明决策六。库 target 用 Swift 5 + 除 `ImportObjcForwardDeclarations` 外的全部 Swift 6 特性；测试、helper、共享测试代码导入 Foundation，用 Swift 6 模式；所有 target 打开 `NonisolatedNonsendingByDefault`。是否向 swiftlang/swift 报告仍由用户决定 |
| 2026-10-14 | 派发不用 `assumeIsolated` | 查证 Swift 5.10 运行时：macOS 15 前在 dispatch block 里判断 actor 隔离会 trap。改为加锁 FIFO + 部分应用 `self.startOldestJob` 创建隔离任务、弹出最旧的 job；26+ 仍用 `Task.immediate`。新增内部 `MessageDispatcher.Strategy`，测试在本机覆盖 macOS 12–13 与 14–25 的路径；变异检查（后进先出、严格串行）确认测试能抓到问题 |
| 2026-10-14 | handler 返回值不标 `sending`，泛型参数加 `SendableMetatype` | Swift 6.4 拒绝把方法引用（`handler: self.sayHello`）转换成返回 `sending` 值的函数类型，即使返回类型是 `Sendable`。handler 默认在连接的执行器上运行，响应在同一处编码，去掉后仍安全。handler 闭包在连接执行器上用到 `Request.self` / `Response.self`，SE-0470 要求 `SendableMetatype` |
| 2026-10-14 | `sendMessage` 在调用方解码回复 | 原定在回复处理块里解码，会迫使 `Response` 满足 `SendableMetatype`；改为把原始回复交回调用方再解码。`XPCDecoder.decode` 返回 `sending T` |
| 2026-10-14 | 对端校验统一用 14.4 的公开 setter；`senderSatisfies` 用 `dlsym` | `xpc_connection_set_peer_requirement` 与 `xpc_peer_requirement_*` 在 SDK 中对 Swift 隐藏（`XPC_SWIFT_NOEXPORT`），且 26 前不存在，`@_silgen_name` 强引用会让库在 12–25 无法加载。代码签名要求的逐条消息校验用 Security。`xpc_dictionary_get_audit_token` 在 macOS 12.0.1 / 13.0 的 shared cache 中确认存在 |
| 2026-10-14 | listener 与已接受连接共享 handler 表 | 替代接受连接时拷贝与匿名 listener 的 `isMulti` 特例：listener 上后设的 handler 对已连上的对端也生效 |
| 2026-10-14 | `XPCNull` 也遵循 `XPCObjectRepresentable` | 三种以 XPC 对象本身传输的值统一走一个协议，编解码器少一处特判 |
| 2026-10-14 | 落地顺序调整 | 先升平台（步骤 4）再修缺陷（步骤 3），避免为 macOS 10.15 / 11 再写一套修复；缺陷回归测试仍先于修复提交（`withKnownIssue` 证明能复现，会崩溃的单独运行确认） |
| 2026-10-14 | 提案外的缺陷一并修复 | 解码器在对端可控输入上的三处 trap、`decodeNil()` 语义、第二次请求容器的前置条件崩溃、`superEncoder()` / `superDecoder(forKey:)`、`XPCEncoder(replyingTo:)` 必崩、错误负载解不出时整体失败、端点 / bundle 连接遇到非法签名要求时崩溃、`XPC_TYPE_SHMEM` 映射。每项先在旧代码上确认失败或崩溃，清单见实现说明 |
| 2026-10-14 | 与 0.5.105 互通验证通过 | 两个方向各 8 项检查全部通过（macOS 27.2）。验证程序与步骤提交到 `Tests/Interop/`；`WireCompatibilityTests` 用 C API 模拟 0.5 对端做常驻测试。1.0 发送方静默丢弃 0.5 接收方对单向消息的多余回复 |
| 2026-10-14 | Example App 改为本地包引用并升 Swift 6 模式 | 原工程远程引用上游 CharlesJS/SwiftyXPC，从未编译本仓库代码；改为 `relativePath = ..`。Swift 5 模式下方法引用不会被推断为 `@Sendable`，示例改用 Swift 6 模式后零警告 |
| 2026-10-14 | 配套文档与术语表的判断 | 写实现说明（下次维护会踩、代码看不出的决策：派发、语言模式、对端校验的接入方式、0.5 兼容规则，以及与提案的差异）。不另写使用指南：调用方契约（handler 的运行方式、对端校验、与 0.5 对端互通）写进公开的 README，避免两处权威。新建项目术语表，登记 6 个术语 |
| 2026-10-14 | In Progress | 实现全部完成并推送到功能分支 `feature/swift-concurrency-1.0`；合入 main 时分配提案编号并置为 Implemented |
