# 贡献指南

感谢您对 JsonData 产生兴趣并有意愿为其贡献代码！为了让项目始终保持极高的代码质量与一致性，请在发起 PR 之前仔细阅读以下要求和规范。

## 核心指导原则

JsonData 的诞生是为了给全平台 Swift 生态提供一份真正等价于 Apple **SwiftData** 的体验。因此，所有的代码改动和新增特性都必须牢记这一终极目标。

1. **绝对对齐 SwiftData**  
   任何新增特性的 **心智模型** 与 **Public API** 设计，都**必须 100% 严格对齐 SwiftData**。我们需要确保开发者能够零成本从 SwiftData 迁移过来。除非是因为底层依赖（如 GRDB 或跨平台限制）引发的极特殊情况，经讨论认定需要实施的变通办法外，其余情况不可随意发明新的 API 或背离 SwiftData 的用法。
   
2. **纯正的 Apple Swift 风格**  
   所有代码的拼写、缩进、命名规范与抽象逻辑，必须 100% 遵守现代且最佳的 Apple Swift 编码风格。请充分利用 Swift 6+ 的现代特性（如 Macros、Concurrency 等）进行优雅实现。

## 提交代码与 PR 规范

为了降低沟通成本并优化代码审查体验，我们对代码提交的流程有如下要求：

### 1. 强制使用中文进行沟通
- 所有的 **PR 标题与描述** 必须使用 **中文** 进行编写，以便核心维护团队能够快速理解并推进代码审查进程。
- 在描述中，请清晰地指出解决的问题、变更的原因以及与 SwiftData 原始设计的比对说明。

### 2. Git 提交记录 (Commit History) 要求
- 允许使用 AI 来自动生成你的 git commit message。
- 在 commit message 中允许出现英文（或其他 AI 生成时的语言混入），但建议尽量保持简洁清晰的格式。

### 3. AI 辅助编程政策
- **我们完全开放并拥抱 AI 工具辅助编写代码**。
- **但请注意** 即使代码由 AI 辅助生成，贡献者本人也**必须经过严谨的人工审核** 才能提交。任何未经思考直接丢过来的“AI 幻觉”代码或带有大段无关死代码的 PR 将会被直接拒绝。
- 请务必在本地环境（包括但不限于在物理机或容器中测试）中跑通 `swift test`，确保不会破坏跨平台构建环境。
- 任何新增的 API **必须补充测试**，必须确保在 macOS、Linux、Win 中测试结果一致。

## 开发流程建议

1. Fork 本仓库并 Clone 到您的本地机器。
2. 切出一个具有描述性名称的分支（如 `feature/predicate-support`，`fix/cascade-delete-bug`）。
3. 确保您了解我们要修改的代码主要是存放于 `Sources/JsonDataCore` 中。
4. 编写并运行相关的 `XCTest` 用例：
   ```zsh
   # 在 macOS 测试
   swift test
   
   # 在 Linux 容器中测试 (如果使用 orb)
   orb -m debian swift test
   ```
5. Commit 改动并提交 PR。

我导出了 SwiftData 的 API，可以查看 SwiftData.swiftinterface.txt

感谢您为构建跨平台 Swift 繁荣生态做出的贡献！我们期待您的代码。
