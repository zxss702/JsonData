
# 决策记录

## 2026-02-26：移除 SwiftCrossUI 依赖
- **主题**：移除 JsonData 项目对 SwiftCrossUI 的依赖
- **结论**：完全移除 SwiftCrossUI 依赖，Query 模块暂时注释待后续重新实现
- **背景**：需要简化项目依赖
- **理由**：SwiftCrossUI 不是核心功能必需
- **影响范围**：
  - Package.swift/Package.resolved：移除依赖项
  - JsonData.swift：移除环境键、ObservableObject 继承
  - ModelContainer.swift：移除视图修饰符
  - Query.swift：暂时注释实现
  - JsonDataMacros.swift：移除 ObservableObject 协议生成
- **后续动作**：重新实现 Query 模块，不依赖 SwiftCrossUI
