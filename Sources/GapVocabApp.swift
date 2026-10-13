import SwiftUI

/// Gap Vocab for iPhone.
///
/// The app shows your Gap Vocab website in a web view, but replaces the answer box with a
/// native one so iOS can switch between your Japanese and English keyboards automatically.
@main
struct GapVocabApp: App {
    /// Your server's address (e.g. https://bot-vnic.xxxx.ts.net), saved after first launch.
    @AppStorage("serverURL") private var serverURL = ""

    var body: some Scene {
        WindowGroup {
            if let url = URL(string: serverURL), url.scheme == "https", url.host != nil {
                BridgeView(url: url)
                    .ignoresSafeArea()      // the web page handles the notch / home bar itself
            } else {
                SetupView()
            }
        }
    }
}

/// First launch: ask for the server address.
struct SetupView: View {
    @AppStorage("serverURL") private var serverURL = ""
    @State private var draft = "https://"

    private var draftIsValid: Bool {
        guard let url = URL(string: draft.trimmingCharacters(in: .whitespacesAndNewlines)) else { return false }
        return url.scheme == "https" && !(url.host ?? "").isEmpty
    }

    var body: some View {
        VStack(spacing: 16) {
            Text("Gap Vocab").font(.largeTitle.bold())
            Text("Enter your server's address. You can change it later from the connection error screen.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
            TextField("https://…ts.net", text: $draft)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .keyboardType(.URL)
                .textFieldStyle(.roundedBorder)
            Button("Save") {
                serverURL = draft.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            .buttonStyle(.borderedProminent)
            .disabled(!draftIsValid)
        }
        .padding(24)
    }
}

/// Wraps the UIKit view controller so SwiftUI can show it.
struct BridgeView: UIViewControllerRepresentable {
    let url: URL
    func makeUIViewController(context: Context) -> BridgeViewController { BridgeViewController(url: url) }
    func updateUIViewController(_ controller: BridgeViewController, context: Context) {}
}
