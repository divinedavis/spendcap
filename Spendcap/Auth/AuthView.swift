import AuthenticationServices
import SwiftUI

/// Signed-out landing: a dark field with the wordmark centred, then a light
/// sheet with a curved top sweeps up from the bottom, the wordmark settles in
/// the top-left corner, and the form fades in on the sheet.
///
/// The form is *inserted* only once the sheet has landed rather than faded from
/// zero opacity in place. XCUITest treats an invisible-but-present field as
/// existing, and `testLaunchShowsAuthScreen` asserts the submit button is
/// hittable the moment the email field exists — inserting late keeps those two
/// facts true at the same instant.
struct AuthView: View {
    @EnvironmentObject var auth: AuthViewModel
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @State private var email = ""
    @State private var password = ""
    @State private var isSigningUp = false

    @State private var stage = IntroStage.blank
    @FocusState private var focusedField: Field?

    enum Field { case email, password }

    enum IntroStage: Int, Comparable {
        case blank, wordmark, sheet, form
        static func < (a: Self, b: Self) -> Bool { a.rawValue < b.rawValue }
    }

    var body: some View {
        NavigationStack {
            GeometryReader { geo in
                // While typing, the sheet rises over the header so the
                // keyboard can't cover the password field.
                let sheetTop = focusedField != nil ? 0 : max(geo.size.height * 0.26, 190)

                ZStack(alignment: .topLeading) {
                    LinearGradient(colors: [.spendcapFieldTop, .spendcapFieldBottom],
                                   startPoint: .top, endPoint: .bottom)
                        .ignoresSafeArea()

                    header
                        .frame(maxWidth: .infinity,
                               maxHeight: stage >= .sheet ? sheetTop - 24 : .infinity,
                               alignment: stage >= .sheet ? .topLeading : .center)
                        .padding(.horizontal, 28)
                        .padding(.top, stage >= .sheet ? 28 : 0)
                        .opacity(focusedField != nil ? 0 : 1)

                    sheet
                        .frame(height: geo.size.height + geo.safeAreaInsets.bottom - sheetTop)
                        .offset(y: stage >= .sheet ? sheetTop : geo.size.height + 80)
                }
                .animation(.spring(response: 0.45, dampingFraction: 0.9), value: focusedField)
            }
            // An empty, transparent bar kept only so the status bar can be
            // told it sits on a dark header: with the bar hidden it follows
            // the app's appearance and draws black-on-black in light mode.
            .toolbarBackground(Color.clear, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbarColorScheme(.dark, for: .navigationBar)
        }
        .overlay {
            if auth.isLoading { ProgressView() }
        }
        // Wait for an active scene: on a cold launch RootView's privacy cover
        // is still up for a beat, and the wordmark would fade in behind it.
        .task(id: scenePhase == .active) {
            if scenePhase == .active { await playIntro() }
        }
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: stage >= .sheet ? .leading : .center, spacing: 10) {
            HStack(spacing: 10) {
                SpendcapMark()
                    .frame(width: stage >= .sheet ? 30 : 40)
                Text("SPENDCAP")
                    .font(.system(size: stage >= .sheet ? 24 : 30, weight: .semibold))
                    .tracking(6)
                    .foregroundStyle(.white)
            }
            Text("Know the moment you're over budget.")
                .font(.subheadline)
                .foregroundStyle(.white.opacity(0.6))
        }
        .opacity(stage >= .wordmark ? 1 : 0)
        .scaleEffect(stage >= .wordmark ? 1 : 0.94)
        .accessibilityElement(children: .combine)
    }

    // MARK: - Sheet

    private var sheetFill: Color {
        // The header is near-black in both modes; in dark mode a pure black
        // sheet would erase the curve, so lift it one step.
        colorScheme == .dark ? Color(.secondarySystemBackground) : Color(.systemBackground)
    }

    private var sheet: some View {
        CurvedSheetShape()
            .fill(sheetFill)
            .ignoresSafeArea(edges: .bottom)
            .overlay(alignment: .top) {
                if stage >= .form {
                    ScrollViewReader { proxy in
                        ScrollView {
                            form
                                .padding(.top, CurvedSheetShape.dip + 12)
                                // Room to scroll the fields clear of the
                                // keyboard; the form alone is too short to.
                                .padding(.bottom, focusedField != nil ? 360 : 32)
                        }
                        .scrollDismissesKeyboard(.interactively)
                        .scrollBounceBehavior(.basedOnSize)
                        .onChange(of: focusedField) { _, field in
                            guard field != nil else { return }
                            Task {
                                // After the bottom room lands, or there is
                                // nothing yet to scroll into.
                                try? await Task.sleep(for: .milliseconds(50))
                                withAnimation { proxy.scrollTo("credentials", anchor: .top) }
                            }
                        }
                    }
                }
            }
    }

    private var form: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(isSigningUp ? "Create account" : "Sign in")
                .font(.largeTitle.weight(.semibold))
                .reveal(order: 0, reduceMotion: reduceMotion)

            // Third-party sign-in sits above the form: it is the faster
            // path and the one most people will take, and burying it
            // under a keyboard-first form makes it look like a fallback.
            VStack(spacing: 12) {
                SignInWithAppleButton(.signIn) { request in
                    auth.prepareAppleRequest(request)
                } onCompletion: { result in
                    Task { await auth.completeAppleSignIn(result) }
                }
                .signInWithAppleButtonStyle(colorScheme == .dark ? .white : .black)
                .frame(height: 48)
                .clipShape(Capsule())
                .accessibilityIdentifier("auth.apple")

                // Hidden rather than disabled when the build has no Google
                // client id — a button that can only ever fail is worse
                // than no button.
                if GoogleSignInService.isConfigured {
                    Button {
                        Task { await auth.signInWithGoogle() }
                    } label: {
                        Label("Continue with Google", systemImage: "g.circle.fill")
                            .font(.body.weight(.medium))
                            .frame(maxWidth: .infinity, minHeight: 48)
                    }
                    .buttonStyle(.bordered)
                    .buttonBorderShape(.capsule)
                    .accessibilityIdentifier("auth.google")
                }
            }
            .disabled(auth.isLoading)
            .reveal(order: 1, reduceMotion: reduceMotion)

            HStack {
                VStack { Divider() }
                Text("or")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                VStack { Divider() }
            }
            .reveal(order: 2, reduceMotion: reduceMotion)

            VStack(alignment: .leading, spacing: 6) {
                Text("Email").font(.footnote.weight(.semibold))
                TextField("Enter your email", text: $email)
                    .textContentType(.emailAddress)
                    .keyboardType(.emailAddress)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .modifier(OutlinedField())
                    .focused($focusedField, equals: .email)
                    .submitLabel(.next)
                    .onSubmit { focusedField = .password }
                    .accessibilityIdentifier("auth.email")

                Text("Password").font(.footnote.weight(.semibold))
                    .padding(.top, 6)
                SecureField("Enter your password", text: $password)
                    .textContentType(isSigningUp ? .newPassword : .password)
                    .modifier(OutlinedField())
                    .focused($focusedField, equals: .password)
                    .accessibilityIdentifier("auth.password")
            }
            .id("credentials")
            .reveal(order: 3, reduceMotion: reduceMotion)

            if let error = auth.errorMessage {
                Text(error)
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .accessibilityIdentifier("auth.error")
            }

            if let notice = auth.noticeMessage {
                Label(notice, systemImage: "envelope.badge")
                    .font(.footnote)
                    .foregroundStyle(.blue)
                    .accessibilityIdentifier("auth.notice")
            }

            VStack(spacing: 14) {
                Button {
                    Task {
                        if isSigningUp {
                            await auth.signUp(email: email, password: password)
                        } else {
                            await auth.signIn(email: email, password: password)
                        }
                    }
                } label: {
                    Text(isSigningUp ? "Create Account" : "Sign In")
                        .font(.body.weight(.semibold))
                        .frame(maxWidth: .infinity, minHeight: 48)
                }
                .buttonStyle(.borderedProminent)
                .buttonBorderShape(.capsule)
                .tint(colorScheme == .dark ? .white : .spendcapFieldTop)
                .foregroundStyle(colorScheme == .dark ? Color.black : Color.white)
                .disabled(email.isEmpty || password.isEmpty || auth.isLoading)
                .accessibilityIdentifier("auth.submit")

                Button(isSigningUp ? "Have an account? Sign in" : "New here? Create an account") {
                    isSigningUp.toggle()
                    auth.errorMessage = nil
                    auth.noticeMessage = nil
                }
                .font(.footnote)
                .accessibilityIdentifier("auth.toggleMode")
            }
            .frame(maxWidth: .infinity)
            .reveal(order: 4, reduceMotion: reduceMotion)
        }
        .padding(.horizontal, 28)
    }

    // MARK: - Intro timing

    private func playIntro() async {
        guard stage == .blank else { return }
        if reduceMotion {
            stage = .form
            return
        }
        withAnimation(.easeOut(duration: 0.45)) { stage = .wordmark }
        try? await Task.sleep(for: .milliseconds(800))
        withAnimation(.spring(response: 0.7, dampingFraction: 0.86)) { stage = .sheet }
        try? await Task.sleep(for: .milliseconds(450))
        stage = .form
    }
}

/// The sheet's top edge: high on the left, dipping to the right in one sweep,
/// so the dark header reads as a wave resting on the form.
struct CurvedSheetShape: Shape {
    /// How far below its left edge the curve lands on the right.
    static let dip: CGFloat = 56

    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: rect.minX, y: rect.minY))
        p.addCurve(to: CGPoint(x: rect.maxX, y: rect.minY + Self.dip),
                   control1: CGPoint(x: rect.width * 0.35, y: rect.minY + Self.dip * 1.15),
                   control2: CGPoint(x: rect.width * 0.7, y: rect.minY + Self.dip * 0.95))
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        p.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        p.closeSubpath()
        return p
    }
}

private struct OutlinedField: ViewModifier {
    func body(content: Content) -> some View {
        content
            .padding(.horizontal, 16)
            .frame(minHeight: 48)
            .overlay(Capsule().stroke(Color.secondary.opacity(0.35), lineWidth: 1))
    }
}

/// Staggered fade-and-rise for each form row as it is inserted.
private struct Reveal: ViewModifier {
    let order: Int
    let reduceMotion: Bool
    @State private var shown = false

    func body(content: Content) -> some View {
        content
            .opacity(shown ? 1 : 0)
            .offset(y: shown ? 0 : 14)
            .onAppear {
                guard !reduceMotion else { shown = true; return }
                withAnimation(.easeOut(duration: 0.4).delay(Double(order) * 0.07)) { shown = true }
            }
    }
}

private extension View {
    func reveal(order: Int, reduceMotion: Bool) -> some View {
        modifier(Reveal(order: order, reduceMotion: reduceMotion))
    }
}
