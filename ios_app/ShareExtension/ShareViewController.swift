// ShareViewController.swift - "Teilen → BambuController" für STL/3MF aus Dateien, Safari, Mail.
import UIKit
import Social
import UniformTypeIdentifiers

final class ShareViewController: UIViewController {
    private let allowedExts = ["stl", "3mf", "obj", "step"]
    /// 100 MB im Extension-Prozess (Speicherlimit) — Größeres bitte direkt in der App hochladen.
    private let maxBytes = 100 * 1024 * 1024
    private var fileData: Data?
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

    // MARK: - Datei aus Extension-Context holen (mehrere Typen, nicht nur fileURL)

    private func extractFile() {
        guard let items = extensionContext?.inputItems as? [NSExtensionItem], !items.isEmpty else {
            status("Keine Datei gefunden.", ok: false); return
        }
        // Alle Attachments einsammeln (Dateien-App, Mail, Safari liefern je nach
        // Quelle fileURL, public.data oder public.file-url — nicht nur fileURL).
        var providers: [NSItemProvider] = []
        for item in items { providers.append(contentsOf: item.attachments ?? []) }
        guard !providers.isEmpty else { status("Keine Datei gefunden.", ok: false); return }

        let fileURLId = UTType.fileURL.identifier
        let dataId = UTType.data.identifier
        // 1) Bevorzugt: echte Datei-URL (ohne Umweg über RAM)
        if let p = providers.first(where: { $0.hasItemConformingToTypeIdentifier(fileURLId) }) {
            p.loadItem(forTypeIdentifier: fileURLId, options: nil) { [weak self] item, _ in
                DispatchQueue.main.async { self?.handleFileURL(item as? URL) }
            }
            return
        }
        // 2) Fallback: rohe Daten (z. B. aus Mail-Anhang), Name aus Provider raten
        if let p = providers.first(where: { $0.hasItemConformingToTypeIdentifier(dataId) }) {
            let guess = p.suggestedName ?? "model.stl"
            p.loadItem(forTypeIdentifier: dataId, options: nil) { [weak self] item, _ in
                DispatchQueue.main.async {
                    guard let self = self else { return }
                    if let url = item as? URL { self.handleFileURL(url); return }
                    guard let data = item as? Data else {
                        self.status("Datei konnte nicht gelesen werden.", ok: false); return
                    }
                    self.handleData(data, name: guess)
                }
            }
            return
        }
        status("Dieser Inhalt ist keine Datei (STL/3MF/OBJ/STEP erwartet).", ok: false)
    }

    private func handleFileURL(_ url: URL?) {
        guard let url = url else { status("Datei konnte nicht gelesen werden.", ok: false); return }
        let ext = url.pathExtension.lowercased()
        guard allowedExts.contains(ext) else {
            status("„.\(ext)“ wird nicht unterstützt (STL, 3MF, OBJ, STEP).", ok: false); return
        }
        let needsStop = url.startAccessingSecurityScopedResource()
        defer { if needsStop { url.stopAccessingSecurityScopedResource() } }
        // Größe VOR dem Einlesen prüfen (Extension-Speicher ist knapp)
        if let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
           let bytes = attrs[.size] as? NSNumber, bytes.intValue > maxBytes {
            status("Datei zu groß (\(bytes.intValue / 1_048_576) MB, max. 100 MB per Teilen). Bitte direkt in der App hochladen.", ok: false)
            return
        }
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else {
            status("Datei kann nicht gelesen werden.", ok: false); return
        }
        handleData(data, name: url.lastPathComponent)
    }

    private func handleData(_ data: Data, name: String) {
        if data.count > maxBytes {
            status("Datei zu groß (\(data.count / 1_048_576) MB, max. 100 MB per Teilen). Bitte direkt in der App hochladen.", ok: false)
            return
        }
        if data.isEmpty {
            status("Datei ist leer.", ok: false); return
        }
        let clean = URL(fileURLWithPath: name).lastPathComponent
        guard !clean.isEmpty else { status("Ungültiger Dateiname.", ok: false); return }
        let ext = (clean as NSString).pathExtension.lowercased()
        guard allowedExts.contains(ext) else {
            status("„.\(ext)“ wird nicht unterstützt (STL, 3MF, OBJ, STEP).", ok: false); return
        }
        self.fileData = data
        self.fileName = clean
        self.status("Bereit: \(clean) (\(data.count / 1024) KB). Vorschau + Slicen & Starten danach in der App.", ok: true)
        self.sendButton.isEnabled = true
    }

    // MARK: - Upload (multipart)

    @objc private func send() {
        guard let fileData = fileData else { return }
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

        URLSession.shared.uploadTask(with: req, from: body) { [weak self] data, resp, err in
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.spinner.stopAnimating()
                if let err = err { self.status("Fehler: \(err.localizedDescription)", ok: false); self.sendButton.isEnabled = true; return }
                if let http = resp as? HTTPURLResponse, 200...299 ~= http.statusCode {
                    self.status("✅ Hochgeladen! 3D-Vorschau + Slicen & Druck starten in der App unter „Dateien“.", ok: true)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { self.done() }
                } else if let http = resp as? HTTPURLResponse, http.statusCode == 413 {
                    self.status("Datei zu groß für den Pi. Kleineres Modell wählen.", ok: false); self.sendButton.isEnabled = true
                } else if let http = resp as? HTTPURLResponse, http.statusCode == 400,
                          let data = data, let msg = String(data: data, encoding: .utf8) {
                    self.status("Abgelehnt: \(msg.prefix(160))", ok: false); self.sendButton.isEnabled = true
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
