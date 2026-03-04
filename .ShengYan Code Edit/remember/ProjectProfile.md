
# 项目/仓库画像

## 仓库基线信息
- **技术栈**：Swift 6.1
- **平台要求**：macOS 13+
- **构建与依赖管理**：Swift Package Manager (SPM)
- **核心依赖**：`swift-syntax` 601.0.0+（宏实现）

## 项目定位
轻量级本地数据持久化库，API 设计参考 SwiftData，底层使用 JSON 文件存储替代 Core Data。核心特性包括延迟加载（Faulting）、Identity Map 缓存、编译时代码生成（宏）。

## 目录职责映射
```
Sources/
├── JsonData/           # 运行时库
│   ├── JsonData.swift       # PersistentModel 协议、@Field 属性包装器
│   ├── ModelContainer.swift # 容器管理（Schema + 主上下文）
│   ├── ModelContext.swift   # 上下文/CRUD/Identity Map 缓存
│   └── Query.swift          # 已注释（原 SwiftCrossUI 集成模块）
└── JsonDataMacros/     # 编译时宏实现
    └── JsonDataMacros.swift # @Model 宏（代码生成）
```

## 关键配置入口
- **Package.swift**：依赖声明、宏目标配置、Swift 版本（6.1）
- **默认存储路径**：`~/Documents/JsonDataStore/`

## 工程约束
- 移除 SwiftCrossUI 依赖后，Query 模块已废弃（全部注释）
- 宏模块与运行时库严格分离，编译期 vs 运行时分层清晰
