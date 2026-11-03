import Observation
import SwiftUI

/// The local pairing prototype. There is no Mac to ask yet, so this session
/// drives the three UI steps and never tells the link that a connection exists:
/// after it finishes, BLEPlaceholderCurtainLink still reports "没连上".
@MainActor
@Observable
final class PairingSession {
    enum Step: Equatable {
        case searching
        case code
        case success
    }

    let macName = "这台电脑"
    private(set) var step: Step = .searching
    private(set) var isVerifying = false
    private(set) var errorMessage: String?
    private(set) var retryTitle = "重试"
    private(set) var shakeToken = 0

    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var started = false
    /// 由界面在出现时接上真的配对：把码交给 Mac 的那一步
    @ObservationIgnored var verify: @MainActor (String) async -> PairResult = { _ in .notFound }
    /// 「再找一次 / 再试一次」时重新开始连接（连续失败停下之后，只有这里能让它重新来）
    @ObservationIgnored var onRetry: @MainActor () -> Void = {}

    func start() {
        guard !started else { return }
        started = true
        task = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(1_200))
            guard let self, !Task.isCancelled else { return }
            self.step = .code
        }
    }

    /// 失败：一句说卡在哪，配一颗下一步该按的按钮（copy v6.2 §8.5）
    private func fail(_ message: String, _ action: String) {
        errorMessage = message
        retryTitle = action
        shakeToken += 1
    }

    /// 那颗「再找一次 / 再试一次 / 重新输入」：前两个重走一遍流程，最后一个只是清空重输
    func retry() {
        if retryTitle == "重新输入" {
            errorMessage = nil
            return
        }
        errorMessage = nil
        onRetry()
        started = false
        step = .searching
        start()
    }

    /// 连续断了几次、停下以后点「再试一次」：清掉错误，重新开始连接
    func restart() {
        task?.cancel()
        isVerifying = false
        errorMessage = nil
        onRetry()
        started = false
        step = .searching
        start()
    }

    func cancel() {
        task?.cancel()
    }

    func submit(_ code: String) {
        guard step == .code, !isVerifying, code.count == 6 else { return }
        isVerifying = true
        errorMessage = nil
        task?.cancel()
        task = Task { [weak self] in
            guard let self else { return }
            let result = await self.verify(code)
            guard !Task.isCancelled else { return }
            self.isVerifying = false
            switch result {
            case .accepted:
                self.step = .success
            case .notFound:
                self.fail("这台电脑没连上来。电脑上开着 LockCurtain，两边蓝牙都开着。", "再找一次")
            case .connectFailed:
                self.fail("连上了，但没配成。把电脑上「配对手机」重新点开，拿新的 6 位。", "再试一次")
            case .wrongCode:
                self.fail("码不对，再看一眼电脑上那 6 位。", "重新输入")
            case .macRefused:
                self.fail("电脑没有接受这次配对。回电脑上点「换一个码」，再输一次。", "重新输入")
            case .noResponse:
                self.fail("这次作废了。回电脑上点「换一个码」。", "再试一次")
            case .disconnected:
                self.fail("和这台电脑断开了。刚才那 6 位不能用了。", "再试一次")
            }
        }
    }
}

struct PairingSheet: View {
    /// 已经配着一台、要换成另一台（copy v11 §13）：新配对在旁边配，配成了才换掉原来那台
    var replacing = false

    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// v2.9 P2-1：格子跟字号走（整排封顶在 AX2）
    @ScaledMetric(relativeTo: .title) private var box: CGFloat = 46
    /// v2.9 P2-2
    @ScaledMetric(relativeTo: .largeTitle) private var heroSize: CGFloat = 56

    @State private var session = PairingSession()
    @State private var code = ""
    @State private var shake: CGFloat = 0
    @State private var didComplete = false
    @FocusState private var codeFocused: Bool

    var body: some View {
        NavigationStack {
            ZStack {
                Color(.systemGroupedBackground)
                    .ignoresSafeArea()
                content
                    .id(showsGaveUp ? nil : session.step)
                    .transition(.opacity)
            }
            .animation(.easeInOut(duration: 0.25), value: session.step)
            .animation(.easeInOut(duration: 0.25), value: showsGaveUp)
            .navigationTitle("配对")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button(role: .close) {
                        dismiss()
                    }
                    .accessibilityLabel("关闭")
                }
            }
        }
        .presentationDetents([.large])
        .onAppear {
            model.prepareForPairing()
            let replacing = replacing
            session.verify = { [model] code in
                replacing ? await model.pairReplacing(code: code) : await model.pair(code: code)
            }
            session.onRetry = { [model] in model.prepareForPairing() }
            session.start()
        }
        .onDisappear {
            session.cancel()
            if replacing && session.step != .success {
                // 中途关掉：新配对作废，原来那台不动
                model.cancelReplacing()
            }
            completeIfNeeded()
        }
        .onChange(of: session.step) { _, newStep in
            if newStep == .code {
                Task {
                    try? await Task.sleep(for: .milliseconds(300))
                    codeFocused = true
                }
            } else if newStep == .success {
                codeFocused = false
                // v2.9 P1-4：配好了也读出来
                AccessibilityNotification.Announcement(successTitle).post()
            }
        }
        .onChange(of: model.connectionGaveUp) { _, gaveUp in
            if gaveUp { codeFocused = false }
        }
        .onChange(of: session.errorMessage) { _, message in
            // v2.9 P1-4：出错那句读出来（和 .error 震动同时）
            if let message {
                AccessibilityNotification.Announcement(message).post()
            }
            guard message != nil, !model.connectionGaveUp else { return }
            code = ""
            codeFocused = true
        }
        .onChange(of: session.shakeToken) { _, _ in
            guard !reduceMotion else { return }
            shake = 0
            withAnimation(.linear(duration: 0.35)) {
                shake += 1
            }
        }
        .sensoryFeedback(.success, trigger: session.step) { _, step in
            step == .success
        }
        .sensoryFeedback(.error, trigger: session.shakeToken)
    }

    // MARK: - Steps

    /// 连续断了 5 次、已经不再重连：换掉一般的失败提示
    private var showsGaveUp: Bool {
        model.connectionGaveUp && session.step != .success
    }

    @ViewBuilder
    private var content: some View {
        if showsGaveUp {
            GaveUpNotice {
                session.restart()
            }
            .padding(.horizontal, 32)
        } else {
            stepContent
        }
    }

    @ViewBuilder
    private var stepContent: some View {
        switch session.step {
        case .searching:
            searchingView
        case .code:
            codeView
        case .success:
            successView
        }
    }

    /// 首次配对「配对好了」；换电脑「已经换成这台电脑了。」（copy v11 §13）
    private var successTitle: String {
        replacing ? "已经换成这台电脑了。" : "配对好了"
    }

    private var searchingView: some View {
        VStack(spacing: 16) {
            ProgressView()
            Text("等这台电脑来连")
                .font(.title2.bold())
                .accessibilityAddTraits(.isHeader)
            Text("电脑上点开「配对手机」，把 6 位输进来")
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(.horizontal, 32)
    }

    private var codeView: some View {
        // v2.9 P2-4：能滚，最大字号或横屏时错误那句和按钮不会被键盘挡住
        ScrollView {
            codeStack
        }
        .scrollBounceBehavior(.basedOnSize)
    }

    private var codeStack: some View {
        VStack(spacing: 16) {
            Text("输 6 位码")
                .font(.title2.bold())
                .accessibilityAddTraits(.isHeader)
            Text("电脑上显示的那 6 个数字")
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            // v2.9 P1-3：格子只是画，读屏只看到盖在上面的那一个输入框
            codeBoxes
                .accessibilityHidden(true)
                .overlay { hiddenField }
                .modifier(ShakeEffect(animatableData: shake))
                .padding(.top, 8)

            if let message = session.errorMessage {
                Text(message)
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
                Button(session.retryTitle) {
                    session.retry()
                }
                .buttonStyle(.bordered)
            }

            if session.isVerifying {
                ProgressView()
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 48)
        .padding(.bottom, 20)
        .frame(maxWidth: .infinity, alignment: .top)
    }

    private var codeBoxes: some View {
        // 格子宽 = box（跟字号走），放不下就一起缩；高 = 宽 × 1.26
        HStack(spacing: 8) {
            ForEach(0..<6, id: \.self) { index in
                let character = digit(at: index)
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color(.secondarySystemGroupedBackground))
                    .aspectRatio(1 / 1.26, contentMode: .fit)
                    .frame(maxWidth: box)
                    .overlay {
                        RoundedRectangle(cornerRadius: 12)
                            .strokeBorder(
                                index == code.count && codeFocused ? Color.accentColor : .clear,
                                lineWidth: 2
                            )
                    }
                    .overlay {
                        Text(character)
                            .font(.title.monospacedDigit().weight(.semibold))
                    }
            }
        }
        .frame(maxWidth: 6 * box + 5 * 8)
        .dynamicTypeSize(...DynamicTypeSize.accessibility2)
    }

    private var hiddenField: some View {
        TextField("", text: $code)
            .keyboardType(.numberPad)
            .textContentType(.oneTimeCode)
            .focused($codeFocused)
            // 字和光标都透明：大字号时 0.01 的字在白格子上还能隐约看见
            .foregroundStyle(.clear)
            .tint(.clear)
            .frame(maxWidth: .infinity, minHeight: 58, maxHeight: .infinity)
            .opacity(0.01)
            .accessibilityLabel("6 位配对码")
            .accessibilityValue(code.isEmpty ? "还没输" : "已输 \(code.count) 位")
            .onChange(of: code) { _, newValue in
                let filtered = String(newValue.filter { $0.isNumber }.prefix(6))
                if filtered != newValue {
                    code = filtered
                    return
                }
                if filtered.count == 6 && !session.isVerifying {
                    codeFocused = false
                    session.submit(filtered)
                }
            }
    }

    private var successView: some View {
        // v2.9 P2-4：能滚；内容不够高时照旧上下居中、按钮在底
        GeometryReader { proxy in
            ScrollView {
                successStack
                    .frame(minHeight: proxy.size.height)
            }
            .scrollBounceBehavior(.basedOnSize)
        }
    }

    private var successStack: some View {
        VStack(spacing: 16) {
            Spacer()

            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: heroSize))
                .foregroundStyle(.green)
                .accessibilityHidden(true)
            Text(successTitle)
                .font(.title2.bold())
                .multilineTextAlignment(.center)
                .accessibilityAddTraits(.isHeader)

            Spacer()

            Button {
                completeIfNeeded()
                dismiss()
            } label: {
                Text("完成")
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 3)
            }
            .buttonStyle(.glassProminent)
            .controlSize(.large)
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 8)
    }

    private func completeIfNeeded() {
        guard session.step == .success, !didComplete else { return }
        didComplete = true
        model.completePairing(macName: session.macName)
    }

    private func digit(at index: Int) -> String {
        guard index < code.count else { return "" }
        let stringIndex = code.index(code.startIndex, offsetBy: index)
        return String(code[stringIndex])
    }
}

private struct ShakeEffect: GeometryEffect {
    var travelDistance: CGFloat = 8
    var shakesPerUnit: CGFloat = 3
    var animatableData: CGFloat

    func effectValue(size: CGSize) -> ProjectionTransform {
        ProjectionTransform(
            CGAffineTransform(
                translationX: travelDistance * sin(animatableData * .pi * shakesPerUnit),
                y: 0
            )
        )
    }
}

#Preview {
    PairingSheet()
        .environment(AppModel())
}
