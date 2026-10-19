import MapKit
import SwiftUI

struct Place: Codable, Identifiable, Hashable {
    var id = UUID()
    var name: String
    var lat: Double
    var lon: Double

    var coordinate: CLLocationCoordinate2D { .init(latitude: lat, longitude: lon) }
}

private let defaultPlaces = [
    Place(name: "Kyiv", lat: 50.4501, lon: 30.5234),
    Place(name: "Warsaw", lat: 52.2297, lon: 21.0122),
    Place(name: "Paris", lat: 48.8584, lon: 2.2945),
    Place(name: "New York", lat: 40.7580, lon: -73.9855),
    Place(name: "Tokyo", lat: 35.6595, lon: 139.7005),
]

private func region(_ c: CLLocationCoordinate2D, _ span: Double = 0.02) -> MapCameraPosition {
    .region(MKCoordinateRegion(center: c, span: .init(latitudeDelta: span, longitudeDelta: span)))
}

struct ContentView: View {
    @AppStorage("host") private var host = Config.host
    @AppStorage("token") private var token = Config.token
    @AppStorage("places") private var placesData = ""
    @AppStorage("fakeAt") private var fakeAtText = ""
    @AppStorage("realAt") private var realAtText = ""
    @AppStorage("holdMinutes") private var holdMinutes = 15
    @StateObject private var loc = LocationManager()
    @Environment(\.scenePhase) private var scenePhase

    @State private var camera: MapCameraPosition = .userLocation(fallback: region(.init(latitude: 52.23, longitude: 21.01), 0.3))
    @State private var chosen: CLLocationCoordinate2D?
    @State private var chosenName = ""
    @State private var devices: [Device] = []
    @State private var selected: Set<String> = []
    @State private var status = "Tap the map or search a place"
    @State private var statusOK = true
    @State private var busy = false
    @State private var query = ""
    @State private var results: [MKMapItem] = []
    @State private var showSettings = false
    @State private var showDevices = false
    @State private var ignoreLocationUntil = Date.distantPast
    @State private var holdUntil: Date?
    @State private var serverHolds: [String: Hold] = [:]
    @FocusState private var searching: Bool

    private var api: API { API(host: host, token: token) }

    private var fakeAt: CLLocationCoordinate2D? {
        get { decode(fakeAtText) }
        nonmutating set { fakeAtText = encode(newValue) }
    }
    /// Last position seen while no fake was active, so the real spot stays visible during a fake.
    private var realAt: CLLocationCoordinate2D? { decode(realAtText) }

    /// Where the owner really is: the live fix, or the last real one saved before faking.
    private var myRealLocation: CLLocationCoordinate2D? { fakeAt == nil ? loc.location : realAt }

    private var selectedSummary: String {
        let names = devices.filter { selected.contains($0.id) }.map(\.name)
        if names.isEmpty { return "Choose devices" }
        return names.count == devices.filter(\.canMove).count && names.count > 1 ? "All devices" : names.joined(separator: ", ")
    }

    private var places: [Place] {
        (try? JSONDecoder().decode([Place].self, from: Data(placesData.utf8))) ?? defaultPlaces
    }

    private func savePlaces(_ list: [Place]) {
        placesData = String(data: (try? JSONEncoder().encode(list)) ?? Data(), encoding: .utf8) ?? ""
    }

    var body: some View {
        ZStack(alignment: .top) {
            MapReader { proxy in
                Map(position: $camera) {
                    if let c = chosen {
                        Marker(chosenName.isEmpty ? "Here" : chosenName, systemImage: "mappin", coordinate: c)
                            .tint(.red)
                    }
                    UserAnnotation()
                    if fakeAt != nil, let r = realAt {
                        Annotation("You are here (real)", coordinate: r) {
                            Image(systemName: "figure.stand")
                                .font(.caption.bold()).foregroundStyle(.white)
                                .padding(6).background(.green, in: Circle())
                                .overlay(Circle().stroke(.white, lineWidth: 2))
                        }
                    }
                }
                .mapControls {
                    MapUserLocationButton()
                    MapCompass()
                }
                .onTapGesture { point in
                    searching = false
                    if let c = proxy.convert(point, from: .local) { choose(c, name: "") }
                }
            }
            .ignoresSafeArea()

            VStack(spacing: 10) {
                searchBar
                if results.isEmpty {
                    HStack {
                        Spacer()
                        meButton
                    }
                    .padding(.horizontal)
                }
            }
        }
        .safeAreaInset(edge: .bottom) { panel }
        .sheet(isPresented: $showSettings, onDismiss: { Task { await loadDevices() } }) {
            SettingsView(host: $host, token: $token)
        }
        .sheet(isPresented: $showDevices) {
            DevicesSheet(devices: devices, selected: $selected, problem: statusOK ? nil : status) { await loadDevices() }
                .presentationDetents([.medium, .large])
        }
        .task {
            for s in DirectSession.all { await s.resume() }
            // Older installs saved only the home address; add Tailscale too.
            if !host.contains(",") && Config.host.hasPrefix(host) { host = Config.host }
            await loadDevices()
            await syncHolds()
        }
        .task(id: holdUntil) {
            // Refresh once the Mac has put the real location back.
            guard let until = holdUntil else { return }
            try? await Task.sleep(for: .seconds(max(0, until.timeIntervalSinceNow) + 8))
            if !Task.isCancelled { await syncHolds() }
        }
        .onChange(of: scenePhase) {
            if scenePhase == .active { Task { await loadDevices(); await syncHolds() } }
        }
        .onChange(of: holdMinutes) { Reminder.registerButtons() }
        .onReceive(NotificationCenter.default.publisher(for: .holdChanged)) { _ in
            Task { await syncHolds() }
        }
        .onChange(of: loc.location?.latitude) {
            // Right after "Original location" iOS may still report the fake point for a moment.
            if fakeAt == nil, Date() > ignoreLocationUntil, let c = loc.location { realAtText = encode(c) }
        }
    }

    // MARK: - Views

    private var searchBar: some View {
        VStack(spacing: 6) {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search a place", text: $query)
                    .focused($searching)
                    .submitLabel(.search)
                    .onSubmit { Task { await search() } }
                if !query.isEmpty {
                    Button { query = ""; results = [] } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                    }
                }
                Button { showSettings = true } label: { Image(systemName: "gearshape") }
            }
            .padding(12)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))

            if !results.isEmpty {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(results, id: \.self) { item in
                        Button { pick(item) } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(item.name ?? "Place")
                                Text(item.placemark.title ?? "")
                                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.vertical, 8).padding(.horizontal, 12)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        Divider()
                    }
                }
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
            }
        }
        .padding(.horizontal)
        .padding(.top, 8)
    }

    private var panel: some View {
        VStack(alignment: .leading, spacing: 12) {
            Button { showDevices = true } label: {
                HStack {
                    Image(systemName: "checklist")
                    Text(selectedSummary).lineLimit(1)
                    Spacer()
                    Image(systemName: "chevron.up")
                }
                .font(.subheadline.weight(.medium))
                .padding(.horizontal, 12).padding(.vertical, 10)
                .background(Color.secondary.opacity(0.15), in: RoundedRectangle(cornerRadius: 12))
            }
            .buttonStyle(.plain)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack {
                    if let r = myRealLocation {
                        Button { choose(r, name: "My real location"); camera = region(r) } label: {
                            Label("Me", systemImage: "location")
                        }
                        .buttonStyle(.bordered).tint(.green)
                    }
                    ForEach(places) { p in
                        Button(p.name) {
                            choose(p.coordinate, name: p.name)
                            camera = region(p.coordinate)
                        }
                        .buttonStyle(.bordered)
                        .contextMenu {
                            Button("Remove", role: .destructive) { savePlaces(places.filter { $0.id != p.id }) }
                        }
                    }
                    if let c = chosen {
                        Button {
                            let name = chosenName.isEmpty ? String(format: "%.3f, %.3f", c.latitude, c.longitude) : chosenName
                            savePlaces(places + [Place(name: name, lat: c.latitude, lon: c.longitude)])
                        } label: { Image(systemName: "star") }
                        .buttonStyle(.bordered)
                    }
                }
            }

            holdRow

            HStack {
                Button { Task { await move() } } label: {
                    Label("Move here", systemImage: "location.fill").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(chosen == nil || selected.isEmpty || busy)

                Button { Task { await reset() } } label: {
                    Label("Original location", systemImage: "arrow.uturn.backward").frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .tint(.green)
                .disabled(selected.isEmpty || busy)
            }
            .controlSize(.large)

            HStack(spacing: 8) {
                if busy { ProgressView() }
                Text(status)
                    .font(.footnote)
                    .foregroundStyle(statusOK ? Color.secondary : Color.red)
            }
        }
        .padding()
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 22))
        .padding(.horizontal, 8)
    }

    private var meButton: some View {
        Button {
            if let r = myRealLocation {
                withAnimation { camera = region(r, 0.01) }
            } else {
                status = "Waiting for your location. Allow Location for this app in Settings."
                statusOK = false
            }
        } label: {
            Image(systemName: "figure.stand")
                .font(.title2.weight(.semibold))
                .foregroundStyle(.white)
                .frame(width: 52, height: 52)
                .background(.green, in: Circle())
                .overlay(Circle().stroke(.white.opacity(0.8), lineWidth: 2))
                .shadow(radius: 4)
        }
        .accessibilityLabel("Show where I am")
    }

    private var holdRow: some View {
        HStack(spacing: 10) {
            Menu {
                Picker("Hold for", selection: $holdMinutes) {
                    ForEach([0, 1, 5, 10, 15, 30, 60, 120, 240], id: \.self) { Text(holdLabel($0)).tag($0) }
                }
            } label: {
                Label("Hold: \(holdLabel(holdMinutes))", systemImage: "timer")
                    .font(.subheadline.weight(.medium))
            }
            Spacer()
            if fakeAt != nil {
                if let until = holdUntil {
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        Text(timeLeft(until, now: context.date))
                            .font(.subheadline.monospacedDigit())
                            .foregroundStyle(.orange)
                    }
                    Button("+\(holdLabel(HoldStore.prolongMinutes))") { Task { await prolong() } }
                        .buttonStyle(.bordered)
                        .disabled(busy)
                } else {
                    Text("Fake, no limit").font(.subheadline).foregroundStyle(.orange)
                }
            }
        }
    }

    private func timeLeft(_ until: Date, now: Date) -> String {
        let s = max(0, Int(until.timeIntervalSince(now)))
        if s == 0 { return "Ending…" }
        return s >= 3600
            ? String(format: "%d:%02d:%02d left", s / 3600, s / 60 % 60, s % 60)
            : String(format: "%d:%02d left", s / 60, s % 60)
    }

    // MARK: - Actions

    /// The Mac is the source of truth for what is faked and until when.
    private func syncHolds() async {
        if let holds = try? await api.status() { serverHolds = holds }
        HoldStore.devices = Array(serverHolds.keys)
        if let c = DirectSession.all.compactMap(\.fakeAt).first {
            fakeAt = c
        } else if let h = serverHolds.values.first {
            fakeAt = .init(latitude: h.lat, longitude: h.lon)
        } else {
            if fakeAt != nil { ignoreLocationUntil = Date().addingTimeInterval(10) }
            fakeAt = nil
        }
        let untils = serverHolds.values.compactMap(\.until).map { Date(timeIntervalSince1970: $0) }
            + DirectSession.all.compactMap(\.until)
        holdUntil = untils.min()
        Reminder.schedule(until: holdUntil)
    }

    private func prolong() async {
        busy = true
        for id in HoldStore.devices { _ = try? await api.extend(id, minutes: HoldStore.prolongMinutes) }
        for s in DirectSession.all { s.extend(minutes: HoldStore.prolongMinutes) }
        busy = false
        await syncHolds()
        status = "Fake location kept \(holdLabel(HoldStore.prolongMinutes)) longer"
        statusOK = true
    }

    private func choose(_ c: CLLocationCoordinate2D, name: String) {
        chosen = c
        chosenName = name
        status = name.isEmpty ? String(format: "%.5f, %.5f", c.latitude, c.longitude) : name
        statusOK = true
    }

    private func pick(_ item: MKMapItem) {
        let c = item.placemark.coordinate
        choose(c, name: item.name ?? "")
        camera = region(c)
        results = []
        query = ""
        searching = false
    }

    private func search() async {
        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = query
        do {
            results = Array(try await MKLocalSearch(request: request).start().mapItems.prefix(6))
        } catch {
            results = []
            status = "Nothing found"
            statusOK = false
        }
    }

    private func loadDevices() async {
        defer {
            if selected.isEmpty {
                selected = [devices.contains { $0.id == Self.groupID } ? Self.groupID : DirectSession.deviceID]
            }
        }
        do {
            let mac = try await api.devices().map { d -> Device in
                guard d.canMove else { return d }
                var copy = d
                copy.note = d.kind == "watch" ? "Via Mac: home Wi‑Fi only" : "Via Mac: cable or home Wi‑Fi"
                return copy
            }
            devices = directDevices + mac
            selected = selected.filter { id in devices.contains { $0.id == id && $0.canMove } }
            if selected.isEmpty, let first = devices.first(where: { $0.id == Self.groupID }) ?? devices.first(where: { $0.kind == "iphone" }) {
                selected = [first.id]
            }
            status = "Connected to the Mac" + (API.route.map { " (\($0))" } ?? "")
            statusOK = true
        } catch {
            devices = directDevices
            status = "Mac not reachable: only the \"no Mac\" devices work now"
            statusOK = true
        }
    }

    /// One entry that moves this iPhone and the Watch together (AirPods follow the iPhone).
    static let groupID = "group-direct"

    /// This iPhone always; once the Watch is paired (⚙️), the iPhone + Watch group. The Watch alone
    /// isn't offered: near its iPhone it takes the iPhone's location, so a Watch-only fake jumps back.
    private var directDevices: [Device] {
        var list = [DirectSession.shared.device]
        if DirectSession.watch.hasPairingFile {
            // First in the list and the default choice.
            list.insert(Device(id: Self.groupID, name: "iPhone + Watch + AirPods (no Mac)", kind: "group",
                               paired: true, movable: true,
                               note: "Moves all together. AirPods follow the iPhone while connected. LocalDevVPN on, Watch near"), at: 0)
        }
        return list
    }

    private func forSelected(_ work: (Device) async throws -> Void) async -> [String] {
        busy = true
        defer { busy = false }
        var errors: [String] = []
        // A Watch near its iPhone takes the iPhone's location: the Watch fake only holds when the
        // iPhone is moved too, so "Apple Watch (no Mac)" always brings "This iPhone (no Mac)" along.
        var ids = selected
        if ids.remove(Self.groupID) != nil { ids.insert(DirectTarget.phone.id); ids.insert(DirectTarget.watch.id) }
        if ids.contains(DirectTarget.watch.id) { ids.insert(DirectTarget.phone.id) }
        // iPhone first, then the Watch, then the Mac's devices.
        let targets = DirectSession.all.map(\.device) + devices.filter { DirectSession.session(for: $0.id) == nil && $0.id != Self.groupID }
        for d in targets where ids.contains(d.id) {
            do { try await work(d) } catch { errors.append("\(d.name): \(error.localizedDescription)") }
        }
        return errors
    }

    private func move() async {
        guard let c = chosen else { return }
        status = "Moving…"
        statusOK = true
        let minutes = holdMinutes
        let errors = await forSelected { d in
            if let s = DirectSession.session(for: d.id) {
                try await s.move(to: c, minutes: minutes)
            } else {
                try await api.move(d.id, lat: c.latitude, lon: c.longitude, minutes: minutes)
            }
        }
        await syncHolds()
        if errors.isEmpty {
            let name = chosenName.isEmpty ? "the pin" : chosenName
            if let until = holdUntil {
                status = "Moved to \(name). Real location back at \(until.formatted(date: .omitted, time: .shortened))"
            } else {
                status = "Moved to \(name), no time limit"
            }
        } else {
            status = errors.joined(separator: "\n")
        }
        statusOK = errors.isEmpty
    }

    private func reset() async {
        status = "Going back to the real location…"
        statusOK = true
        let errors = await forSelected { d in
            if let s = DirectSession.session(for: d.id) {
                try await s.stop()
            } else {
                try await api.reset(d.id)
            }
        }
        await syncHolds()
        if errors.isEmpty {
            status = "Back to the real location"
        } else {
            status = errors.joined(separator: "\n")
        }
        statusOK = errors.isEmpty
    }
}

struct SettingsView: View {
    @Binding var host: String
    @Binding var token: String
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                DirectSetupSection()
                WatchSetupSection()
                Section {
                    TextField("Mac address", text: $host)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                } header: {
                    Text("Mac address")
                } footer: {
                    Text("One or more addresses with :8765, separated by commas. The app uses the first one that answers: home Wi-Fi name, then the Mac's Tailscale IP.")
                }
                Section("Token") {
                    TextField("Token", text: $token)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .font(.footnote.monospaced())
                }
                Section {
                    Button("Reset to defaults") {
                        host = Config.host
                        token = Config.token
                    }
                }
            }
            .navigationTitle("Settings")
            .toolbar { Button("Done") { dismiss() } }
        }
    }
}

private func encode(_ c: CLLocationCoordinate2D?) -> String {
    guard let c else { return "" }
    return "\(c.latitude),\(c.longitude)"
}

private func decode(_ text: String) -> CLLocationCoordinate2D? {
    let parts = text.split(separator: ",").compactMap { Double($0) }
    return parts.count == 2 ? .init(latitude: parts[0], longitude: parts[1]) : nil
}

/// Device list like Find My: tick the ones to move, the rest explain why they can't.
struct DevicesSheet: View {
    let devices: [Device]
    @Binding var selected: Set<String>
    let problem: String?
    let refresh: () async -> Void
    @State private var loading = false
    @Environment(\.dismiss) private var dismiss

    private var movable: [Device] { devices.filter(\.canMove) }
    private var fixed: [Device] { devices.filter { !$0.canMove } }

    var body: some View {
        NavigationStack {
            List {
                if devices.isEmpty {
                    Section {
                        VStack(spacing: 12) {
                            if loading {
                                ProgressView("Asking the Mac…")
                            } else {
                                Image(systemName: "exclamationmark.triangle").font(.largeTitle).foregroundStyle(.orange)
                                Text(problem ?? "No devices yet").multilineTextAlignment(.center)
                                Button("Try again") { Task { await reload() } }.buttonStyle(.borderedProminent)
                            }
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical)
                    }
                }
                Section {
                    ForEach(movable) { d in
                        Button {
                            if selected.contains(d.id) { selected.remove(d.id) } else { selected.insert(d.id) }
                        } label: {
                            row(d, subtitle: d.note ?? (d.paired ? "Can be moved" : "Not paired with the Mac"))
                        }
                        .buttonStyle(.plain)
                    }
                } header: {
                    HStack {
                        Text("Move these")
                        Spacer()
                        if !movable.isEmpty {
                        Button(selected.count == movable.count ? "Select none" : "Select all") {
                            selected = selected.count == movable.count ? [] : Set(movable.map(\.id))
                        }
                        .font(.footnote)
                        .textCase(nil)
                        }
                    }
                }

                if !fixed.isEmpty {
                    Section {
                        ForEach(fixed) { d in row(d, subtitle: d.note ?? "Can't be moved").opacity(0.55) }
                    } header: {
                        Text("Can't be moved")
                    } footer: {
                        Text("AirPods follow the iPhone they are connected to. Move the iPhone and keep them connected to it.")
                    }
                }
            }
            .navigationTitle("Devices")
            .navigationBarTitleDisplayMode(.inline)
            .refreshable { await refresh() }
            .task { await reload() }
            .toolbar { Button("Done") { dismiss() } }
        }
    }

    private func reload() async {
        loading = true
        await refresh()
        loading = false
    }

    private func row(_ d: Device, subtitle: String) -> some View {
        HStack(spacing: 14) {
            Image(systemName: d.icon)
                .font(.title3)
                .frame(width: 44, height: 44)
                .background(Color.secondary.opacity(0.15), in: Circle())
            VStack(alignment: .leading, spacing: 2) {
                Text(d.name).font(.body.weight(.semibold))
                Text(subtitle).font(.footnote).foregroundStyle(.secondary)
            }
            Spacer()
            if d.canMove {
                Image(systemName: selected.contains(d.id) ? "checkmark.circle.fill" : "circle")
                    .font(.title2)
                    .foregroundStyle(selected.contains(d.id) ? Color.accentColor : Color.secondary)
            }
        }
        .contentShape(Rectangle())
    }
}
