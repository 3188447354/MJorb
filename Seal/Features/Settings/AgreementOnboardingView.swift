import SwiftUI

/// 协议版本号：文档有实质更新时 +1，触发用户重新同意。
enum AgreementVersion {
    static let current = 1
    static let storageKey = "seal.agreedAgreementVersion"
}

/// 首次启动（或协议更新后）的协议同意页。
///
/// 视觉：品牌图标 → 标题 → 两张成组卡片（信任摘要 / 协议入口）→ 底部主次按钮。
///
/// 🔴 2026-10-08 重做的原因（用户反馈「UI 布局…大小、间隙太割裂」）：
/// 旧版把两条信任摘要用裸 `Divider` 串在页面背景上、两条协议入口又是**两张各自带阴影的
/// 独立卡片** ⇒ 四行同类信息有四种「贴法」；再加上 40 / 24 / 16 / 14 / 12 / 8 混着当间距、
/// 圆角 18 / 15 / 9 混着用，还手写了一个与设计系统不一致的主按钮（52pt / 字号 17 / 圆角 15）。
/// 现在：「**一张玻璃卡片 = 一组同类信息**」，组内一条内缩细线分隔，组与组之间同一档间距；
/// 所有间距只从 `Metrics` 的三档里取、圆角只用两档；主按钮直接走设计系统的
/// `sealPrimaryAction`（全 App 同一套按下动画与投影）。
struct AgreementOnboardingView: View {
    var onAgreed: () -> Void
    var onDeclined: () -> Void

    @State private var showDeclineHint = false

    /// 版式常量：集中在此，别让 magic number 再散回各处。
    ///
    /// 规则：**间距按「关系」分三档**（块与块 / 紧邻 / 再紧一档），
    /// **圆角只用两档**（卡片 / 卡片内小方块），按钮圆角跟随全 App 惯例。
    /// 「割裂感」的根源就是同一类元素每处各调各的数值 —— 这里把它锁死。
    /// ⚠️ 名字刻意叫 `Metrics` 而不是 `Layout`：SwiftUI 自己有个 `Layout` 协议，
    /// 嵌套类型同名会在本类型作用域里把它遮住，日后有人在这里写自定义布局会莫名其妙编译不过。
    private enum Metrics {
        /// 大块之间：品牌头 → 信任卡片 → 协议卡片。
        static let section: CGFloat = 22
        /// 紧邻元素之间：标题 ↔ 副标题、图标 ↔ 文字、卡片内行与行。
        static let tight: CGFloat = 10
        /// 再紧一档：卡片内标题与描述之间。
        static let block: CGFloat = 4

        /// 页面左右安全边距。
        static let gutter: CGFloat = 20
        /// 首屏顶部留白（不参与块间距节奏）。
        static let pageTop: CGFloat = 32
        /// 底部操作区与安全区之间的留白。
        static let pageBottom: CGFloat = 18
        /// 卡片内行的左右内边距。
        static let rowHorizontal: CGFloat = 14
        /// 卡片内行的上下内边距（两张卡片**共用同一值** ⇒ 行高节奏一致）。
        static let rowVertical: CGFloat = 13

        /// 卡片圆角。
        static let cardCorner: CGFloat = 18
        /// 主按钮圆角：与全 App 其余 `sealPrimaryAction` 调用点一致（都是 14）。
        static let buttonCorner: CGFloat = 14
        /// 卡片内小方块圆角。
        static let tileCorner: CGFloat = 10
        /// 卡片内行首图标方块边长。
        static let tile: CGFloat = 32

        /// 细线粗细。
        static let hair: CGFloat = 1
        /// 组内分隔线左端对齐到文字起点（= 行内边距 + 图标方块 + 图标间距）。
        static var dividerInset: CGFloat { rowHorizontal + tile + tight }
    }

    var body: some View {
        VStack(spacing: 0) {
            // 顶部内容（一屏放下，不滚动）
            VStack(spacing: Metrics.section) {
                brandHeader
                trustCard
                documentsCard
            }
            .padding(.horizontal, Metrics.gutter)
            .padding(.top, Metrics.pageTop)

            Spacer(minLength: Metrics.section)

            footer
        }
        .sealScreenBackground()
        .alert("需要您的同意", isPresented: $showDeclineHint) {
            Button("好的", role: .cancel) { }
        } message: {
            Text("Seal 需要您同意《隐私政策》与《用户协议》才能继续使用。")
        }
    }

    // MARK: - 上半屏

    /// 品牌图标 + 标题 + 副标题。三段共用 `tight` 间距 ⇒ 读成**一个整体**，而不是三个元素。
    private var brandHeader: some View {
        VStack(spacing: Metrics.tight) {
            Image("SealBrandIcon")
                .resizable()
                .frame(width: 64, height: 64)
                .clipShape(RoundedRectangle(cornerRadius: Metrics.cardCorner, style: .continuous))
                .shadow(color: Color.sealAccent.opacity(0.18), radius: 12, y: 6)

            VStack(spacing: Metrics.block) {
                Text("欢迎使用 Seal")
                    .font(.system(size: 27, weight: .bold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)

                Text("开始前，请花一分钟了解我们如何处理你的数据。")
                    .font(.system(size: 13))
                    .foregroundStyle(Color.sealTextSecondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, Metrics.block)
        }
    }

    /// 信任摘要：**一张**卡片包两条，组内细线分隔 —— 不再让两行各自「挂在」页面背景上。
    private var trustCard: some View {
        VStack(spacing: 0) {
            trustRow(
                icon: "iphone",
                title: "优先在本机处理",
                detail: "账号、设备与签名资料默认保留在此设备。"
            )
            cardDivider
            trustRow(
                icon: "lock.shield",
                title: "仅用于必要的 Apple 通信",
                detail: "需要签名时，才与 Apple 服务建立加密连接。"
            )
        }
        .glassSurface(cornerRadius: Metrics.cardCorner)
    }

    /// 协议入口：同样是**一张**卡片包两行 —— 两行各自成卡会带来「高度不一致 + 阴影叠加」。
    private var documentsCard: some View {
        VStack(spacing: 0) {
            NavigationLink { PrivacyNoticeView() } label: {
                documentRow(
                    title: AgreementMetadata.Privacy.title,
                    date: AgreementMetadata.Privacy.effectiveDate,
                    icon: "doc.text"
                )
            }
            .buttonStyle(.plain)

            cardDivider

            NavigationLink { UserAgreementView() } label: {
                documentRow(
                    title: AgreementMetadata.Terms.title,
                    date: AgreementMetadata.Terms.effectiveDate,
                    icon: "doc.plaintext"
                )
            }
            .buttonStyle(.plain)
        }
        .glassSurface(cornerRadius: Metrics.cardCorner)
    }

    /// 组内分隔线：左端对齐到文字起点（跳过图标方块），视觉上属于上一行的「后半段」。
    private var cardDivider: some View {
        Rectangle()
            .fill(Color.sealHairline)
            .frame(height: Metrics.hair)
            .padding(.leading, Metrics.dividerInset)
    }

    // MARK: - 底部操作区

    /// 同意说明 + 主次按钮。三段共用 `tight` 间距，整体贴在下安全区上方。
    private var footer: some View {
        VStack(spacing: Metrics.tight) {
            agreementFootnote

            Button("同意并继续") {
                UserDefaults.standard.set(AgreementVersion.current, forKey: AgreementVersion.storageKey)
                onAgreed()
            }
            .sealPrimaryAction(cornerRadius: Metrics.buttonCorner)

            Button("暂不使用") {
                showDeclineHint = true
                onDeclined()
            }
            .font(.system(size: 15, weight: .medium))
            .foregroundStyle(Color.sealTextSecondary)
            .frame(maxWidth: .infinity)
            .frame(minHeight: 44)
        }
        .padding(.horizontal, Metrics.gutter)
        .padding(.bottom, Metrics.pageBottom)
    }

    /// 「继续即表示你已阅读并同意《隐私政策》和《用户协议》。」协议名可点。
    private var agreementFootnote: some View {
        HStack(spacing: 0) {
            Text("继续即表示你已阅读并同意")
                .foregroundStyle(Color.sealTextSecondary)
            NavigationLink { PrivacyNoticeView() } label: {
                Text("《\(AgreementMetadata.Privacy.title)》")
                    .fontWeight(.semibold)
                    .foregroundStyle(Color.sealAccent)
            }
            .buttonStyle(.plain)
            Text("和")
                .foregroundStyle(Color.sealTextSecondary)
            NavigationLink { UserAgreementView() } label: {
                Text("《\(AgreementMetadata.Terms.title)》")
                    .fontWeight(.semibold)
                    .foregroundStyle(Color.sealAccent)
            }
            .buttonStyle(.plain)
            Text("。")
                .foregroundStyle(Color.sealTextSecondary)
        }
        .font(.system(size: 12))
        .lineLimit(1)
        .minimumScaleFactor(0.75)
        .padding(.horizontal, Metrics.block)
    }

    // MARK: - 行构件

    /// 信任摘要行：图标方块 + 粗体标题 + 描述。行高统一由 `Metrics` 决定，不再逐处微调。
    private func trustRow(icon: String, title: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: Metrics.tight) {
            iconTile(icon)
            VStack(alignment: .leading, spacing: Metrics.block) {
                Text(title)
                    .font(.system(size: 15, weight: .semibold))
                Text(detail)
                    .font(.system(size: 12.5))
                    .foregroundStyle(Color.sealTextSecondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, Metrics.rowHorizontal)
        .padding(.vertical, Metrics.rowVertical)
    }

    /// 协议文档行：图标方块 + 名称 + 生效日期 + 箭头。
    private func documentRow(title: String, date: String, icon: String) -> some View {
        HStack(spacing: Metrics.tight) {
            iconTile(icon)
            Text(title)
                .font(.system(size: 15, weight: .semibold))
            Spacer(minLength: Metrics.block)
            Text(date)
                .font(.system(size: 12))
                .foregroundStyle(Color.sealTextSecondary)
            Image(systemName: "chevron.right")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Color.sealTextSecondary.opacity(0.55))
        }
        .padding(.horizontal, Metrics.rowHorizontal)
        .padding(.vertical, Metrics.rowVertical)
        .contentShape(Rectangle())
    }

    /// 行首图标方块：两处构件共用同一尺寸与圆角 ⇒ 上下两行的「起点」天然对齐。
    private func iconTile(_ icon: String) -> some View {
        Image(systemName: icon)
            .font(.system(size: 15, weight: .semibold))
            .foregroundStyle(Color.sealAccent)
            .frame(width: Metrics.tile, height: Metrics.tile)
            .background(
                Color.sealAccent.opacity(0.12),
                in: RoundedRectangle(cornerRadius: Metrics.tileCorner, style: .continuous)
            )
    }
}

/// UI 测试用的启动参数：声明「本次启动视为已同意协议」。
///
/// 🔴 为什么必须有（2026-10-07 引入本门控时漏掉的同步）：
/// 门控把**整个** `RootTabView` 挡在协议页后面，而 `SealUITests` 的用例都是
/// `app.launch()` 之后直接去找根界面的元素（tab 栏 / 「待签名，N 个」/ 导入入口）
/// ⇒ 它们全部停在协议页，7 个用例一起红，
/// `swift-regression` 从 2026-10-05 最后一次全绿之后再没绿过。
/// 而中间几十次 run 全是 `cancelled`（被新推送顶掉），这个红点一直没暴露 ——
/// 直到 2026-10-08 才第一次真的跑完并报出来，很容易被误当成「本轮改动引入的回归」。
///
/// ⚠️ 只认**显式**参数，**不**写成「`--ui-testing-` 前缀」这类隐式规则
/// （AGENTS.md §3：显式集合，禁止前缀与数字区间）：
/// 前缀规则会让「到底哪些参数能开门」不可枚举，下一个加 UI 测试的人无从自查。
///
/// 真实用户拿不到这个参数：iOS 上启动参数只有 Xcode / `simctl launch` 能传，
/// 别的 App 无法为 Seal 指定 —— 所以门控对真实首启的行为完全不变。
let uiTestingAgreementAcceptedArgument = "--ui-testing-agreement-accepted"

/// 检查是否需要展示协议页：没同意过，或协议版本更新了。
///
/// - Parameter arguments: 可注入，便于单测；默认取进程启动参数。
func needsAgreementOnboarding(
    arguments: [String] = ProcessInfo.processInfo.arguments
) -> Bool {
    if arguments.contains(uiTestingAgreementAcceptedArgument) {
        return false
    }
    return UserDefaults.standard.integer(forKey: AgreementVersion.storageKey) < AgreementVersion.current
}
