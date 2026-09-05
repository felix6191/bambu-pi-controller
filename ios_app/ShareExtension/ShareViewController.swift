// ShareViewController.swift - "Teilen → BambuController" für STL/3MF aus Dateien, Safari, Mail.
import UIKit
import Social
import MobileCoreServices
import UniformTypeIdentifiers

final class ShareViewController: UIViewController {
    private let allowedExts = ["stl", "3mf", "obj", "step"]
    private var fileURL: URL?
    private var fileName = "model.stl"

    private let statusLabel = UILabel()
    private let urlField = UITextField()
    private let tokenField = UITextField()
    private let sendButton = UIButton(type: .system)
    private let spinner = UIActivityIndicatorView(style: .medium)

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        setupUI()
        urlField.text = UserDefaults.standard.string(forKey: "share.serverURL") ?? ""
        tokenField.text = UserDefaults.standard.string(forKey: "share.apiToken") ?? ""
        extractFile()
    }

    // MARK: - UI (programmatisch, bewusst schlicht)

    private func setupUI() {
        navigationItem.title = "An BambuController senden"
        navigationItem.leftBarButtonItem = UIBarButtonItem(barButtonSystemItem: .cancel, target: self, action: #selector(cancel))
        let stack = UIStackView()
        stack.axis = .vertical; stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
            stack.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 16),
        ])
        statusLabel.numberOfLines = 0
        statusLabel.font = .preferredFont(forTextStyle: .footnote)
        statusLabel.textColor = .secondaryLabel
        statusLabel.text = "Datei wird gelesen …"
        urlField.placeholder = "Server-URL (http://100.x.x.x:8000)"
        urlField.borderStyle = .roundedRect
        urlField.autocapitalizationType = .none
        urlField.autocorrectionType = .no
        urlField.keyboardType = .URL
        tokenField.placeholder = "API-Token"
        tokenField.borderStyle = .roundedRect
        tokenField.isSecureTextEntry = true
        sendButton.setTitle("Zum Pi hochladen", for: .normal)
        sendButton.titleLabel?.font = .boldSystemFont(ofSize: 17)
        sendButton.backgroundColor = UIColor(red: 0, green: 0.7, blue: 0.35, alpha: 1)
        sendButton.setTitleColor(.white, for: .normal)
        sendButton.layer.cornerRadius = 12
        sendButton.heightAnchor.constraint(equalToConstant: 50).isActive = true
        sendButton.addTarget(self, action: #selector(send), for: .touchUpInside)
        sendButton.isEnabled = false
        for v in [statusLabel, urlField, tokenField, sendButton, spinner] { stack.addArrangedSubview(v) }
    }

    // MARK: - Datei aus Extension-Context holen

    private func extractFile() {
        guard let item = extensionContext?.inputItems.first as? NSExtensionItem,
              let provider = item.attachments?.first else {
            status("Keine Datei gefunden.", ok: false); return
        }
        let typeId = UTType.fileURL.identifier
        guard provider.hasItemConformingToTypeIdentifier(typeId) else {
            status("Dieser Inhalt ist keine Datei.", ok: false); return
        }
        provider.loadItem(forTypeIdentifier: typeId, options: nil) { [weak self] item, _ in
            DispatchQueue.main.async {
                guard let self = self else { return }
                guard let url = item as? URL else { self.status("Datei konnte nicht gelesen werden.", ok: false); return }
                let ext = url.pathExtension.lowercased()
                guard self.allowedExts.contains(ext) else {
                    self.status("„.\(ext)“ wird nicht unterstützt (STL, 3MF, OBJ, STEP).", ok: false); return
                }
                self.fileURL = url
                self.fileName = url.lastPathComponent
                self.status("Bereit: \(self.fileName). Slicen & Starten danach in der App.", ok: true)
                self.sendButton.isEnabled = true
            }
        }
    }

    // MARK: - Upload (multipart, direkt als Stream vom File)

    @objc private func send() {
        guard let fileURL = fileURL else { return }
        let base = urlField.text?.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "/$", with: "", options: .regularExpression) ?? ""
        let token = tokenField.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !base.isEmpty, let endpoint = URL(string: base + "/api/v1/files/upload") else {
            status("Bitte zuerst die Server-URL eintragen.", ok: false); return
        }
        guard !token.isEmpty else { status("Bitte zuerst den API-Token eintragen.", ok: false); return }
        UserDefaults.standard.set(base, forKey: "share.serverURL")
        UserDefaults.standard.set(token, forKey: "share.apiToken")
        sendButton.isEnabled = false
        spinner.startAnimating()
        status("Lade hoch …", ok: true)

        let needsStop = fileURL.startAccessingSecurityScopedResource()
        defer { if needsStop { fileURL.stopAccessingSecurityScopedResource() } }
        guard let fileData = try? Data(contentsOf: fileURL) else {
            status("Datei kann nicht gelesen werden.", ok: false); return
        }
        let boundary = "Boundary-\(UUID().uuidString)"
        var req = URLRequest(url: endpoint, timeoutInterval: 600)
        req.httpMethod = "POST"
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        var body = Data()
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"file\"; filename=\"\(fileName)\"\r\n".data(using: .utf8)!)
        body.append("Content-Type: application/octet-stream\r\n\r\n".data(using: .utf8)!)
        body.append(fileData)
        body.append("\r\n--\(boundary)--\r\n".data(using: .utf8)!)

        URLSession.shared.uploadTask(with: req, from: body) { [weak self] _, resp, err in
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.spinner.stopAnimating()
                if let err = err { self.status("Fehler: \(err.localizedDescription)", ok: false); self.sendButton.isEnabled = true; return }
                if let http = resp as? HTTPURLResponse, 200...299 ~= http.statusCode {
                    self.status("✅ Hochgeladen! Slicen & Druck starten geht in der App unter „Dateien\".", ok: true)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { self.done() }
                } else {
                    self.status("Server-Fehler (URL/Token prüfen).", ok: false); self.sendButton.isEnabled = true
                }
            }
        }.resume()
    }

    private func status(_ text: String, ok: Bool) {
        statusLabel.text = text
        statusLabel.textColor = ok ? .secondaryLabel : .systemRed
    }

    @objc private func cancel() {
        extensionContext?.cancelRequest(withError: NSError(domain: "share", code: 0))
    }

    private func done() {
        extensionContext?.completeRequest(returningItems: nil)
    }
}
