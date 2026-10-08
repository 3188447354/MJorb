# 常犯坑位

从 DEBUG_LOG.md 提炼，动手前必查。

## 1. 只改一处，漏了关联

- **症状**：修了 A，B 还是旧的
- **例子**：
  - 修导入抽屉图标预览，只改 ImportConfirmationView，漏了 AppSigningSheet
  - 修 iconData，漏了 decodedIconCache
  - 修 ViewModel 的缓存，漏了 ImportedAppRow 的 static 缓存
- **对策**：改任何东西，并发 grep 所有相关文件（UI、缓存、通知、持久化）

## 2. 猜而不查

- **症状**：构建失败猜是 CI 问题，实际是自己代码括号多了
- **对策**：先看日志/代码，再下结论。禁止猜测。

## 3. NSCache 的 limit 不生效

- **症状**：设了 totalCostLimit，内存还是涨
- **根因**：`setObject(_:forKey:)` 不传 cost，limit 不生效
- **对策**：手动记顺序，超了删最旧的；或传 cost

## 4. load() 会覆盖直接设置的值

- **症状**：设置了 `iconData[id]`，但 UI 不显示
- **根因**：`load()` 重建整个字典，覆盖了直接设置
- **对策**：在 `load()` 完成后再设置

## 5. 私有 struct 跨文件用不了

- **症状**：编译失败 "cannot find in scope"
- **根因**：`private struct` 只能在定义文件内用
- **对策**：改成 `internal`（去掉 private）

## 6. 守卫只查字符串，注释会误伤

- **症状**：守卫恒假
- **根因**：判"源码不得出现 X"时忘了注释里也有 X
- **对策**：先 grep 确认，或用 strip_comments
