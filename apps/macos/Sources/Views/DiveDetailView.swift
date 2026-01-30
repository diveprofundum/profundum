import SwiftUI
import DivelogCore

struct DiveDetailView: View {
    @EnvironmentObject var appState: AppState
    let dive: Dive
    @State private var samples: [DiveSample] = []
    @State private var stats: DiveStats?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                // Header
                headerSection

                Divider()

                // Stats grid
                statsSection

                Divider()

                // Depth profile
                if !samples.isEmpty {
                    depthProfileSection
                }

                Divider()

                // Gas info for CCR
                if dive.isCcr {
                    ccrSection
                }

                Spacer()
            }
            .padding()
        }
        .task {
            await loadSamples()
        }
    }

    private var headerSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(formatDate(dive.startTimeUnix))
                .font(.title)

            HStack(spacing: 12) {
                if dive.isCcr {
                    Badge(text: "CCR", color: .blue)
                }
                if dive.decoRequired {
                    Badge(text: "Deco Required", color: .orange)
                }
            }
        }
    }

    private var statsSection: some View {
        LazyVGrid(columns: [
            GridItem(.flexible()),
            GridItem(.flexible()),
            GridItem(.flexible()),
            GridItem(.flexible())
        ], spacing: 16) {
            StatCard(title: "Max Depth", value: String(format: "%.1f m", dive.maxDepthM))
            StatCard(title: "Avg Depth", value: String(format: "%.1f m", dive.avgDepthM))
            StatCard(title: "Bottom Time", value: "\(dive.bottomTimeSec / 60) min")
            StatCard(title: "Total Time", value: formatTotalTime())

            if dive.cnsPercent > 0 {
                StatCard(title: "CNS", value: String(format: "%.0f%%", dive.cnsPercent),
                         color: dive.cnsPercent > 80 ? .orange : nil)
            }
            if dive.otu > 0 {
                StatCard(title: "OTU", value: String(format: "%.0f", dive.otu))
            }

            if let stats = stats {
                StatCard(title: "Min Temp", value: String(format: "%.1f°C", stats.minTempC))
                StatCard(title: "Max Temp", value: String(format: "%.1f°C", stats.maxTempC))
            }
        }
    }

    private var depthProfileSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Depth Profile")
                .font(.headline)

            DepthProfileChart(samples: samples)
                .frame(height: 200)
                .background(Color(nsColor: .controlBackgroundColor))
                .cornerRadius(8)
        }
    }

    private var ccrSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("CCR Information")
                .font(.headline)

            LazyVGrid(columns: [
                GridItem(.flexible()),
                GridItem(.flexible()),
            ], spacing: 16) {
                if let o2Rate = dive.o2RateCuftMin {
                    StatCard(title: "O2 Rate", value: String(format: "%.2f cuft/min", o2Rate))
                }
                if let o2Consumed = dive.o2ConsumedPsi {
                    StatCard(title: "O2 Used", value: String(format: "%.0f psi", o2Consumed))
                }
            }
        }
    }

    private func formatDate(_ unix: Int64) -> String {
        let date = Date(timeIntervalSince1970: TimeInterval(unix))
        let formatter = DateFormatter()
        formatter.dateStyle = .full
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }

    private func formatTotalTime() -> String {
        let total = dive.endTimeUnix - dive.startTimeUnix
        let minutes = total / 60
        return "\(minutes) min"
    }

    private func loadSamples() async {
        do {
            samples = try appState.diveService.getSamples(diveId: dive.id)

            // Compute stats using Rust core
            let diveInput = DiveInput(
                startTimeUnix: dive.startTimeUnix,
                endTimeUnix: dive.endTimeUnix,
                bottomTimeSec: dive.bottomTimeSec
            )

            let sampleInputs = samples.map { sample in
                SampleInput(
                    tSec: sample.tSec,
                    depthM: sample.depthM,
                    tempC: sample.tempC,
                    setpointPpo2: sample.setpointPpo2,
                    ceilingM: sample.ceilingM,
                    gf99: sample.gf99
                )
            }

            stats = DivelogCompute.computeDiveStats(dive: diveInput, samples: sampleInputs)
        } catch {
            print("Failed to load samples: \(error)")
        }
    }
}

struct Badge: View {
    let text: String
    let color: Color

    var body: some View {
        Text(text)
            .font(.caption)
            .fontWeight(.medium)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(color.opacity(0.2))
            .foregroundColor(color)
            .cornerRadius(6)
    }
}

struct StatCard: View {
    let title: String
    let value: String
    var color: Color? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption)
                .foregroundColor(.secondary)
            Text(value)
                .font(.title3)
                .fontWeight(.semibold)
                .foregroundColor(color)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(Color(nsColor: .controlBackgroundColor))
        .cornerRadius(8)
    }
}
