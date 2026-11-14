import SwiftUI

/// The server-side path: pair with the clinic engine, push daily Apple Health values, send a
/// FaceMetrics recording as raw frames, and read back what the engine (and Gemini behind it) made of it.
struct EngineScreen: View {
    @EnvironmentObject var state: AppState
    @State private var pairingCode = ""
    @State private var selectedSession: String?
    @State private var kind: EngineActivityBuilder.ActivityKind = .breathing
    @State private var rate: Double = 30
    @State private var useMarkersAsMoments = false
    @State private var clinicUser = ""
    @State private var clinicPass = ""
    @State private var patientOverride = ""

    var body: some View {
        NavigationStack {
            List {
                serverSection
                dailySection
                activitySection
                if !state.engineActivityResults.isEmpty { readingsSection }
                clinicianSection
                logSection
            }
            .navigationTitle("Engine")
            .onAppear { if selectedSession == nil { selectedSession = state.arKitSessions.first?.id } }
        }
    }

    // MARK: Sections

    private var serverSection: some View {
        Section("Clinic engine") {
            TextField("https://lanvi.app", text: $state.engine.baseURL).textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
            HStack { Text("Device token"); Spacer(); StatusBadge(text: state.engine.hasDeviceToken ? "in Keychain" : "none", tone: state.engine.hasDeviceToken ? .good : .warn) }
            if let p = state.engine.patientID { KV("Patient id", p) }
            if !state.engine.hasDeviceToken {
                TextField("Pairing code from the clinic (ABCD-EFGH-JKLM)", text: $pairingCode).textInputAutocapitalization(.characters).autocorrectionDisabled()
                Button("Pair this device") { Task { await state.enginePair(code: pairingCode); pairingCode = "" } }.disabled(pairingCode.count < 12)
            } else {
                Button("GET /v1/today") { Task { await state.engineToday() } }
                Button("Forget pairing", role: .destructive) { state.engine.forgetDevice() }
            }
            if let t = state.engineTodayResult {
                KV("Status", t["status"]?.stringValue ?? "–")
                KV("Attention", t["attention"]?.stringValue ?? "–")
                KV("Suggestion", t["suggestion"]?["action"]?.stringValue ?? "none")
                NavigationLink("Full /v1/today JSON") { JSONView(title: "today", json: t) }
            }
        }
        .disabled(state.busy != nil)
    }

    private var dailySection: some View {
        Section("1 · Daily Apple Health → POST /v1/daily") {
            if let r = state.engineDailyPreview {
                KV("Days with steps", r.days.count)
                KV("Days skipped (no steps)", r.skippedDays.count)
                if let f = r.days.first, let l = r.days.last { KV("Range", "\(f.date) … \(l.date)") }
                KV("With HRV", r.days.filter { $0.hrvMs != nil }.count)
                KV("With sleep", r.days.filter { $0.sleepH != nil }.count)
                KV("With walking speed", r.days.filter { $0.walkingSpeedMS != nil }.count)
                Text(r.note).font(.caption2).foregroundStyle(.secondary)
                Button("Review and send \(r.days.count) days") { state.engineAskToSendDaily() }.disabled(r.days.isEmpty || !state.engine.hasDeviceToken)
            } else {
                Button("Build day records from the Health summary") { state.engineBuildDailyPreview() }.disabled(state.healthSummary == nil)
                if state.healthSummary == nil { Text("Fetch or import Health data on the HealthKit tab first.").font(.caption).foregroundStyle(.secondary) }
            }
            if let out = state.engineDailyResult {
                KV("Accepted", out.accepted.count); KV("Rejected", out.rejected.count); KV("Server status", out.status)
                ForEach(out.rejected.prefix(10), id: \.self) { Text("\($0.date): \($0.reason)").font(.caption2).foregroundStyle(.red) }
            }
        }
        .disabled(state.busy != nil)
    }

    private var activitySection: some View {
        Section("2 · Recording → face_raw → POST /v1/activities") {
            if state.arKitSessions.isEmpty {
                Text("Import a FaceMetrics recording on the ARKit tab first.").font(.caption).foregroundStyle(.secondary)
            } else {
                Picker("Recording", selection: Binding(get: { selectedSession ?? state.arKitSessions.first!.id }, set: { selectedSession = $0 })) {
                    ForEach(state.arKitSessions) { s in Text(s.id).tag(s.id) }
                }
                Picker("Send as", selection: $kind) { ForEach(EngineActivityBuilder.ActivityKind.allCases) { Text($0.rawValue).tag($0) } }
                Picker("Rate", selection: $rate) { Text("30 Hz").tag(30.0); Text("15 Hz").tag(15.0); Text("10 Hz").tag(10.0) }
                Toggle("Marker starts as pleasant moments", isOn: $useMarkersAsMoments)
                Button("Build face_raw preview") {
                    if let id = selectedSession { state.engineBuildActivityPreview(sessionID: id, kind: kind, rateHz: rate, markersAsMoments: useMarkersAsMoments) }
                }
                if let r = state.engineFaceRawReport {
                    KV("Channels", "\(r.channelCount) (\(r.blendShapeChannels) blend shapes + 3 head angles)")
                    KV("Samples", r.sampleCount); KV("Rate", r.rateHz, digits: 1, unit: "Hz")
                    KV("Tracked", Fmt.pct(r.trackedFraction)); KV("Span", r.spanSeconds, digits: 1, unit: "s")
                    KV("Head angles", r.headAngleSource); KV("Moments", r.momentCount)
                    KV("Approx. size", Fmt.bytes(r.approximateBytes))
                    if !r.droppedBlendShapes.isEmpty { KV("Dropped channels", r.droppedBlendShapes.joined(separator: ", ")) }
                    ForEach(r.warnings, id: \.self) { Text($0).font(.caption).foregroundStyle(.orange) }
                    Button("Review and send to the engine") { state.engineAskToSendActivity() }.disabled(!state.engine.hasDeviceToken)
                }
            }
        }
        .disabled(state.busy != nil)
    }

    private var readingsSection: some View {
        Section("3 · What the engine answered") {
            ForEach(state.engineActivityResults.keys.sorted(), id: \.self) { id in
                if let out = state.engineActivityResults[id] {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(id).font(.caption.monospaced())
                        HStack(spacing: 6) {
                            StatusBadge(text: "reading \(state.engineReadings[id]?.status ?? out.reading)", tone: badgeTone(state.engineReadings[id]?.status ?? out.reading))
                            Text("xp +\(out.xpGained) · \(out.stage)").font(.caption2).foregroundStyle(.secondary)
                        }
                        Text("Lanvi: \(out.line.text)").font(.caption)
                        if let l = state.engineReadings[id]?.line { Text("Reading line: \(l)").font(.caption) }
                        Button("Poll reading") { Task { await state.enginePollReading(id) } }.font(.caption)
                    }
                }
            }
            Text("The patient-facing reading is one neutral fixed line by design. The checked reading, the server-computed face summary and the raw Gemini exchange are visible through the clinician login below.")
                .font(.caption2).foregroundStyle(.secondary)
        }
    }

    private var clinicianSection: some View {
        Section("4 · Clinician view (what the server computed, what Gemini said)") {
            if !state.engine.clinicianLoggedIn {
                TextField("Clinician username", text: $clinicUser).textInputAutocapitalization(.never).autocorrectionDisabled()
                SecureField("Password", text: $clinicPass)
                Button("Log in") { Task { await state.engineClinicLogin(user: clinicUser, pass: clinicPass); clinicPass = "" } }.disabled(clinicUser.isEmpty || clinicPass.isEmpty)
            } else {
                TextField("Patient id (blank = paired patient)", text: $patientOverride).textInputAutocapitalization(.never).autocorrectionDisabled()
                Button("Fetch patient detail") { Task { await state.engineFetchPatientDetail(patientOverride.isEmpty ? nil : patientOverride) } }
                Button("Fetch model exchanges (session_reading)") { Task { await state.engineFetchExchanges(patientOverride.isEmpty ? nil : patientOverride) } }
                Button("Log out") { state.engine.clinicLogout() }
            }
            if let d = state.enginePatientDetail {
                faceSummaryView(d)
                NavigationLink("Full patient detail JSON") { JSONView(title: "patient", json: d) }
            }
            if let ex = state.engineModelExchanges {
                let list = ex["exchanges"]?.arrayValue ?? []
                KV("Exchanges", list.count)
                ForEach(Array(list.prefix(5).enumerated()), id: \.offset) { _, e in
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(e["at"]?.stringValue ?? "") · level \(e["level"]?.intValue ?? 0) · \(e["model"]?.stringValue ?? "") · \(e["ms"]?.intValue ?? 0) ms").font(.caption2.monospaced())
                        Text("reply: \((e["reply"]?.stringValue ?? "—").prefix(300))").font(.caption2).foregroundStyle(.secondary)
                    }
                }
                NavigationLink("Full exchanges JSON (prompt sent + reply)") { JSONView(title: "exchanges", json: ex) }
            }
        }
        .disabled(state.busy != nil)
    }

    @ViewBuilder
    private func faceSummaryView(_ d: JSONValue) -> some View {
        // activities.{focus|breathing}.sessions[*] carry face, face_source, raw counts, z and reading.
        let acts = d["activities"]?.objectValue ?? [:]
        ForEach(["breathing", "focus"], id: \.self) { t in
            if let sessions = acts[t]?["sessions"]?.arrayValue, !sessions.isEmpty {
                DisclosureGroup("\(t): \(sessions.count) session(s)") {
                    ForEach(Array(sessions.prefix(6).enumerated()), id: \.offset) { _, s in
                        VStack(alignment: .leading, spacing: 2) {
                            Text("\(s["date"]?.stringValue ?? s["started_at"]?.stringValue ?? "?") · face_source \(s["face_source"]?.stringValue ?? "–")").font(.caption.monospaced())
                            if let face = s["face"]?.objectValue {
                                Text(face.sorted(by: { $0.key < $1.key }).compactMap { k, v in v.doubleValue.map { "\(k) \(Fmt.num($0, 3))" } }.joined(separator: " · "))
                                    .font(.caption2).lineLimit(4)
                            }
                            if let raw = s["raw"]?.objectValue {
                                Text("raw: \(raw["frames"]?.intValue ?? 0) frames · \(raw["channels"]?.intValue ?? 0) channels · tracked \(Fmt.pct(raw["tracked_share"]?.doubleValue))").font(.caption2).foregroundStyle(.secondary)
                            }
                            if let z = s["face_z"]?.objectValue ?? s["z"]?.objectValue {
                                Text("z: " + z.sorted(by: { $0.key < $1.key }).compactMap { k, v in v.doubleValue.map { "\(k) \(Fmt.num($0, 2))" } }.joined(separator: " · ")).font(.caption2).foregroundStyle(.secondary).lineLimit(3)
                            }
                            if let r = s["reading"] { Text("reading: \(r.description.prefix(400))").font(.caption2) }
                        }
                    }
                }
            }
        }
    }

    private var logSection: some View {
        Section("Call log (\(state.engine.exchanges.count))") {
            ForEach(state.engine.exchanges.prefix(30)) { e in
                NavigationLink {
                    JSONView(title: "\(e.method) \(e.path)", json: .object(["request": e.request ?? .null, "http_status": JSONValue(e.httpStatus),
                                                                              "response": e.response ?? .null, "latency_ms": .number(e.latencyMs), "error": JSONValue(e.error)]))
                } label: {
                    HStack {
                        Text("\(e.method) \(e.path)").font(.caption.monospaced()).lineLimit(1)
                        Spacer()
                        StatusBadge(text: e.httpStatus.map { String($0) } ?? "err", tone: (e.httpStatus ?? 0) < 300 && e.httpStatus != nil ? .good : .bad)
                        Text(String(format: "%.0f ms", e.latencyMs)).font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                    }
                }
            }
            if !state.engine.exchanges.isEmpty { Button("Clear log") { state.engine.clearLog() } }
        }
    }

    private func badgeTone(_ s: String) -> StatusBadge.Tone {
        switch s { case "ready": return .good; case "pending": return .neutral; case "failed", "not_allowed": return .bad; default: return .warn }
    }
}

/// Consent before anything goes to the engine: what, how much, where, and the exact JSON.
struct EngineConsentSheet: View {
    @EnvironmentObject var state: AppState
    @Environment(\.dismiss) private var dismiss
    let send: EnginePendingSend
    @State private var acknowledged = false

    var body: some View {
        NavigationStack {
            List {
                Section(send.title) {
                    KV("Destination", state.engine.baseURL + send.path)
                    ForEach(send.facts, id: \.self) { Text($0).font(.callout) }
                }
                Section("Never transmitted") {
                    Label("Camera frames, video, face mesh", systemImage: "video.slash")
                    Label("Names, participant labels, notes, device identifiers", systemImage: "person.crop.circle.badge.xmark")
                    Label("Anything computed from the face on this phone", systemImage: "function")
                }
                Section { NavigationLink("Inspect the exact JSON body") { JSONView(title: "Body", json: send.preview) } }
                Section { Toggle("I understand these numbers are sent to the clinic engine, which stores them and may pass an anonymous summary to Gemini.", isOn: $acknowledged).font(.footnote) }
            }
            .navigationTitle("Consent")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { state.pendingEngineSend = nil; dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("Send") { dismiss(); Task { await state.engineSendPending() } }.disabled(!acknowledged) }
            }
        }
    }
}
