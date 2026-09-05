// PrinterDiagramView.swift - Apple-clean.
//
// Übersicht: großes Hero-Bild auf Weiß, 2 neutrale Hotspots, keine Temps.
// Tap Bett  -> erstes Bild (Bett-Nahaufnahme), Temp schwarz daneben auf Weiß.
// Tap Düse  -> rechtes Bild (Print Head), Temp links davon, oben klein "Print Head".
// Bilder: als `bed-detail.png` (1. Bild) + `nozzle-detail.png` (2. Bild)
// nach ios_app/BambuController/Resources/Images/ legen.
import SwiftUI
import UIKit

struct PrinterDiagramView: View {
    let status: PrinterStatus?

    @State private var selected: PartSpot? = nil

    var body: some View {
        VStack(spacing: 0) {
            if let spot = selected {
                detailView(for: spot)
                    .transition(.opacity.combined(with: .scale(scale: 0.98)))
            } else {
                overview
                    .transition(.opacity)
            }
        }
        .background(Color(.systemBackground))
        .clipShape(RoundedRectangle(cornerRadius: AppTheme.cardRadius, style: .continuous))
        .animation(.spring(response: 0.5, dampingFraction: 0.88), value: selected?.id)
    }

    // MARK: - Übersicht

    private var overview: some View {
        VStack(spacing: 0) {
            GeometryReader { geo in
                let size = geo.size
                ZStack {
                    if let ui = PrinterHeroImage.load() {
                        Image(uiImage: ui)
                            .resizable()
                            .scaledToFit()
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .padding(.vertical, 6)
                            .accessibilityLabel("Bambu Lab A1")
                    } else {
                        Image(systemName: "printer.fill")
                            .font(.system(size: 90))
                            .foregroundColor(.secondary)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                    ForEach(PartSpot.all) { spot in
                        HotspotButton { select(spot) }
                            .position(x: size.width * spot.anchor.x, y: size.height * spot.anchor.y)
                            .accessibilityLabel("\(spot.title) anzeigen")
                    }
                }
                .frame(width: size.width, height: size.height)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 320)

            HStack(spacing: 6) {
                Image(systemName: "hand.tap").foregroundColor(.secondary)
                Text("Tippe auf einen Punkt")
                    .font(.subheadline).foregroundColor(.secondary)
                Spacer()
            }
            .padding(.horizontal, 4).padding(.vertical, 10)
            .accessibilityHidden(true)
        }
        .padding(12)
    }

    // MARK: - Detail: immersiv groß, Zahl direkt daneben (Apple-Stil)

    @ViewBuilder
    private func detailView(for spot: PartSpot) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(spot.kicker)
                    .font(.caption2.weight(.medium))
                    .foregroundColor(.secondary)
                    .textCase(.uppercase)
                    .tracking(0.8)
                Spacer()
                Button {
                    withAnimation(.spring(response: 0.5, dampingFraction: 0.88)) { selected = nil }
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title3).foregroundColor(Color(.tertiaryLabel))
                        .frame(width: 44, height: 44)
                }
                .accessibilityLabel("Zurück")
            }
            .padding(.horizontal, 12).padding(.top, 4)

            // Bild + Zahl nebeneinander, beides groß, viel Weißraum
            HStack(spacing: 4) {
                if spot.kind == .nozzle {
                    tempBlock(for: spot)
                        .frame(minWidth: 120, alignment: .leading)
                        .padding(.leading, 16)
                    detailImage(for: spot)
                        .frame(maxWidth: .infinity)
                        .frame(height: 300)
                } else {
                    detailImage(for: spot)
                        .frame(maxWidth: .infinity)
                        .frame(height: 300)
                    tempBlock(for: spot)
                        .frame(minWidth: 120, alignment: .trailing)
                        .padding(.trailing, 16)
                }
            }
            .padding(.bottom, 16)
        }
        .background(Color(.systemBackground))
    }

    @ViewBuilder
    private func tempBlock(for spot: PartSpot) -> some View {
        if let s = status {
            VStack(alignment: spot.kind == .nozzle ? .leading : .trailing, spacing: 2) {
                Text(spot.degrees(status: s))
                    .font(.system(size: 52, weight: .bold, design: .rounded))
                    .foregroundColor(.primary)
                    .monospacedDigit()
                    .contentTransition(.numericText())
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                Text(spot.targetShort(status: s))
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .monospacedDigit()
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel(spot.a11y(status: s))
        } else {
            Text("–")
                .font(.system(size: 52, weight: .bold, design: .rounded))
                .foregroundColor(.secondary)
        }
    }

    @ViewBuilder
    private func detailImage(for spot: PartSpot) -> some View {
        if let ui = PartDetailImage.load(for: spot) {
            Image(uiImage: ui)
                .resizable()
                .scaledToFit()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .accessibilityLabel(spot.title)
        } else {
            ZStack {
                Color(.secondarySystemGroupedBackground)
                VStack(spacing: 8) {
                    Image(systemName: spot.icon)
                        .font(.system(size: 44)).foregroundColor(.secondary)
                    Text("Fehlt: \(spot.placeholderFile)")
                        .font(.caption).foregroundColor(.secondary)
                }
                .padding()
            }
        }
    }

    private func select(_ spot: PartSpot) {
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        withAnimation(.spring(response: 0.5, dampingFraction: 0.88)) { selected = spot }
    }
}

// MARK: - Spots

struct PartSpot: Identifiable, Equatable {
    enum Kind { case nozzle, bed }
    let id: String
    let kind: Kind
    let title: String        // "Düse" / "Druckbett"
    let kicker: String       // winzig oben links: "Print Head" / "Heatbed"
    let icon: String
    let anchor: CGPoint      // Hotspot im Übersichtsbild
    let placeholderFile: String

    static let all: [PartSpot] = [
        PartSpot(id: "nozzle", kind: .nozzle, title: "Düse", kicker: "Print Head",
                 icon: "thermometer", anchor: CGPoint(x: 0.545, y: 0.34),
                 placeholderFile: "nozzle-detail.png"),
        PartSpot(id: "bed", kind: .bed, title: "Druckbett", kicker: "Heatbed",
                 icon: "square.stack.3d.up", anchor: CGPoint(x: 0.46, y: 0.78),
                 placeholderFile: "bed-detail.jpg"),
    ]

    func degrees(status s: PrinterStatus) -> String {
        switch kind {
        case .nozzle: return "\(Int(s.nozzleTemp))°"
        case .bed: return "\(Int(s.bedTemp))°"
        }
    }
    func targetShort(status s: PrinterStatus) -> String {
        switch kind {
        case .nozzle: return "/ \(Int(s.nozzleTargetTemp))°"
        case .bed: return "/ \(Int(s.bedTargetTemp))°"
        }
    }
    func a11y(status: PrinterStatus) -> String {
        switch kind {
        case .nozzle: return "Print Head: \(Int(status.nozzleTemp)) Grad, Ziel \(Int(status.nozzleTargetTemp)) Grad."
        case .bed: return "Heatbed: \(Int(status.bedTemp)) Grad, Ziel \(Int(status.bedTargetTemp)) Grad."
        }
    }
}

// MARK: - Neutraler Hotspot (Glas + Plus)

private struct HotspotButton: View {
    let action: () -> Void
    @State private var pulse = false
    var body: some View {
        Button(action: action) {
            ZStack {
                Circle()
                    .fill(.ultraThinMaterial)
                    .frame(width: 38, height: 38)
                    .overlay(Circle().stroke(Color.primary.opacity(0.14), lineWidth: 0.5))
                    .shadow(color: .black.opacity(0.14), radius: 6, x: 0, y: 2)
                Circle()
                    .stroke(Color.primary.opacity(0.22), lineWidth: 1.5)
                    .frame(width: 38, height: 38)
                    .scaleEffect(pulse ? 1.45 : 1)
                    .opacity(pulse ? 0 : 0.8)
                    .animation(.easeOut(duration: 2.2).repeatForever(autoreverses: false), value: pulse)
                Image(systemName: "plus")
                    .font(.body.weight(.medium))
                    .foregroundColor(.primary)
            }
        }
        .buttonStyle(.plain)
        .frame(width: 60, height: 60)
        .contentShape(Rectangle())
        .onAppear { pulse = true }
    }
}

// MARK: - Loader

enum PrinterHeroImage {
    static func load() -> UIImage? {
        if let img = UIImage(named: "printer-hero") { return img }
        if let img = UIImage(named: "printer-hero.png") { return img }
        let bundle = Bundle.main
        for (subdir, base) in [(nil as String?, "printer-hero"), ("Images", "printer-hero")] {
            if let url = bundle.url(forResource: base, withExtension: "png", subdirectory: subdir),
               let img = UIImage(contentsOfFile: url.path) { return img }
        }
        if let resURL = bundle.resourceURL,
           let e = FileManager.default.enumerator(at: resURL, includingPropertiesForKeys: nil) {
            for case let url as URL in e where url.lastPathComponent == "printer-hero.png" {
                if let img = UIImage(contentsOfFile: url.path) { return img }
            }
        }
        return nil
    }
}

enum PartDetailImage {
    static func load(for spot: PartSpot) -> UIImage? {
        let bases: [String]
        switch spot.kind {
        case .nozzle: bases = ["nozzle-detail", "nozzle-closeup", "nozzle-nah", "duese-detail"]
        case .bed: bases = ["bed-detail", "bed-closeup", "bed-nah", "bett-detail"]
        }
        for base in bases {
            if let img = UIImage(named: base) { return img }
            if let url = Bundle.main.url(forResource: base, withExtension: "png"),
               let img = UIImage(contentsOfFile: url.path) { return img }
            for ext in ["png", "jpg", "jpeg", "heic", "webp"] {
                if let url = Bundle.main.url(forResource: base, withExtension: ext),
                   let img = UIImage(contentsOfFile: url.path) { return img }
                if let url = Bundle.main.url(forResource: base, withExtension: ext, subdirectory: "Images"),
                   let img = UIImage(contentsOfFile: url.path) { return img }
            }
        }
        return nil
    }
}

#Preview("Diagramm") {
    PrinterDiagramView(status: DemoService.shared.status)
        .padding()
}
