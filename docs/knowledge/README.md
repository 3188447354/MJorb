# Seal 知识库

配合 `MEMORY.md`（用户偏好/教训）与 `DEBUG_LOG.md`（bug 历史）一起用。

## 文件

- **ARCHITECTURE.md** - 系统架构：三条链路（签名/安装/续签）怎么走，关键类在哪
- **CODEMAP.md** - 代码地图：改某个功能去哪找文件
- **PITFALLS.md** - 常犯坑位：从 DEBUG_LOG 提炼的高频错误模式
- **DECISIONS.md** - 决策记录：为什么这么做（比如为什么不用某个方案）

## 使用

- 改 bug 前：先查 PITFALLS.md 看是不是犯过，再查 DEBUG_LOG.md 看具体案例
- 加功能前：先查 ARCHITECTURE.md 看走哪条链路，再查 CODEMAP.md 找文件
- 做决策时：查 DECISIONS.md 看以前为什么这么定
