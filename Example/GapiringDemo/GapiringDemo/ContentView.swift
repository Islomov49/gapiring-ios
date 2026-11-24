import Gapiring
import SwiftUI

struct ContentView: View {
    @StateObject private var demo = Demo()

    var body: some View {
        NavigationView {
            Form {
                Section("Line") {
                    Picker("Line", selection: $demo.selected) {
                        ForEach(Demo.lines.indices, id: \.self) { Text("\($0 + 1)").tag($0) }
                    }
                    .pickerStyle(.segmented)
                    let line = Demo.lines[demo.selected]
                    Text(line.text)
                    Text("\(line.voice) · \(line.role) · \(line.manner)")
                        .font(.footnote)
                        .foregroundColor(.secondary)
                }

                Section {
                    HStack(spacing: 12) {
                        Button { demo.play() } label: {
                            Text("Play").frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(demo.busy)
                        .accessibilityIdentifier("play")

                        Button { demo.stop() } label: {
                            Text("Stop").frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                        .disabled(!demo.playing)
                        .accessibilityIdentifier("stop")
                    }
                    .controlSize(.large)

                    Button { demo.measure() } label: {
                        Text("Measure").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                    .disabled(demo.busy)
                    .accessibilityIdentifier("measure")
                } footer: {
                    HStack(spacing: 6) {
                        if demo.busy { ProgressView() }
                        Text(demo.status).accessibilityIdentifier("status")
                    }
                }

                if !demo.report.isEmpty {
                    Section("Measurements") {
                        ForEach(demo.report, id: \.self) { Text($0).font(.system(.footnote, design: .monospaced)) }
                    }
                }
            }
            .navigationTitle("Gapiring \(Gapiring.version)")
        }
        .navigationViewStyle(.stack)
        .onAppear { demo.load() }
    }
}
