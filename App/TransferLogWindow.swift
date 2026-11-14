import DeviceService
import SwiftUI

/// Transfer log (spec §6, FR-17): every upload and download of the last 7 days, with
/// filters by device, result and direction, and the transfers running now.
struct TransferLogWindow: View {
    @ObservedObject var manager: DeviceManager
    @State private var records: [TransferRecord] = []
    @State private var filter = TransferFilter()
    @State private var confirmClear = false

    var body: some View {
        VStack(spacing: 0) {
            filters.padding(10)
            if !manager.activeTransfers.isEmpty { activeList }
            Table(records) {
                TableColumn("Time") { Text($0.started.formatted(date: .abbreviated, time: .standard)) }
                    .width(min: 140, ideal: 160)
                TableColumn("Device", value: \.deviceName).width(min: 80, ideal: 120)
                TableColumn("File") { record in
                    Text(record.fileName).help(record.path)
                }
                .width(min: 160, ideal: 260)
                TableColumn("") { record in
                    Image(systemName: record.direction == .download ? "arrow.down" : "arrow.up")
                        .help(record.direction == .download ? "Phone to Mac" : "Mac to phone")
                }
                .width(18)
                TableColumn("Size") { Text(Format.bytes($0.bytes)).monospacedDigit() }.width(min: 60, ideal: 80)
                TableColumn("Speed") { Text(Format.speed($0.bytesPerSecond)).monospacedDigit() }.width(min: 70, ideal: 90)
                TableColumn("Duration") { Text(Format.duration($0.duration)).monospacedDigit() }.width(min: 60, ideal: 70)
                TableColumn("Result") { record in result(record.result) }.width(min: 90, ideal: 180)
            }
            .overlay {
                if records.isEmpty {
                    Text("No transfers in the last 7 days match these filters.").foregroundStyle(.secondary)
                }
            }
        }
        .task(id: filter) { await reload() }
        .task {
            for await _ in await manager.monitor.events() { await reload() }
        }
        .confirmationDialog("Clear the transfer log?", isPresented: $confirmClear) {
            Button("Clear Log", role: .destructive) {
                Task {
                    await manager.monitor.log.clear()
                    await reload()
                }
            }
        }
    }

    private var filters: some View {
        HStack {
            Picker("Device", selection: $filter.phoneId) {
                Text("All devices").tag(String?.none)
                ForEach(manager.devices) { Text($0.model).tag(String?.some($0.serial)) }
            }
            .frame(maxWidth: 220)
            Picker("Result", selection: $filter.result) {
                Text("All results").tag(TransferResult.Kind?.none)
                Text("Succeeded").tag(TransferResult.Kind?.some(.succeeded))
                Text("Failed").tag(TransferResult.Kind?.some(.failed))
                Text("Cancelled").tag(TransferResult.Kind?.some(.cancelled))
            }
            .frame(maxWidth: 180)
            Picker("Direction", selection: $filter.direction) {
                Text("Both directions").tag(TransferDirection?.none)
                Text("Phone to Mac").tag(TransferDirection?.some(.download))
                Text("Mac to phone").tag(TransferDirection?.some(.upload))
            }
            .frame(maxWidth: 200)
            TextField("Search file names", text: $filter.text)
                .textFieldStyle(.roundedBorder)
            Button("Clear Log…") { confirmClear = true }
        }
        .labelsHidden()
    }

    private var activeList: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(manager.activeTransfers) { transfer in
                HStack {
                    Image(systemName: transfer.direction == .download ? "arrow.down.circle" : "arrow.up.circle")
                    Text((transfer.path as NSString).lastPathComponent).lineLimit(1)
                    if transfer.total > 0 {
                        ProgressView(value: Double(transfer.completed), total: Double(transfer.total))
                            .frame(maxWidth: 200)
                    } else {
                        ProgressView().controlSize(.small)
                    }
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.bottom, 8)
    }

    @ViewBuilder
    private func result(_ result: TransferResult) -> some View {
        switch result {
        case .succeeded: Label("Done", systemImage: "checkmark.circle").foregroundStyle(.green)
        case .cancelled: Label("Cancelled", systemImage: "xmark.circle").foregroundStyle(.secondary)
        case .failed(let message): Label(message, systemImage: "exclamationmark.triangle").foregroundStyle(.red)
            .help(message)
        }
    }

    private func reload() async {
        records = await manager.monitor.log.entries(matching: filter)
    }
}
