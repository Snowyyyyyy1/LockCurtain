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

    let macName = "Mac"
    private(set) var step: Step = .searching
    private(set) var isVerifying = false
    private(set) var errorMessage: String?
    private(set) var shakeToken = 0

    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var started = false
    @ObservationIgnored private let verify: @MainActor (String) async -> Bool

    init(verify: @escaping @MainActor (String) async -> Bool = { _ in
        try? await Task.sleep(for: .milliseconds(600))
        return true
    }) {
        self.verify = verify
    }

    func start() {
        guard !started else { return }
        started = true
        task = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(1_200))
            guard let self, !Task.isCancelled else { return }
            self.step = .code
        }
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
            let accepted = await self.verify(code)
            guard !Task.isCancelled else { return }
            self.isVerifying = false
            if accepted {
                self.step = .success
            } else {
                self.errorMessage = "码不对，再看一眼 Mac 上那 6 位。"
                self.shakeToken += 1
            }
        }
    }
}

struct PairingSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

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
                    .id(session.step)
                    .transition(.opacity)
            }
            .animation(.easeInOut(duration: 0.25), value: session.step)
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
            session.start()
        }
        .onDisappear {
            session.cancel()
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
            }
        }
        .onChange(of: session.errorMessage) { _, message in
            guard message != nil else { return }
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

    @ViewBuilder
    private var content: some View {
        switch session.step {
        case .searching:
            searchingView
        case .code:
            codeView
        case .success:
            successView
        }
    }

    private var searchingView: some View {
        VStack(spacing: 16) {
            ProgressView()
                .controlSize(.large)
            Text("找这台 Mac…")
                .font(.title2.bold())
            Text("Mac 要醒着、在附近，蓝牙也要开着。")
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(.horizontal, 32)
    }

    private var codeView: some View {
        VStack(spacing: 16) {
            Text("输 6 位码")
                .font(.title2.bold())
            Text("Mac 上显示的那 6 个数字")
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            codeBoxes
                .modifier(ShakeEffect(animatableData: shake))
                .padding(.top, 8)

            if let message = session.errorMessage {
                Text(message)
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
            }

            if session.isVerifying {
                ProgressView()
            }

            hiddenField

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 20)
        .padding(.top, 48)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private var codeBoxes: some View {
        HStack(spacing: 8) {
            ForEach(0..<6, id: \.self) { index in
                let character = digit(at: index)
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color(.secondarySystemGroupedBackground))
                    .frame(width: 46, height: 58)
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
                            .minimumScaleFactor(0.5)
                    }
            }
        }
        .contentShape(.rect)
        .onTapGesture {
            codeFocused = true
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("6 位配对码")
        .accessibilityValue(code.isEmpty ? "还没输入" : code.map(String.init).joined(separator: " "))
    }

    private var hiddenField: some View {
        TextField("", text: $code)
            .keyboardType(.numberPad)
            .textContentType(.oneTimeCode)
            .focused($codeFocused)
            .frame(width: 1, height: 1)
            .opacity(0.01)
            .accessibilityLabel("6 位配对码")
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
        VStack(spacing: 16) {
            Spacer()

            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 56))
                .foregroundStyle(.green)
            Text("配对好了")
                .font(.title2.bold())

            Spacer()

            Button {
                completeIfNeeded()
                dismiss()
            } label: {
                Text("完成")
                    .frame(maxWidth: .infinity)
                    .frame(minHeight: 50)
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
