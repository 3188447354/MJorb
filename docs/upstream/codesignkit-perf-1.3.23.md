# CodeSignKit 性能补丁留痕（1.3.23，2026-09-26）

> **为什么要这个文件**：`Vendor/CodeSignKit` 是**上游 SideStore 的一字不差副本**
> （2026-09-26 核对：`diff -rq upstream/CodeSignKit Vendor/CodeSignKit` 只有
> `Package.swift` 不同 —— 那是本仓改的 SwiftPM 依赖声明）。
> 本仓在这份副本上做了改动 ⇒ **下次同步上游时必须知道改了哪几处、为什么改**，
> 否则一次「照抄上游」就会把下面这些优化全部静默回退 ✗。
>
> ⚠️ 本仓**不能** `git merge` / `git rebase` 上游（历史被重建过、没有共同祖先）
> ⇒ 只能做**语义对照**，所以留痕靠的就是这份清单 + 守卫（**R91**）。

## 怎么重新生成 diff

```bash
# 上游快照在仓库根的 upstream/CodeSignKit（与 Vendor/CodeSignKit 同源）
for f in CodeDirectoryBuilder MachOSigner CMSSigner CodeSigner; do
  diff -u "upstream/CodeSignKit/Sources/$f.swift" "Vendor/CodeSignKit/Sources/$f.swift"
done
```

## 改了哪几处

| 文件 | 位置锚点（改后） | 改动 | 为什么 | 守卫 |
| --- | --- | --- | --- | --- |
| `CodeDirectoryBuilder.swift` | `public func size() -> Int { layout().totalSize }` ＋ `private func layout() -> Layout` | 新增 `size()`；把尺寸公式抽成 `layout()`，`build()` 与 `size()` **共用** | `MachOSigner` 的 Pass 1 只需要**长度**（算 `LC_CODE_SIGNATURE` 的偏移/长度），原来却传一份 `codeLimit` 字节的全零缓冲、让 `build()` 逐页哈希一遍 —— 那份哈希**没有任何地方用到** ✗。对齐 Apple `cdbuilder.cpp` 的 `Builder::size(version)` | R91① / R91② |
| `CodeDirectoryBuilder.swift` | `let page = UnsafeRawBufferPointer(rebasing: raw[pageStart..<pageEnd])` | 页哈希改成在 `binaryData` 的裸缓冲区上取切片（零拷贝），不再 `binaryData.subdata(in:)` | 原写法**每页新建一份 `Data`**（malloc ＋ memcpy）：200 MB 二进制按 16 KB 页算约 **1.2 万次**，而副本马上被哈希器吃掉 ✗ | R91③ |
| `MachOSigner.swift` | Pass 1：`binaryData: Data(),` ＋ `let dummyCDData = Data(count: dummyCD.size())` | Pass 1 只调 `size()`，不再 `build()` | 同上一行；**保留** dummy CMS 预签（Apple 自己也要预签一次估 CMS 长度） | R91② |
| `MachOSigner.swift` | `finalBinary.reserveCapacity(codeLimit + realSuperBlobData.count)` | 追加 SuperBlob 前预留容量 | 此时 `finalBinary.count == codeLimit`，直接 append 会「分配新缓冲 ＋ 整份复制」 | R91⑥ |
| `CMSSigner.swift` | `private lazy var parsedPKCS12: Result<PKCS12Parser, Error>` | PKCS#12 **实例级只解析一次**，`leafCertificate` 与 `sign()` 共用 | 原来 `leafCertificate` 是**计算属性**、`sign()` 又各自 `try PKCS12Parser(...)` ⇒ 同一个 `CMSSigner` 上每访问一次重解一遍（PBKDF2 2048 轮 ＋ AES ＋ DER）；33 个二进制约 **99 次** ✗ | R91⑤ |
| `CodeSigner.swift` | `try Data(contentsOf: executableURL, options: .mappedIfSafe)` | 签名输入改 mmap | 对每个 Mach-O 跑一次，整块读等于把每一份都白搬进内存（主二进制上百 MB ⇒ 内存峰值被 jetsam 盯上） | R91④ |

### ⚠️ 两处**刻意不动**的地方（改上面那些时别顺手「优化」掉）

1. **`MachOSigner` 对传入的 `binaryData` 全程只读** —— `let workingData = sliceData` 只能是别名，
   所有原地改写必须落在 `subdata` **复制**出来的 `finalBinary` 上。
   ⚠️ 这正是 `CodeSigner` 敢用 mmap 的**唯一**前提；破坏了它 ⇒ 写映射页 ⇒ **真机 SIGBUS**
   （同族事故：`SigningWorkspace.rewriteExecutablePathReferences`，见构建 151 的 `.ips`）。
   守卫 **R91④b**。
2. **`CodeSigner.removeSignature` 仍然用普通读取**（`Data(contentsOf:)`，没有 mmap）——
   `removeSignatureThinBinary` 里会 `prefix` 出切片再 `replaceSubrange` 原地改写，
   与上面那条判据**不同**。别把两处的 mmap 判据互相套用 ✗。

## 上游侧待办（本仓不做，但要知道）

- 这 6 处都是**上游也能受益**的改动 ⇒ 后续可以给上游提 PR（`Magesh-K/CodeSignKit`）。
- **没有**改动上游任何对外行为（`public` API 只**新增**了 `CodeDirectoryBuilder.size()`，
  其余全是内部实现）⇒ 补丁对上游是**向后兼容**的。

## 单测（CI `signer-tests` 跑 `swift test`，working-directory `Vendor/CodeSignKit`）

| 测试 | 钉住什么 |
| --- | --- |
| `CodeDirectoryBuilderTests.sizeMatchesBuildLengthForManyShapes` | `size()` 与 `build()` 长度**逐位一致**（8 种形状 × 2 种哈希算法） |
| `CodeDirectoryBuilderTests.codeDirectorySizeIgnoresBinaryContent` | 尺寸只与 `codeLimit` 有关、**与内容无关** ⇒ Pass 1 可以传空 `Data()` |
| `CodeDirectoryBuilderTests.pageHashesMatchLegacySubdataImplementation` | 零拷贝页哈希与原来的 `subdata` 实现**逐页逐字节相同** |
| `MachOSignerTests.codeSignatureLoadCommandMatchesTheAppendedSuperBlob` | `LC_CODE_SIGNATURE` 的 `dataoff`/`datasize` 与实际追加的 SuperBlob 完全吻合 |
| `MachOSignerTests.signingIsUnaffectedByHowTheInputDataWasLoaded` | mmap 读取与整块读取产出**完全相同的签名字节**（ad-hoc ⇒ 无签名时间 ⇒ 可比对） |
| `CMSSignerTests.repeatedAccessIsStableAndKeepsTheOriginalError` | 缓存后行为不变：指纹稳定、坏 P12 恒 `nil`、`sign()` **仍抛解析器真实错误** |
