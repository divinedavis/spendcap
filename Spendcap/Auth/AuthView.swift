import SwiftUI

struct AuthView: View {
    @EnvironmentObject var auth: AuthViewModel
    @State private var email = ""
    @State private var password = ""
    @State private var isSigningUp = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 20) {
                Spacer()

                VStack(spacing: 8) {
                    SpendcapIcon(size: 88)
                        .padding(.bottom, 4)
                    Text("Spendcap")
                        .font(.largeTitle.bold())
                    Text("Know the moment you're over budget.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                VStack(spacing: 12) {
                    TextField("Email", text: $email)
                        .textContentType(.emailAddress)
                        .keyboardType(.emailAddress)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .textFieldStyle(.roundedBorder)
                        .accessibilityIdentifier("auth.email")

                    SecureField("Password", text: $password)
                        .textContentType(isSigningUp ? .newPassword : .password)
                        .textFieldStyle(.roundedBorder)
                        .accessibilityIdentifier("auth.password")
                }
                .padding(.horizontal)

                if let error = auth.errorMessage {
                    Text(error)
                        .font(.footnote)
                        .foregroundStyle(.red)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal)
                        .accessibilityIdentifier("auth.error")
                }

                if let notice = auth.noticeMessage {
                    Label(notice, systemImage: "envelope.badge")
                        .font(.footnote)
                        .foregroundStyle(.blue)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal)
                        .accessibilityIdentifier("auth.notice")
                }

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
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(email.isEmpty || password.isEmpty || auth.isLoading)
                .padding(.horizontal)
                .accessibilityIdentifier("auth.submit")

                Button(isSigningUp ? "Have an account? Sign in" : "New here? Create an account") {
                    isSigningUp.toggle()
                    auth.errorMessage = nil
                    auth.noticeMessage = nil
                }
                .font(.footnote)
                .accessibilityIdentifier("auth.toggleMode")

                Spacer()
                Spacer()
            }
            .overlay {
                if auth.isLoading { ProgressView() }
            }
        }
    }
}
