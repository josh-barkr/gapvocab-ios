import AVFoundation
import UIKit
import WebKit

/// A text field that asks iOS for a particular keyboard language ("ja" or "en").
///
/// iOS checks `textInputMode` when the field becomes active, and switches to the first
/// keyboard you've installed in that language. If you have several Japanese keyboards
/// (e.g. Kana and Romaji), put the one you want first in Settings > General > Keyboard > Keyboards.
final class LangTextField: UITextField {
    let lang: String

    init(lang: String) {
        self.lang = lang
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var textInputMode: UITextInputMode? {
        UITextInputMode.activeInputModes.first { ($0.primaryLanguage ?? "").hasPrefix(lang) }
            ?? super.textInputMode
    }

    /// Backup: iOS also remembers the last keyboard used for each identifier.
    override var textInputContextIdentifier: String? { "gapvocab.\(lang)" }
}

/// Shows the Gap Vocab site and provides the native answer bar.
///
/// Messages from the page (window.webkit.messageHandlers.gv.postMessage):
///   {type: "ask", lang: "ja" | "en", placeholder}   show the answer bar with that keyboard
///   {type: "result", result: "ok" | "bad" | ...}     colour the box and buzz
///   {type: "hide"}                                    hide the answer bar
///   {type: "speak", text, rate, voice}               say text with an installed voice
///   {type: "stopSpeaking"}                           stop talking
/// Answers go back to the page with window.gvSubmit(text); finished speech with window.gvSpeechDone().
///
/// Speech goes through the app (AVSpeechSynthesizer) because iOS only lets web pages use some
/// voices; the app can use every voice you've downloaded, e.g. Otoya (Enhanced).
final class BridgeViewController: UIViewController, WKScriptMessageHandler, WKNavigationDelegate, WKUIDelegate,
                                  UITextFieldDelegate, AVSpeechSynthesizerDelegate {
    private let url: URL
    private var webView: WKWebView!
    private let bar = UIView()
    private let jaField = LangTextField(lang: "ja")
    private let enField = LangTextField(lang: "en")
    private var barHeight: NSLayoutConstraint!
    private let errorView = UIView()          // full-screen cover with the message centred
    private let haptics = UINotificationFeedbackGenerator()
    private let speech = AVSpeechSynthesizer()

    init(url: URL) {
        self.url = url
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground

        // --- Web view: the normal Gap Vocab site ---
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()                 // keeps your login between launches
        config.userContentController.add(self, name: "gv")   // page -> app messages
        // Tell the page which Japanese voices are installed (it shows them in Settings > Voice)
        let voices = AVSpeechSynthesisVoice.speechVoices()
            .filter { $0.language.hasPrefix("ja") }
            .map { ["voiceURI": $0.identifier, "name": $0.name, "lang": $0.language, "quality": $0.quality.rawValue] as [String: Any] }
        if let data = try? JSONSerialization.data(withJSONObject: voices),
           let json = String(data: data, encoding: .utf8) {
            config.userContentController.addUserScript(WKUserScript(
                source: "window.__nativeVoices = \(json);", injectionTime: .atDocumentStart, forMainFrameOnly: true))
        }
        speech.delegate = self
        // Play speech even when the ring/silent switch is on, like other study apps
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio, options: [.duckOthers])
        webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.scrollView.contentInsetAdjustmentBehavior = .never   // the page handles safe areas
        webView.isOpaque = false
        webView.backgroundColor = .systemBackground
        let refresh = UIRefreshControl()                     // pull down to reload
        refresh.addTarget(self, action: #selector(reload), for: .valueChanged)
        webView.scrollView.refreshControl = refresh

        // --- Answer bar: sits on top of the keyboard while a question is showing ---
        bar.backgroundColor = .secondarySystemBackground
        bar.clipsToBounds = true
        for field in [jaField, enField] {
            field.delegate = self
            field.borderStyle = .roundedRect
            field.font = .systemFont(ofSize: 22)
            field.textAlignment = .center
            field.autocorrectionType = .no
            field.autocapitalizationType = .none
            field.spellCheckingType = .no
            field.smartQuotesType = .no
            field.returnKeyType = .go
            field.alpha = 0
            field.translatesAutoresizingMaskIntoConstraints = false
            bar.addSubview(field)
            NSLayoutConstraint.activate([
                field.leadingAnchor.constraint(equalTo: bar.leadingAnchor, constant: 12),
                field.trailingAnchor.constraint(equalTo: bar.trailingAnchor, constant: -12),
                field.centerYAnchor.constraint(equalTo: bar.centerYAnchor),
                field.heightAnchor.constraint(equalToConstant: 48),
            ])
        }

        // --- Layout: web view on top, answer bar glued to the top of the keyboard ---
        for subview in [webView!, bar] as [UIView] {
            subview.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(subview)
        }
        if #available(iOS 17.0, *) {
            view.keyboardLayoutGuide.usesBottomSafeArea = false   // no gap above the home bar
        }
        barHeight = bar.heightAnchor.constraint(equalToConstant: 0)
        NSLayoutConstraint.activate([
            webView.topAnchor.constraint(equalTo: view.topAnchor),
            webView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            webView.bottomAnchor.constraint(equalTo: bar.topAnchor),
            bar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            bar.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            bar.bottomAnchor.constraint(equalTo: view.keyboardLayoutGuide.topAnchor),
            barHeight,
        ])

        setUpErrorView()
        haptics.prepare()
        webView.load(URLRequest(url: url))
    }

    // MARK: - Messages from the page

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any], let type = body["type"] as? String else { return }
        switch type {
        case "ask":
            let field = (body["lang"] as? String) == "en" ? enField : jaField
            let other = field === jaField ? enField : jaField
            field.placeholder = body["placeholder"] as? String
            field.text = ""
            field.backgroundColor = .systemBackground
            showBar(true)
            field.alpha = 1
            other.alpha = 0
            // Moving focus from one field to the other makes iOS swap keyboards smoothly.
            if !field.isFirstResponder { field.becomeFirstResponder() }

        case "result":
            let field = enField.isFirstResponder ? enField : jaField
            switch body["result"] as? String {
            case "ok":
                field.backgroundColor = UIColor.systemGreen.withAlphaComponent(0.25)
                haptics.notificationOccurred(.success)
            case "bad":
                field.backgroundColor = UIColor.systemRed.withAlphaComponent(0.25)
                haptics.notificationOccurred(.error)
            default:                                   // empty, or romaji left in a kana answer
                shake(field)
                haptics.notificationOccurred(.warning)
            }

        case "hide":
            view.endEditing(true)
            showBar(false)

        case "speak":
            let text = body["text"] as? String ?? ""
            let rate = body["rate"] as? Double ?? 0.8
            speech.stopSpeaking(at: .immediate)
            let utterance = AVSpeechUtterance(string: text)
            utterance.voice = AVSpeechSynthesisVoice(identifier: body["voice"] as? String ?? "")
                ?? AVSpeechSynthesisVoice(language: "ja-JP")
            // the page uses 1.0 = normal speed; Apple's normal speed is AVSpeechUtteranceDefaultSpeechRate
            utterance.rate = AVSpeechUtteranceDefaultSpeechRate * Float(rate)
            try? AVAudioSession.sharedInstance().setActive(true)
            speech.speak(utterance)

        case "stopSpeaking":
            speech.stopSpeaking(at: .immediate)

        default:
            break
        }
    }

    // MARK: - Speech

    /// Finished a sentence: let the page move on (e.g. "Play chapter" goes to the next sentence).
    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        webView.evaluateJavaScript(
            "(function(){ var f = window.gvSpeechDone; window.gvSpeechDone = null; if (f) f(); })()",
            completionHandler: nil)
    }

    // MARK: - Answer bar

    /// Return / Go on the keyboard: send the answer to the page.
    func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        let text = textField.text ?? ""
        // Wrap the answer as JSON so quotes or backslashes can't break the JavaScript.
        let json = (try? JSONSerialization.data(withJSONObject: [text]))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "[\"\"]"
        webView.evaluateJavaScript("window.gvSubmit && window.gvSubmit(\(json)[0])", completionHandler: nil)
        return false
    }

    private func showBar(_ visible: Bool) {
        barHeight.constant = visible ? 64 : 0
        if !visible {
            jaField.alpha = 0
            enField.alpha = 0
        }
        UIView.animate(withDuration: 0.15) { self.view.layoutIfNeeded() }
    }

    private func shake(_ target: UIView) {
        let animation = CAKeyframeAnimation(keyPath: "transform.translation.x")
        animation.values = [-8, 8, -6, 6, 0]
        animation.duration = 0.3
        target.layer.add(animation, forKey: "shake")
    }

    // MARK: - Loading and errors

    @objc private func reload() {
        errorView.isHidden = true
        if webView.url == nil {
            webView.load(URLRequest(url: url))
        } else {
            webView.reload()
        }
    }

    /// Links to other sites (e.g. the Jisho dictionary) open in Safari, not inside the app.
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        if let target = navigationAction.request.url, let host = target.host,
           host != url.host, navigationAction.navigationType == .linkActivated {
            UIApplication.shared.open(target)
            decisionHandler(.cancel)
            return
        }
        decisionHandler(.allow)
    }

    /// Links marked "open in a new tab" (target="_blank") also go to Safari.
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if let target = navigationAction.request.url {
            UIApplication.shared.open(target)
        }
        return nil
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        errorView.isHidden = true
        webView.scrollView.refreshControl?.endRefreshing()
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        showError()
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        showError()
    }

    private func showError() {
        webView.scrollView.refreshControl?.endRefreshing()
        view.endEditing(true)
        showBar(false)
        errorView.isHidden = false
    }

    /// Shown when the server can't be reached: retry, or change the saved address.
    private func setUpErrorView() {
        let label = UILabel()
        label.text = "Can't reach your Gap Vocab server.\nCheck your connection and try again."
        label.numberOfLines = 0
        label.textAlignment = .center

        var retryStyle = UIButton.Configuration.filled()
        retryStyle.title = "Try again"
        let retry = UIButton(configuration: retryStyle, primaryAction: UIAction { [weak self] _ in self?.reload() })

        var changeStyle = UIButton.Configuration.plain()
        changeStyle.title = "Change server address"
        let change = UIButton(configuration: changeStyle, primaryAction: UIAction { _ in
            UserDefaults.standard.removeObject(forKey: "serverURL")   // back to the setup screen
        })

        let stack = UIStackView(arrangedSubviews: [label, retry, change])
        stack.axis = .vertical
        stack.spacing = 16
        stack.alignment = .center
        stack.translatesAutoresizingMaskIntoConstraints = false

        errorView.backgroundColor = .systemBackground
        errorView.isHidden = true
        errorView.translatesAutoresizingMaskIntoConstraints = false
        errorView.addSubview(stack)
        view.addSubview(errorView)
        NSLayoutConstraint.activate([
            errorView.topAnchor.constraint(equalTo: view.topAnchor),
            errorView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            errorView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            errorView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            stack.centerYAnchor.constraint(equalTo: errorView.centerYAnchor),
            stack.leadingAnchor.constraint(equalTo: errorView.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: errorView.trailingAnchor, constant: -24),
        ])
    }
}
