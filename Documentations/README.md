# SwiftyXPC 文档索引

本目录存放 SwiftyXPC 的内部文档。面向使用者的说明见仓库根目录的 `README.md`。

## Evolutions —— 改动提案

每一次实质性改动对应一份提案，状态表见 [Evolutions/README.md](Evolutions/README.md)。

| 文档 | 摘要 |
|------|------|
| [Swift Concurrency 现代化与 1.0 缺陷修复](Evolutions/draft-swift-concurrency-1-0.md) | 修复消息回复与编码相关的缺陷，按 Swift 6 并发模型重做消息派发与公开 API，并接入新系统的 XPC 能力，以 1.0.0 发布 |

## Internal —— 实现说明

面向维护者：最终怎么建成的、为什么这样建、与提案的差异、已知降级。

| 文档 | 摘要 |
|------|------|
| [SwiftyXPC 1.0：实现说明](Internal/Version1Implementation.md) | 每连接串行派发与按到达顺序启动、库 target 的语言模式、对端校验的接入方式、与 0.5 互通的规则，以及与提案的差异 |

## 术语表

[术语表](Glossary.md) 收录本项目的专有名词：按到达顺序启动、派发策略、LWCR、协议版本号、0.5 多余回复、线上互通。

## 其他

| 文档 | 摘要 |
|------|------|
| [Tests/Interop/README.md](../Tests/Interop/README.md) | 用 0.5.105 与当前版本互为对端、端到端验证线上互通的步骤 |
