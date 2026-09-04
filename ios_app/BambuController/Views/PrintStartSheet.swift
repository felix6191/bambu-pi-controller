// PrintStartSheet.swift - Sheet for starting a new print
import SwiftUI

struct PrintStartSheet: View {
    @Environment(\.dismiss) var dismiss
    @StateObject private var vm = PrinterViewModel.shared
    @State private var filename = ""
    @State private var bedTemp = 60
    @State private var nozzleTemp = 210
    @State private var loading = false

    var body: some View {
        NavigationStack {
            Form {
                Section("Druckdatei") { TextField("Dateiname (auf SD-Karte)", text: $filename).textInputAutocapitalization(.never) }
                Section("Temperaturen") { Stepper("Düse: \(nozzleTemp)°", value: $nozzleTemp, in: 0...300, step: 5); Stepper("Bett: \(bedTemp)°", value: $bedTemp, in: 0...120, step: 5) }
                Section { Button { loading = true; Task { await vm.startPrint(filename: filename, bedTemp: bedTemp, nozzleTemp: nozzleTemp); loading = false; dismiss() } } label: { if loading { ProgressView().frame(maxWidth: .infinity) } else { Text("Druck starten").frame(maxWidth: .infinity) } }.disabled(filename.isEmpty || loading) }
            }.navigationTitle("Neuen Druck starten").navigationBarTitleDisplayMode(.inline).toolbar { ToolbarItem(placement: .navigationBarLeading) { Button("Abbrechen") { dismiss() } } }
        }
    }
}