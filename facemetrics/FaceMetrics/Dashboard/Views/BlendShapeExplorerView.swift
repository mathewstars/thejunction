import SwiftUI

enum CoefficientSort: String, CaseIterable, Identifiable {
    case name = "Name"
    case value = "Value"
    case maximum = "Max"
    case velocity = "Velocity"
    case activations = "Events"
    var id: String { rawValue }
}

struct BlendShapeExplorerView: View {
    @EnvironmentObject var model: DashboardViewModel
    @State private var search = ""
    @State private var category: BlendShapeCategory? = nil
    @State private var sort: CoefficientSort = .name
    @State private var expanded: Set<String> = []

    private var filtered: [CoefficientSnapshot] {
        var items = model.snapshot.coefficients
        if let category { items = items.filter { $0.category == category } }
        if !search.isEmpty {
            let q = search.lowercased()
            items = items.filter { $0.name.lowercased().contains(q) || $0.id.lowercased().contains(q) }
        }
        switch sort {
        case .name: items.sort { $0.name < $1.name }
        case .value: items.sort { $0.value > $1.value }
        case .maximum: items.sort { ($0.maximum ?? 0) > ($1.maximum ?? 0) }
        case .velocity: items.sort { abs($0.velocity ?? 0) > abs($1.velocity ?? 0) }
        case .activations: items.sort { $0.activationCount > $1.activationCount }
        }
        return items
    }

    var body: some View {
        VStack(spacing: 0) {
            controls
            if model.snapshot.coefficients.isEmpty {
                VStack(spacing: 8) {
                    Text("No coefficients yet").font(.headline).foregroundStyle(Theme.textPrimary)
                    Text("Coefficients appear as soon as ARKit tracks a face. Every key in ARFaceAnchor.blendShapes is listed; nothing is hardcoded.")
                        .font(.caption).foregroundStyle(Theme.textSecondary).multilineTextAlignment(.center)
                }
                .padding(30)
                Spacer()
            } else {
                ScrollView {
                    LazyVStack(spacing: 6) {
                        ForEach(filtered) { c in
                            CoefficientRow(c: c, expanded: expanded.contains(c.id)) {
                                if expanded.contains(c.id) { expanded.remove(c.id) } else { expanded.insert(c.id) }
                            }
                        }
                        Text("\(filtered.count) of \(model.snapshot.coefficients.count) coefficients. Raw values 0...1 from ARKit; min, max, mean and velocity are computed by the app over this tracking run.")
                            .font(.caption2).foregroundStyle(Theme.textTertiary)
                            .padding(.top, 6)
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                }
            }
        }
    }

    private var controls: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass").foregroundStyle(Theme.textSecondary)
                    TextField("Search coefficient", text: $search)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .foregroundStyle(Theme.textPrimary)
                }
                .padding(.horizontal, 10).padding(.vertical, 7)
                .background(Theme.panelRaised, in: RoundedRectangle(cornerRadius: Theme.controlRadius))
                Menu {
                    Picker("Sort", selection: $sort) {
                        ForEach(CoefficientSort.allCases) { Text($0.rawValue).tag($0) }
                    }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.up.arrow.down")
                        Text(sort.rawValue)
                    }
                    .font(.caption.weight(.medium))
                    .foregroundStyle(Theme.textPrimary)
                    .padding(.horizontal, 10).padding(.vertical, 8)
                    .background(Theme.panelRaised, in: RoundedRectangle(cornerRadius: Theme.controlRadius))
                }
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    Chip(label: "All", selected: category == nil) { category = nil }
                    ForEach(BlendShapeCategory.allCases) { cat in
                        Chip(label: cat.rawValue, selected: category == cat, color: Theme.category(cat)) {
                            category = category == cat ? nil : cat
                        }
                    }
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }
}

struct CoefficientRow: View {
    let c: CoefficientSnapshot
    let expanded: Bool
    let toggle: () -> Void

    var body: some View {
        VStack(spacing: 8) {
            Button(action: toggle) {
                HStack(spacing: 10) {
                    RoundedRectangle(cornerRadius: 1.5)
                        .fill(Theme.channel(c.side))
                        .frame(width: 3, height: 30)
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(c.name).font(.callout.weight(.medium)).foregroundStyle(Theme.textPrimary)
                            if c.isActive {
                                Text("active").font(.caption2.weight(.semibold)).foregroundStyle(Theme.background)
                                    .padding(.horizontal, 5).padding(.vertical, 1)
                                    .background(Theme.category(c.category), in: Capsule())
                            }
                            Spacer()
                            Text(Fmt.f(c.value, 3)).font(.callout.monospacedDigit().weight(.semibold)).foregroundStyle(Theme.textPrimary)
                        }
                        LevelBar(value: c.value, color: Theme.category(c.category), height: 5)
                    }
                    Sparkline(values: c.history, color: Theme.category(c.category), range: 0...1, fill: false)
                        .frame(width: 72, height: 30)
                }
            }
            .buttonStyle(.plain)
            if expanded {
                VStack(alignment: .leading, spacing: 8) {
                    Sparkline(values: c.history, color: Theme.category(c.category), range: 0...1)
                        .frame(height: 60)
                    ReadoutGrid(items: [
                        ("Min", Fmt.f(c.minimum, 3), nil),
                        ("Max", Fmt.f(c.maximum, 3), nil),
                        ("Mean", Fmt.f(c.mean, 3), nil),
                        ("Δ frame", Fmt.signed(c.delta, 3), nil),
                        ("Velocity", Fmt.signed(c.velocity, 2), "1/s"),
                        ("Accel.", Fmt.signed(c.secondDerivative, 1), "1/s²"),
                        ("Window mean", Fmt.f(c.windowMean, 3), nil),
                        ("Window std", Fmt.f(c.windowStd, 3), nil),
                        ("Activations", String(c.activationCount), nil)
                    ])
                    Text("ARKit identifier: \(c.id) · \(c.category.rawValue)")
                        .font(.caption2).foregroundStyle(Theme.textTertiary)
                }
                .padding(.leading, 13)
            }
        }
        .padding(10)
        .background(Theme.panel, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Theme.border, lineWidth: 1))
    }
}
