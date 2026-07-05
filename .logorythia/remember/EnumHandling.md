# Enum 处理规则

## String enum（RawRepresentable）

- **columnKind**：`.codableJSON`（默认路径，不特殊处理）
- **SQL 列类型**：`TEXT`
- **存储内容**：JSON 编码后的值，如 `"\"active\""` 而非 `"active"`
- **索引**：✅ 可用，B-tree 索引对 TEXT 列正常生效
- **展开为裸字符串**：❌ 不展开，无此优化

### 关键逻辑位置

`file:///Users/zhiyang/开发/Packges/JsonData/Sources/JsonDataMacros/JsonDataMacros.swift:<28>-<49>`

`columnKind` 计算属性中，`String`、`Int` 等基础类型映射为对应的 `.string` / `.integer`，其余所有类型（含 enum）走 `.codableJSON`。

### 对 `#Predicate` 查询的影响

无影响——predicate 同样走 JSON 编解码，值一致匹配。功能无问题，只是存储多几字节引号。
