//
//  ModulesSearchResultsSheet.swift
//  Sora
//
//  Created by Francesco on 09/08/25.
//

import AVKit
import SwiftUI
import Kingfisher

extension Notification.Name {
    /// Posted when in-app NormalPlayer fails so Miruro can try the next stream server.
    static let noirMiruroTryNextServer = Notification.Name("noirMiruroTryNextServer")
}

struct StreamOption: Identifiable {
    let id = UUID()
    let name: String
    let url: String
    let headers: [String: String]?
    let subtitle: String?
}

@MainActor
final class ModulesSearchResultsViewModel: ObservableObject {
    @Published var moduleResults: [UUID: [SearchItem]] = [:]
    @Published var isSearching = true
    @Published var searchedServices: Set<UUID> = []
    @Published var failedServices: Set<UUID> = []
    @Published var totalServicesCount = 0
    
    @Published var isFetchingStreams = false
    @Published var currentFetchingTitle = ""
    @Published var streamFetchProgress = ""
    @Published var streamOptions: [StreamOption] = []
    @Published var streamError: String?
    @Published var showingStreamError = false
    @Published var showingStreamMenu = false
    
    @Published var selectedResult: SearchItem?
    @Published var showingPlayAlert = false
    @Published var expandedServices: Set<UUID> = []
    @Published var showingFilterEditor = false
    @Published var highQualityThreshold: Double = 0.9
    
    @Published var showingSeasonPicker = false
    @Published var showingEpisodePicker = false
    @Published var showingSubtitlePicker = false
    @Published var showingSubDubPicker = false
    @Published var availableSeasons: [[EpisodeLink]] = []
    @Published var selectedSeasonIndex = 0
    @Published var pendingEpisodes: [EpisodeLink] = []
    @Published var subtitleOptions: [(title: String, url: String)] = []
    
    var pendingSubtitles: [String]?
    var pendingService: Service?
    var pendingResult: SearchItem?
    var pendingJSController: JSController?
    var pendingStreamURL: String?
    var pendingHeaders: [String: String]?
    var pendingDefaultSubtitle: String?
    /// Miruro: alternate stream servers to try if playback fails (best-first order; first stream is played separately).
    var miruroFallbackQueue: [StreamOption] = []
    var miruroFallbackService: Service?
    /// Miruro: all subtitle tracks for the episode (CC menu in Normal player); same across server fallbacks.
    var miruroFallbackExternalSubs: [(title: String, url: String)] = []
    
    func clearMiruroFallbackContext() {
        miruroFallbackQueue = []
        miruroFallbackService = nil
        miruroFallbackExternalSubs = []
    }
    
    init() {
        highQualityThreshold = UserDefaults.standard.object(forKey: "highQualityThreshold") as? Double ?? 0.9
    }
    
    func resetPickerState() {
        availableSeasons = []
        pendingEpisodes = []
        pendingResult = nil
        pendingJSController = nil
        selectedSeasonIndex = 0
        isFetchingStreams = false
    }
    
    func resetStreamState() {
        isFetchingStreams = false
        showingStreamMenu = false
        pendingSubtitles = nil
        pendingService = nil
        clearMiruroFallbackContext()
    }
}

struct ModulesSearchResultsSheet: View {
    let mediaTitle: String
    let originalTitle: String?
    let isMovie: Bool
    let selectedEpisode: TMDBEpisode?
    let tmdbId: Int
    /// When non-nil and non-generic (e.g. "War of Underworld"), refines search and filters service results to this season/series.
    var selectedSeasonName: String? = nil
    /// Poster URL for the show/movie (used when enqueueing a download so Downloads show the poster).
    var posterURL: String? = nil
    /// When true, choosing a stream/subtitle enqueues a download instead of playing.
    var downloadIntent: Bool = false
    /// When downloading a full season: current episode index (0-based) for "Episode X of Y".
    var seasonDownloadEpisodeIndex: Int? = nil
    var seasonDownloadTotal: Int? = nil
    
    @Environment(\.presentationMode) var presentationMode
    @StateObject private var viewModel = ModulesSearchResultsViewModel()
    @StateObject private var serviceManager = ServiceManager.shared
    @StateObject private var algorithmManager = AlgorithmManager.shared
    @State private var pendingSubDub: (href: String, jsController: JSController, service: Service, fromEpisodeList: Bool)?
    
    private var displayTitle: String {
        if let episode = selectedEpisode {
            let base = "\(mediaTitle) S\(episode.seasonNumber)E\(episode.episodeNumber)"
            if let idx = seasonDownloadEpisodeIndex, let total = seasonDownloadTotal, total > 1 {
                return "\(base) — Episode \(idx + 1) of \(total)"
            }
            return base
        }
        return mediaTitle
    }
    
    private var episodeSeasonInfo: String {
        guard let episode = selectedEpisode else { return "" }
        var s = "S\(episode.seasonNumber)E\(episode.episodeNumber)"
        if let idx = seasonDownloadEpisodeIndex, let total = seasonDownloadTotal, total > 1 {
            s += " · \(idx + 1)/\(total)"
        }
        return s
    }
    
    private var mediaTypeText: String { isMovie ? "Movie" : "TV Show" }
    private var mediaTypeColor: Color { isMovie ? .purple : .green }
    
    private var searchStatusText: String {
        viewModel.isSearching
        ? "Searching... (\(viewModel.searchedServices.count)/\(viewModel.totalServicesCount))"
        : "Search complete"
    }
    
    private var searchStatusColor: Color {
        viewModel.isSearching ? .secondary : .green
    }
    
    /// True when we can use the season name to refine search/filter (e.g. "War of Underworld"), not generic like "Season 4".
    private var isSeasonNameMeaningful: Bool {
        guard let name = selectedSeasonName, !name.isEmpty else { return false }
        let lower = name.lowercased()
        return !lower.hasPrefix("season ")
    }
    
    private func lowerQualityResultsText(count: Int) -> String {
        "\(count) lower quality result\(count == 1 ? "" : "s") (<\(Int(viewModel.highQualityThreshold * 100))%)"
    }
    
    @ViewBuilder
    private var searchInfoSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 12) {
                Text("Searching for:")
                    .font(.caption)
                    .foregroundColor(.secondary)
                
                Text(displayTitle)
                    .font(.headline)
                    .fontWeight(.semibold)
                
                if let episode = selectedEpisode, !episode.name.isEmpty {
                    HStack {
                        Text(episode.name)
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                        Spacer()
                        Text(episodeSeasonInfo)
                            .font(.caption)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .cornerRadius(8)
                    }
                }
                
                statusBar
            }
            .padding(.vertical, 8)
        }
    }
    
    @ViewBuilder
    private var statusBar: some View {
        HStack {
            Text(mediaTypeText)
                .font(.caption)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(mediaTypeColor.opacity(0.2))
                .foregroundColor(mediaTypeColor)
                .cornerRadius(8)
            
            Spacer()
            
            if viewModel.isSearching {
                HStack(spacing: 8) {
                    ProgressView()
                        .scaleEffect(0.8)
                    Text(searchStatusText)
                        .font(.caption)
                        .foregroundColor(searchStatusColor)
                }
            } else {
                Text(searchStatusText)
                    .font(.caption)
                    .foregroundColor(searchStatusColor)
            }
        }
    }
    
    @ViewBuilder
    private var noActiveServicesSection: some View {
        Section {
            VStack(spacing: 12) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 40))
                    .foregroundColor(.orange)
                
                Text("No Active Services")
                    .font(.headline)
                    .fontWeight(.semibold)
                
                Text("You don't have any active services. Please go to the Services tab to download and activate services.")
                    .font(.body)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
            }
            .padding()
            .frame(maxWidth: .infinity)
        }
    }
    
    @ViewBuilder
    private var servicesResultsSection: some View {
        ForEach(Array(serviceManager.activeServices.enumerated()), id: \.element.id) { index, service in
            serviceSection(service: service)
        }
    }
    
    @ViewBuilder
    private func serviceSection(service: Service) -> some View {
        let results = viewModel.moduleResults[service.id]
        let hasSearched = viewModel.searchedServices.contains(service.id)
        let isCurrentlySearching = viewModel.isSearching && !hasSearched
        
        if let results = results {
            let filteredResults = filterResults(for: results)
            
            Section(header: serviceHeader(for: service, highQualityCount: filteredResults.highQuality.count, lowQualityCount: filteredResults.lowQuality.count, isSearching: false)) {
                if results.isEmpty {
                    noResultsRow
                } else {
                    serviceResultsContent(filteredResults: filteredResults, service: service)
                }
            }
        } else if isCurrentlySearching {
            Section(header: serviceHeader(for: service, highQualityCount: 0, lowQualityCount: 0, isSearching: true)) {
                searchingRow
            }
        } else if !viewModel.isSearching && !hasSearched {
            Section(header: serviceHeader(for: service, highQualityCount: 0, lowQualityCount: 0, isSearching: false)) {
                notSearchedRow
            }
        }
    }
    
    @ViewBuilder
    private var noResultsRow: some View {
        HStack {
            Image(systemName: "exclamationmark.triangle")
                .foregroundColor(.orange)
            Text("No results found")
                .foregroundColor(.secondary)
            Spacer()
        }
        .padding(.vertical, 8)
    }
    
    @ViewBuilder
    private var searchingRow: some View {
        HStack {
            ProgressView()
                .scaleEffect(0.8)
            Text("Searching...")
                .foregroundColor(.secondary)
            Spacer()
        }
        .padding(.vertical, 8)
    }
    
    @ViewBuilder
    private var notSearchedRow: some View {
        HStack {
            Image(systemName: "minus.circle")
                .foregroundColor(.gray)
            Text("Not searched")
                .foregroundColor(.secondary)
            Spacer()
        }
        .padding(.vertical, 8)
    }
    
    @ViewBuilder
    private func serviceResultsContent(filteredResults: (highQuality: [SearchItem], lowQuality: [SearchItem]), service: Service) -> some View {
        ForEach(filteredResults.highQuality, id: \.id) { searchResult in
            EnhancedMediaResultRow(
                result: searchResult,
                originalTitle: mediaTitle,
                alternativeTitle: originalTitle,
                episode: selectedEpisode,
                onTap: {
                    viewModel.selectedResult = searchResult
                    viewModel.showingPlayAlert = true
                }, highQualityThreshold: viewModel.highQualityThreshold
            )
        }
        
        if !filteredResults.lowQuality.isEmpty {
            lowQualityResultsSection(filteredResults: filteredResults, service: service)
        }
    }
    
    @ViewBuilder
    private func lowQualityResultsSection(filteredResults: (highQuality: [SearchItem], lowQuality: [SearchItem]), service: Service) -> some View {
        let isExpanded = viewModel.expandedServices.contains(service.id)
        
        Button(action: {
            withAnimation(.easeInOut(duration: 0.3)) {
                if isExpanded {
                    viewModel.expandedServices.remove(service.id)
                } else {
                    viewModel.expandedServices.insert(service.id)
                }
            }
        }) {
            HStack {
                Image(systemName: "questionmark.circle")
                    .foregroundColor(.orange)
                
                Text(lowerQualityResultsText(count: filteredResults.lowQuality.count))
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                
                Spacer()
                
                Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .padding(.vertical, 8)
        }
        .buttonStyle(PlainButtonStyle())
        
        if isExpanded {
            ForEach(filteredResults.lowQuality, id: \.id) { searchResult in
                CompactMediaResultRow(
                    result: searchResult,
                    originalTitle: mediaTitle,
                    alternativeTitle: originalTitle,
                    episode: selectedEpisode,
                    onTap: {
                        viewModel.selectedResult = searchResult
                        viewModel.showingPlayAlert = true
                    }, highQualityThreshold: viewModel.highQualityThreshold
                )
            }
        }
    }
    
    @ViewBuilder
    private var playAlertButtons: some View {
        Button("Play") {
            viewModel.showingPlayAlert = false
            if let result = viewModel.selectedResult {
                Task {
                    try? await Task.sleep(nanoseconds: 300_000_000)
                    await playContent(result)
                }
            }
        }
        Button("Cancel", role: .cancel) {
            viewModel.selectedResult = nil
        }
    }
    
    @ViewBuilder
    private var playAlertMessage: some View {
        if let result = viewModel.selectedResult, let episode = selectedEpisode {
            Text("Play Episode \(episode.episodeNumber) of '\(result.title)'?")
        } else if let result = viewModel.selectedResult {
            Text("Play '\(result.title)'?")
        }
    }
    
    @ViewBuilder
    private var streamFetchingOverlay: some View {
        if viewModel.isFetchingStreams {
            ZStack {
                Color.black.opacity(0.4)
                    .ignoresSafeArea()
                
                VStack(spacing: 20) {
                    ProgressView()
                        .progressViewStyle(CircularProgressViewStyle(tint: .white))
                        .scaleEffect(1.5)
                    
                    VStack(spacing: 8) {
                        Text("Fetching Streams")
                            .font(.headline)
                            .fontWeight(.semibold)
                            .foregroundColor(.white)
                        
                        Text(viewModel.currentFetchingTitle)
                            .font(.subheadline)
                            .foregroundColor(.white.opacity(0.9))
                            .lineLimit(2)
                            .multilineTextAlignment(.center)
                        
                        if !viewModel.streamFetchProgress.isEmpty {
                            Text(viewModel.streamFetchProgress)
                                .font(.caption)
                                .foregroundColor(.white.opacity(0.7))
                                .multilineTextAlignment(.center)
                        }
                    }
                }
                .padding(30)
                .applyLiquidGlassBackground(cornerRadius: 16)
                .padding(.horizontal, 40)
            }
        }
    }
    
    @ViewBuilder
    private var qualityThresholdAlertContent: some View {
        TextField("Threshold (0.0 - 1.0)", value: $viewModel.highQualityThreshold, format: .number)
            .keyboardType(.decimalPad)
        
        Button("Save") {
            viewModel.highQualityThreshold = max(0.0, min(1.0, viewModel.highQualityThreshold))
            UserDefaults.standard.set(viewModel.highQualityThreshold, forKey: "highQualityThreshold")
        }
        
        Button("Cancel", role: .cancel) {
            viewModel.highQualityThreshold = UserDefaults.standard.object(forKey: "highQualityThreshold") as? Double ?? 0.9
        }
    }
    
    @ViewBuilder
    private var qualityThresholdAlertMessage: some View {
        Text("Set the minimum similarity score (0.0 to 1.0) for results to be considered high quality. Current: \(String(format: "%.2f", viewModel.highQualityThreshold)) (\(Int(viewModel.highQualityThreshold * 100))%)")
    }
    
    @ViewBuilder
    private var serverSelectionDialogContent: some View {
        ForEach(viewModel.streamOptions) { option in
            Button(option.name) {
                if let service = viewModel.pendingService {
                    resolveSubtitleSelection(
                        subtitles: viewModel.pendingSubtitles,
                        defaultSubtitle: option.subtitle,
                        service: service,
                        streamURL: option.url,
                        headers: option.headers
                    )
                }
            }
        }
        Button("Cancel", role: .cancel) { }
    }
    
    @ViewBuilder
    private var serverSelectionDialogMessage: some View {
        Text("Choose a server to stream from")
    }
    
    @ViewBuilder
    private var seasonPickerDialogContent: some View {
        ForEach(Array(viewModel.availableSeasons.enumerated()), id: \.offset) { index, season in
            Button("Season \(index + 1) (\(season.count) episodes)") {
                viewModel.selectedSeasonIndex = index
                viewModel.pendingEpisodes = season
                viewModel.showingSeasonPicker = false
                viewModel.showingEpisodePicker = true
            }
        }
        Button("Cancel", role: .cancel) {
            viewModel.resetPickerState()
        }
    }
    
    @ViewBuilder
    private var seasonPickerDialogMessage: some View {
        Text("Season \(selectedEpisode?.seasonNumber ?? 1) not found. Please choose the correct season:")
    }
    
    @ViewBuilder
    private var episodePickerDialogContent: some View {
        ForEach(viewModel.pendingEpisodes, id: \.href) { episode in
            Button("Episode \(episode.number)") {
                proceedWithSelectedEpisode(episode)
            }
        }
        Button("Cancel", role: .cancel) {
            viewModel.resetPickerState()
        }
    }
    
    @ViewBuilder
    private var episodePickerDialogMessage: some View {
        if let episode = selectedEpisode {
            Text("Choose the correct episode for S\(episode.seasonNumber)E\(episode.episodeNumber):")
        } else {
            Text("Choose an episode:")
        }
    }
    
    @ViewBuilder
    private var subtitlePickerDialogContent: some View {
        ForEach(viewModel.subtitleOptions, id: \.url) { option in
            Button(option.title) {
                viewModel.showingSubtitlePicker = false
                if let service = viewModel.pendingService,
                   let streamURL = viewModel.pendingStreamURL {
                    playStreamURL(streamURL, service: service, subtitle: option.url, headers: viewModel.pendingHeaders)
                }
            }
        }
        Button("No Subtitles") {
            viewModel.showingSubtitlePicker = false
            if let service = viewModel.pendingService,
               let streamURL = viewModel.pendingStreamURL {
                playStreamURL(streamURL, service: service, subtitle: nil, headers: viewModel.pendingHeaders)
            }
        }
        Button("Cancel", role: .cancel) {
            viewModel.subtitleOptions = []
            viewModel.pendingStreamURL = nil
            viewModel.pendingHeaders = nil
        }
    }
    
    @ViewBuilder
    private var subtitlePickerDialogMessage: some View {
        Text("Choose a subtitle track")
    }
    
    /// Common suffixes that indicate a different season/special (e.g. "Part 2", "Reflection"); main season entry is preferred.
    private static let seasonVariantSuffixes = [" part 2", " part 3", " reflection", " reminiscence", " the movie", " ova", " special"]
    
    private func filterResults(for results: [SearchItem]) -> (highQuality: [SearchItem], lowQuality: [SearchItem]) {
        // When user selected a specific season (e.g. War of Underworld), show only results whose title matches that season
        var candidates: [SearchItem]
        if isSeasonNameMeaningful, let seasonName = selectedSeasonName {
            let filtered = results.filter { $0.title.localizedCaseInsensitiveContains(seasonName) }
            candidates = filtered.isEmpty ? results : filtered
        } else {
            candidates = results
        }
        
        let sortedResults = candidates.map { result -> (result: SearchItem, similarity: Double) in
            let primarySimilarity = algorithmManager.calculateSimilarity(original: mediaTitle, result: result.title)
            let originalSimilarity = originalTitle.map { algorithmManager.calculateSimilarity(original: $0, result: result.title) } ?? 0.0
            return (result: result, similarity: max(primarySimilarity, originalSimilarity))
        }.sorted { a, b in
            if a.similarity != b.similarity { return a.similarity > b.similarity }
            // When we have a season name, prefer the "main" entry (no "Part 2", "Reflection", etc.) so the correct episode list shows first
            if isSeasonNameMeaningful {
                let aIsVariant = Self.seasonVariantSuffixes.contains { a.result.title.lowercased().contains($0) }
                let bIsVariant = Self.seasonVariantSuffixes.contains { b.result.title.lowercased().contains($0) }
                if aIsVariant != bIsVariant { return !aIsVariant }
            }
            return a.result.title < b.result.title
        }
        
        let threshold = viewModel.highQualityThreshold
        let highQuality = sortedResults.filter { $0.similarity >= threshold }.map { $0.result }
        let lowQuality = sortedResults.filter { $0.similarity < threshold }.map { $0.result }
        
        return (highQuality, lowQuality)
    }
    
    var body: some View {
        NavigationView {
            List {
                searchInfoSection
                
                if serviceManager.activeServices.isEmpty {
                    noActiveServicesSection
                } else {
                    servicesResultsSection
                }
            }
            .navigationTitle("Services Result")
#if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
#endif
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Menu {
                        Section("Matching Algorithm") {
                            ForEach(SimilarityAlgorithm.allCases, id: \.self) { algorithm in
                                Button(action: {
                                    algorithmManager.selectedAlgorithm = algorithm
                                }) {
                                    HStack {
                                        Text(algorithm.displayName)
                                        if algorithmManager.selectedAlgorithm == algorithm {
                                            Spacer()
                                            Image(systemName: "checkmark")
                                        }
                                    }
                                }
                            }
                        }
                        
                        Section("Filter Settings") {
                            Button(action: {
                                viewModel.showingFilterEditor = true
                            }) {
                                HStack {
                                    Image(systemName: "slider.horizontal.3")
                                    Text("Quality Threshold")
                                    Spacer()
                                    Text("\(Int(viewModel.highQualityThreshold * 100))%")
                                        .foregroundColor(.secondary)
                                }
                            }
                        }
                    } label: {
                        Image(systemName: "line.3.horizontal.decrease.circle")
                    }
                }
                
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") {
                        presentationMode.wrappedValue.dismiss()
                    }
                }
            }
        }
        .alert("Play Content", isPresented: $viewModel.showingPlayAlert) {
            playAlertButtons
        } message: {
            playAlertMessage
        }
        .overlay(streamFetchingOverlay)
        .onAppear {
            startProgressiveSearch()
        }
        .alert("Quality Threshold", isPresented: $viewModel.showingFilterEditor) {
            qualityThresholdAlertContent
        } message: {
            qualityThresholdAlertMessage
        }
        .adaptiveConfirmationDialog("Select Server", isPresented: $viewModel.showingStreamMenu, titleVisibility: .visible) {
            serverSelectionDialogContent
        } message: {
            serverSelectionDialogMessage
        }
        .adaptiveConfirmationDialog("Select Season", isPresented: $viewModel.showingSeasonPicker, titleVisibility: .visible) {
            seasonPickerDialogContent
        } message: {
            seasonPickerDialogMessage
        }
        .adaptiveConfirmationDialog("Select Episode", isPresented: $viewModel.showingEpisodePicker, titleVisibility: .visible) {
            episodePickerDialogContent
        } message: {
            episodePickerDialogMessage
        }
        .adaptiveConfirmationDialog("Select Subtitle", isPresented: $viewModel.showingSubtitlePicker, titleVisibility: .visible) {
            subtitlePickerDialogContent
        } message: {
            subtitlePickerDialogMessage
        }
        .adaptiveConfirmationDialog("Sub or Dub?", isPresented: $viewModel.showingSubDubPicker, titleVisibility: .visible) {
            Button("Sub (subtitled)") {
                if let p = pendingSubDub {
                    if p.fromEpisodeList {
                        performFetchStreamForEpisode(episodeHref: p.href, jsController: p.jsController, service: p.service, preferredCategory: "sub")
                    } else {
                        performFetchStream(href: p.href, jsController: p.jsController, service: p.service, preferredCategory: "sub")
                    }
                    pendingSubDub = nil
                }
                viewModel.showingSubDubPicker = false
            }
            Button("Dub (dubbed)") {
                if let p = pendingSubDub {
                    if p.fromEpisodeList {
                        performFetchStreamForEpisode(episodeHref: p.href, jsController: p.jsController, service: p.service, preferredCategory: "dub")
                    } else {
                        performFetchStream(href: p.href, jsController: p.jsController, service: p.service, preferredCategory: "dub")
                    }
                    pendingSubDub = nil
                }
                viewModel.showingSubDubPicker = false
            }
            Button("Cancel", role: .cancel) {
                pendingSubDub = nil
                viewModel.showingSubDubPicker = false
                viewModel.isFetchingStreams = false
            }
        } message: {
            Text("Choose audio for this source.")
        }
        .alert("Stream Error", isPresented: $viewModel.showingStreamError) {
            Button("OK", role: .cancel) {
                viewModel.streamError = nil
            }
        } message: {
            if let error = viewModel.streamError {
                Text(error)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .noirMiruroTryNextServer)) { _ in
            advanceMiruroToNextServerAfterPlaybackFailure()
        }
    }
    
    /// After NormalPlayer fails on a Miruro stream, try the next server in queue (same subtitle choice).
    private func advanceMiruroToNextServerAfterPlaybackFailure() {
        // Ignore stale notifications from previous playback sessions.
        guard viewModel.miruroFallbackService != nil else {
            Logger.shared.log("Miruro: ignoring retry notification without active fallback context", type: "Stream")
            return
        }
        guard !viewModel.miruroFallbackQueue.isEmpty else {
            viewModel.streamError = "All video servers failed for this source."
            viewModel.showingStreamError = true
            viewModel.resetStreamState()
            return
        }
        guard let svc = viewModel.miruroFallbackService else { return }
        let next = viewModel.miruroFallbackQueue.removeFirst()
        Logger.shared.log("Miruro: server failed, trying next (\(next.name))", type: "Stream")
        playStreamURL(next.url, service: svc, subtitle: nil, headers: next.headers, externalSubtitleTracks: viewModel.miruroFallbackExternalSubs)
    }
    
    private func startProgressiveSearch() {
        let activeServices = serviceManager.activeServices
        viewModel.totalServicesCount = activeServices.count
        
        guard !activeServices.isEmpty else {
            viewModel.isSearching = false
            return
        }
        
        // Use season name to narrow search when user picked a specific season (e.g. "Sword Art Online War of Underworld")
        let searchQuery: String
        if isSeasonNameMeaningful, let name = selectedSeasonName {
            searchQuery = "\(mediaTitle) \(name)"
        } else {
            searchQuery = mediaTitle
        }
        let hasAlternativeTitle = originalTitle.map { !$0.isEmpty && $0.lowercased() != mediaTitle.lowercased() } ?? false
        
        Task {
            await serviceManager.searchInActiveServicesProgressively(
                query: searchQuery,
                onResult: { service, results in
                    Task { @MainActor in
                        self.viewModel.moduleResults[service.id] = results ?? []
                        self.viewModel.searchedServices.insert(service.id)
                        
                        if results == nil {
                            self.viewModel.failedServices.insert(service.id)
                        } else {
                            self.viewModel.failedServices.remove(service.id)
                        }
                    }
                },
                onComplete: {
                    if hasAlternativeTitle, let altTitle = self.originalTitle {
                        Task {
                            await self.serviceManager.searchInActiveServicesProgressively(
                                query: altTitle,
                                onResult: { service, additionalResults in
                                    Task { @MainActor in
                                        let additional = additionalResults ?? []
                                        let existing = self.viewModel.moduleResults[service.id] ?? []
                                        let existingHrefs = Set(existing.map { $0.href })
                                        let newResults = additional.filter { !existingHrefs.contains($0.href) }
                                        self.viewModel.moduleResults[service.id] = existing + newResults
                                        
                                        if additionalResults == nil {
                                            self.viewModel.failedServices.insert(service.id)
                                        }
                                    }
                                },
                                onComplete: {
                                    Task { @MainActor in
                                        self.viewModel.isSearching = false
                                    }
                                }
                            )
                        }
                    } else {
                        Task { @MainActor in
                            self.viewModel.isSearching = false
                        }
                    }
                }
            )
        }
    }
    
    @ViewBuilder
    private func serviceHeader(for service: Service, highQualityCount: Int, lowQualityCount: Int, isSearching: Bool = false) -> some View {
        HStack {
            NoirImage(url: URL(string: service.metadata.iconUrl)) {
                    Image(systemName: "tv.circle")
                        .foregroundColor(.secondary)
                }
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 20, height: 20)
            
            Text(service.metadata.sourceName)
                .font(.subheadline)
                .fontWeight(.medium)
            
            if viewModel.failedServices.contains(service.id) {
                Image(systemName: "exclamationmark.octagon.fill")
                    .foregroundColor(.red)
                    .font(.caption)
                    .padding(.leading, 6)
            }
            
            Spacer()
            
            HStack(spacing: 4) {
                if isSearching {
                    ProgressView()
                        .scaleEffect(0.6)
                        .frame(width: 12, height: 12)
                } else {
                    if highQualityCount > 0 {
                        Text("\(highQualityCount)")
                            .font(.caption2)
                            .fontWeight(.semibold)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 2)
                            .background(Color.green.opacity(0.2))
                            .foregroundColor(.green)
                            .cornerRadius(4)
                    }
                    
                    if lowQualityCount > 0 {
                        Text("\(lowQualityCount)")
                            .font(.caption2)
                            .fontWeight(.semibold)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 2)
                            .background(Color.orange.opacity(0.2))
                            .foregroundColor(.orange)
                            .cornerRadius(4)
                    }
                }
            }
        }
    }
    
    private func getResultCount(for service: Service) -> Int {
        return viewModel.moduleResults[service.id]?.count ?? 0
    }
    
    private func proceedWithSelectedEpisode(_ episode: EpisodeLink) {
        viewModel.showingEpisodePicker = false
        
        guard let jsController = viewModel.pendingJSController,
              let service = viewModel.pendingService else {
            Logger.shared.log("Missing controller or service for episode selection", type: "Error")
            viewModel.resetPickerState()
            return
        }
        
        viewModel.isFetchingStreams = true
        viewModel.streamFetchProgress = "Fetching selected episode stream..."
        
        fetchStreamForEpisode(episode.href, jsController: jsController, service: service)
    }
    
    private func fetchStreamForEpisode(_ episodeHref: String, jsController: JSController, service: Service) {
        if service.metadata.sourceName == "Miruro" {
            pendingSubDub = (episodeHref, jsController, service, true)
            viewModel.showingSubDubPicker = true
            return
        }
        performFetchStreamForEpisode(episodeHref: episodeHref, jsController: jsController, service: service, preferredCategory: nil)
    }
    
    private func performFetchStreamForEpisode(episodeHref: String, jsController: JSController, service: Service, preferredCategory: String?) {
        if service.metadata.sourceName == "Miruro" {
            // Fresh fetch should not inherit stale fallback state from previous playback sessions.
            viewModel.clearMiruroFallbackContext()
        }
        let softsub = service.metadata.softsub ?? false
        jsController.fetchStreamUrlJS(episodeUrl: episodeHref, softsub: softsub, module: service, preferredCategory: preferredCategory) { streamResult in
            Task { @MainActor in
                let (streams, subtitles, sources) = streamResult
                Logger.shared.log("Stream fetch result - Streams: \(streams?.count ?? 0), Sources: \(sources?.count ?? 0)", type: "Stream")
                self.viewModel.streamFetchProgress = "Processing stream data..."
                self.processStreamResult(streams: streams, subtitles: subtitles, sources: sources, service: service)
                self.viewModel.resetPickerState()
            }
        }
    }
    
    @MainActor
    private func playContent(_ result: SearchItem) async {
        Logger.shared.log("Starting playback for: \(result.title)", type: "Stream")
        
        viewModel.isFetchingStreams = true
        viewModel.currentFetchingTitle = result.title
        viewModel.streamFetchProgress = "Initializing..."
        
        guard let service = serviceManager.activeServices.first(where: { service in
            viewModel.moduleResults[service.id]?.contains { $0.id == result.id } ?? false
        }) else {
            Logger.shared.log("Could not find service for result: \(result.title)", type: "Error")
            viewModel.isFetchingStreams = false
            viewModel.streamError = "Could not find the service for '\(result.title)'. Please try again."
            viewModel.showingStreamError = true
            return
        }
        
        Logger.shared.log("Using service: \(service.metadata.sourceName)", type: "Stream")
        viewModel.streamFetchProgress = "Loading service: \(service.metadata.sourceName)"
        
        let jsController = JSController()
        jsController.loadScript(service.jsScript)
        Logger.shared.log("JavaScript loaded successfully", type: "Stream")
        
        viewModel.streamFetchProgress = "Fetching episodes..."
        
        jsController.fetchEpisodesJS(url: result.href) { episodes in
            Task { @MainActor in
                self.handleEpisodesFetched(episodes, result: result, service: service, jsController: jsController)
            }
        }
    }
    
    @MainActor
    private func handleEpisodesFetched(_ episodes: [EpisodeLink], result: SearchItem, service: Service, jsController: JSController) {
        Logger.shared.log("Fetched \(episodes.count) episodes for: \(result.title)", type: "Stream")
        viewModel.streamFetchProgress = "Found \(episodes.count) episode\(episodes.count == 1 ? "" : "s")"
        
        if episodes.isEmpty {
            Logger.shared.log("No episodes found for: \(result.title)", type: "Error")
            viewModel.isFetchingStreams = false
            viewModel.streamError = "No episodes found for '\(result.title)'. The source may be unavailable."
            viewModel.showingStreamError = true
            return
        }
        
        if isMovie {
            let targetHref = episodes.first?.href ?? result.href
            Logger.shared.log("Movie - Using href: \(targetHref)", type: "Stream")
            viewModel.streamFetchProgress = "Preparing movie stream..."
            fetchFinalStream(href: targetHref, jsController: jsController, service: service)
            return
        }
        
        guard let selectedEp = selectedEpisode else {
            Logger.shared.log("No episode selected for TV show", type: "Error")
            viewModel.isFetchingStreams = false
            viewModel.streamError = "No episode selected. Please select an episode first."
            viewModel.showingStreamError = true
            return
        }
        
        viewModel.streamFetchProgress = "Finding episode S\(selectedEp.seasonNumber)E\(selectedEp.episodeNumber)..."
        let seasons = parseSeasons(from: episodes)
        let targetSeasonIndex = selectedEp.seasonNumber - 1
        let targetEpisodeNumber = selectedEp.episodeNumber
        
        if let targetHref = findEpisodeHref(seasons: seasons, seasonIndex: targetSeasonIndex, episodeNumber: targetEpisodeNumber) {
            viewModel.streamFetchProgress = "Found episode, fetching stream..."
            fetchFinalStream(href: targetHref, jsController: jsController, service: service)
        } else if targetEpisodeNumber > 0, targetEpisodeNumber <= episodes.count {
            // Fallback: some providers (like split-cour seasons) reset episode numbers per part
            // but keep the correct order in the list. In that case, map TMDB's episode number
            // directly to the position in the fetched array.
            let fallback = episodes[targetEpisodeNumber - 1]
            Logger.shared.log("Episode mapping fallback: using positional episode #\(targetEpisodeNumber) (provider number \(fallback.number)) for '\(result.title)'", type: "Stream")
            viewModel.streamFetchProgress = "Found episode (by position), fetching stream..."
            fetchFinalStream(href: fallback.href, jsController: jsController, service: service)
        } else {
            showEpisodePicker(seasons: seasons, result: result, jsController: jsController, service: service)
        }
    }
    
    private func parseSeasons(from episodes: [EpisodeLink]) -> [[EpisodeLink]] {
        var seasons: [[EpisodeLink]] = []
        var currentSeason: [EpisodeLink] = []
        var lastEpisodeNumber = 0
        
        for episode in episodes {
            if episode.number == 1 || episode.number <= lastEpisodeNumber {
                if !currentSeason.isEmpty {
                    seasons.append(currentSeason)
                    currentSeason = []
                }
            }
            currentSeason.append(episode)
            lastEpisodeNumber = episode.number
        }
        
        if !currentSeason.isEmpty {
            seasons.append(currentSeason)
        }
        
        return seasons
    }
    
    private func findEpisodeHref(seasons: [[EpisodeLink]], seasonIndex: Int, episodeNumber: Int) -> String? {
        if seasonIndex >= 0 && seasonIndex < seasons.count {
            if let episode = seasons[seasonIndex].first(where: { $0.number == episodeNumber }) {
                Logger.shared.log("Found exact match: S\(seasonIndex + 1)E\(episodeNumber)", type: "Stream")
                return episode.href
            }
        }
        
        for season in seasons {
            if let episode = season.first(where: { $0.number == episodeNumber }) {
                Logger.shared.log("Found episode \(episodeNumber) in different season, auto-playing", type: "Stream")
                return episode.href
            }
        }
        
        return nil
    }
    
    @MainActor
    private func showEpisodePicker(seasons: [[EpisodeLink]], result: SearchItem, jsController: JSController, service: Service) {
        viewModel.pendingResult = result
        viewModel.pendingJSController = jsController
        viewModel.pendingService = service
        viewModel.isFetchingStreams = false
        
        if seasons.count > 1 {
            viewModel.availableSeasons = seasons
            viewModel.showingSeasonPicker = true
        } else if let firstSeason = seasons.first, !firstSeason.isEmpty {
            viewModel.pendingEpisodes = firstSeason
            viewModel.showingEpisodePicker = true
        } else {
            Logger.shared.log("No episodes found in any season", type: "Error")
            viewModel.streamError = "No episodes found in any season. The source may have incomplete data."
            viewModel.showingStreamError = true
        }
    }
    
    private func fetchFinalStream(href: String, jsController: JSController, service: Service) {
        if service.metadata.sourceName == "Miruro" {
            pendingSubDub = (href, jsController, service, false)
            viewModel.showingSubDubPicker = true
            return
        }
        performFetchStream(href: href, jsController: jsController, service: service, preferredCategory: nil)
    }
    
    private func performFetchStream(href: String, jsController: JSController, service: Service, preferredCategory: String?) {
        if service.metadata.sourceName == "Miruro" {
            // Fresh fetch should not inherit stale fallback state from previous playback sessions.
            viewModel.clearMiruroFallbackContext()
        }
        let softsub = service.metadata.softsub ?? false
        jsController.fetchStreamUrlJS(episodeUrl: href, softsub: softsub, module: service, preferredCategory: preferredCategory) { streamResult in
            Task { @MainActor in
                let (streams, subtitles, sources) = streamResult
                self.processStreamResult(streams: streams, subtitles: subtitles, sources: sources, service: service)
            }
        }
    }
    
    @MainActor
    private func processStreamResult(streams: [String]?, subtitles: [String]?, sources: [[String: Any]]?, service: Service) {
        Logger.shared.log("Stream fetch result - Streams: \(streams?.count ?? 0), Sources: \(sources?.count ?? 0)", type: "Stream")
        viewModel.streamFetchProgress = "Processing stream data..."
        
        let availableStreams = parseStreamOptions(streams: streams, sources: sources)

        // Miruro: use best server first (module order: HLS, quality); on playback failure try next automatically.
        if service.metadata.sourceName == "Miruro", availableStreams.count > 1 {
            if downloadIntent {
                viewModel.isFetchingStreams = false
                let best = availableStreams[0]
                Logger.shared.log("Miruro download: using best of \(availableStreams.count) servers (\(best.name))", type: "Stream")
                resolveSubtitleSelection(
                    subtitles: subtitles,
                    defaultSubtitle: best.subtitle,
                    service: service,
                    streamURL: best.url,
                    headers: best.headers
                )
                return
            }
            viewModel.miruroFallbackQueue = Array(availableStreams.dropFirst())
            viewModel.miruroFallbackService = service
            viewModel.isFetchingStreams = false
            let best = availableStreams[0]
            Logger.shared.log("Miruro: playing best server first (\(best.name)); \(viewModel.miruroFallbackQueue.count) fallback(s) if needed", type: "Stream")
            resolveSubtitleSelection(
                subtitles: subtitles,
                defaultSubtitle: best.subtitle,
                service: service,
                streamURL: best.url,
                headers: best.headers
            )
            return
        }
        
        if service.metadata.sourceName == "Miruro" {
            // This playback has no fallback chain; avoid stale "last server" state.
            viewModel.clearMiruroFallbackContext()
        }
        
        if availableStreams.count > 1 {
            Logger.shared.log("Found \(availableStreams.count) stream options, showing selection", type: "Stream")
            viewModel.streamOptions = availableStreams
            viewModel.pendingSubtitles = subtitles
            viewModel.pendingService = service
            viewModel.isFetchingStreams = false
            viewModel.showingStreamMenu = true
            return
        }
        
        if let firstStream = availableStreams.first {
            resolveSubtitleSelection(
                subtitles: subtitles,
                defaultSubtitle: firstStream.subtitle,
                service: service,
                streamURL: firstStream.url,
                headers: firstStream.headers
            )
        } else if let streamURL = extractSingleStreamURL(streams: streams, sources: sources) {
            resolveSubtitleSelection(
                subtitles: subtitles,
                defaultSubtitle: nil,
                service: service,
                streamURL: streamURL.url,
                headers: streamURL.headers
            )
        } else {
            Logger.shared.log("Failed to create URL from stream string", type: "Error")
            viewModel.isFetchingStreams = false
            viewModel.streamError = "Failed to get a valid stream URL. The source may be temporarily unavailable."
            viewModel.showingStreamError = true
        }
    }
    
    private func parseStreamOptions(streams: [String]?, sources: [[String: Any]]?) -> [StreamOption] {
        var availableStreams: [StreamOption] = []
        
        if let sources = sources, !sources.isEmpty {
            for (idx, source) in sources.enumerated() {
                guard let rawUrl = source["streamUrl"] as? String ?? source["url"] as? String, !rawUrl.isEmpty else { continue }
                let title = (source["title"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
                let headers = safeConvertToHeaders(source["headers"])
                let subtitle = source["subtitle"] as? String
                let option = StreamOption(
                    name: title?.isEmpty == false ? title! : "Stream \(idx + 1)",
                    url: rawUrl,
                    headers: headers,
                    subtitle: subtitle
                )
                availableStreams.append(option)
            }
        } else if let streams = streams, streams.count > 1 {
            availableStreams = parseStreamStrings(streams)
        }
        
        return availableStreams
    }
    
    private func parseStreamStrings(_ streams: [String]) -> [StreamOption] {
        var options: [StreamOption] = []
        var index = 0
        var unnamedCount = 1
        
        while index < streams.count {
            let entry = streams[index]
            if isURL(entry) {
                options.append(StreamOption(name: "Stream \(unnamedCount)", url: entry, headers: nil, subtitle: nil))
                unnamedCount += 1
                index += 1
            } else {
                let nextIndex = index + 1
                if nextIndex < streams.count, isURL(streams[nextIndex]) {
                    options.append(StreamOption(name: entry, url: streams[nextIndex], headers: nil, subtitle: nil))
                    index += 2
                } else {
                    index += 1
                }
            }
        }
        
        return options
    }
    
    private func isURL(_ value: String) -> Bool {
        let lowercased = value.lowercased()
        return lowercased.hasPrefix("http://") || lowercased.hasPrefix("https://")
    }
    
    private func extractSingleStreamURL(streams: [String]?, sources: [[String: Any]]?) -> (url: String, headers: [String: String]?)? {
        if let sources = sources, let firstSource = sources.first {
            if let streamUrl = firstSource["streamUrl"] as? String {
                return (streamUrl, safeConvertToHeaders(firstSource["headers"]))
            } else if let urlString = firstSource["url"] as? String {
                return (urlString, safeConvertToHeaders(firstSource["headers"]))
            }
        } else if let streams = streams, !streams.isEmpty {
            let urlCandidates = streams.filter { $0.hasPrefix("http") }
            if let firstURL = urlCandidates.first {
                return (firstURL, nil)
            } else if let first = streams.first {
                return (first, nil)
            }
        }
        return nil
    }
    
    @MainActor
    private func resolveSubtitleSelection(subtitles: [String]?, defaultSubtitle: String?, service: Service, streamURL: String, headers: [String: String]?) {
        // Miruro play: softsubs merged into HLS master → system subtitle menu (default off).
        if service.metadata.sourceName == "Miruro", !downloadIntent {
            let options = parseSubtitleOptions(from: subtitles ?? [])
            viewModel.miruroFallbackExternalSubs = options
            playStreamURL(streamURL, service: service, subtitle: nil, headers: headers, externalSubtitleTracks: options)
            return
        }
        
        guard let subtitles = subtitles, !subtitles.isEmpty else {
            playStreamURL(streamURL, service: service, subtitle: defaultSubtitle, headers: headers)
            return
        }
        
        let options = parseSubtitleOptions(from: subtitles)
        guard !options.isEmpty else {
            playStreamURL(streamURL, service: service, subtitle: defaultSubtitle, headers: headers)
            return
        }
        
        if options.count == 1 {
            playStreamURL(streamURL, service: service, subtitle: options[0].url, headers: headers)
            return
        }
        
        viewModel.subtitleOptions = options
        viewModel.pendingStreamURL = streamURL
        viewModel.pendingHeaders = headers
        viewModel.pendingService = service
        viewModel.pendingDefaultSubtitle = defaultSubtitle
        viewModel.isFetchingStreams = false
        viewModel.showingSubtitlePicker = true
    }
    
    private func parseSubtitleOptions(from subtitles: [String]) -> [(title: String, url: String)] {
        var options: [(String, String)] = []
        var index = 0
        var fallbackIndex = 1
        
        while index < subtitles.count {
            let entry = subtitles[index]
            if isURL(entry) {
                options.append(("Subtitle \(fallbackIndex)", entry))
                fallbackIndex += 1
                index += 1
            } else {
                let nextIndex = index + 1
                if nextIndex < subtitles.count, isURL(subtitles[nextIndex]) {
                    options.append((entry, subtitles[nextIndex]))
                    fallbackIndex += 1
                    index += 2
                } else {
                    index += 1
                }
            }
        }
        return options
    }
    
    private func enqueueDownload(streamURL url: String, service: Service, subtitle: String?, headers: [String: String]?) {
        let serviceURL = service.metadata.baseUrl
        var finalHeaders: [String: String] = [
            "Origin": serviceURL,
            "Referer": serviceURL,
            "User-Agent": URLSession.randomUserAgent
        ]
        if let custom = headers {
            for (k, v) in custom { finalHeaders[k] = v }
            if finalHeaders["User-Agent"] == nil { finalHeaders["User-Agent"] = URLSession.randomUserAgent }
        }
        let displayTitle: String
        if let ep = selectedEpisode {
            displayTitle = "\(mediaTitle) S\(ep.seasonNumber)E\(ep.episodeNumber)"
        } else {
            displayTitle = mediaTitle
        }
        let isAnime = service.metadata.type?.lowercased() == "anime"
        DownloadManager.shared.enqueueDownload(
            tmdbId: tmdbId,
            isMovie: isMovie,
            title: mediaTitle,
            displayTitle: displayTitle,
            posterURL: posterURL,
            seasonNumber: selectedEpisode?.seasonNumber,
            episodeNumber: selectedEpisode?.episodeNumber,
            episodeName: selectedEpisode?.name,
            streamURL: url,
            headers: finalHeaders,
            subtitleURL: subtitle,
            serviceBaseURL: serviceURL,
            isAnime: isAnime
        )
        viewModel.resetStreamState()
        presentationMode.wrappedValue.dismiss()
    }
    
    /// Builds Infuse-friendly filename (with {tmdb-id}) and display title for proxy so Infuse shows correct metadata.
    private static func infuseMetadataFilename(mediaTitle: String, tmdbId: Int, isMovie: Bool, episode: TMDBEpisode?) -> (filename: String?, displayTitle: String?) {
        // Keep this safe for URL path usage (and external player file-ish parsing).
        // Note: StreamProxyServer will also sanitize, but doing it here keeps filenames stable/clean.
        let invalid = CharacterSet(charactersIn: " \\/:|<>*?\"'")
        let sanitized = mediaTitle
            .components(separatedBy: .whitespaces)
            .filter { !$0.isEmpty }
            .joined(separator: ".")
            .unicodeScalars
            .filter { !invalid.contains($0) }
            .map { String($0) }
            .joined()
        guard !sanitized.isEmpty else { return (nil, nil) }
        let displayTitle: String
        let filename: String
        if isMovie {
            displayTitle = mediaTitle
            filename = "\(sanitized).{tmdb-\(tmdbId)}.m3u8"
        } else if let ep = episode {
            let s = String(format: "S%02dE%02d", ep.seasonNumber, ep.episodeNumber)
            displayTitle = "\(mediaTitle) - \(s)"
            filename = "\(sanitized).\(s).{tmdb-\(tmdbId)}.m3u8"
        } else {
            displayTitle = mediaTitle
            filename = "\(sanitized).{tmdb-\(tmdbId)}.m3u8"
        }
        return (filename, displayTitle)
    }
    
    private func playStreamURL(_ url: String, service: Service, subtitle: String?, headers: [String: String]?, externalSubtitleTracks: [(title: String, url: String)] = []) {
        let miruro = service.metadata.sourceName == "Miruro"
        let savedQueue = miruro ? viewModel.miruroFallbackQueue : []
        let savedSvc = miruro ? viewModel.miruroFallbackService : nil
        let savedExtSubs = miruro ? viewModel.miruroFallbackExternalSubs : []
        
        viewModel.resetStreamState()
        
        if miruro {
            viewModel.miruroFallbackQueue = savedQueue
            viewModel.miruroFallbackService = savedSvc
            viewModel.miruroFallbackExternalSubs = savedExtSubs.isEmpty ? externalSubtitleTracks : savedExtSubs
        }
        
        if downloadIntent {
            enqueueDownload(streamURL: url, service: service, subtitle: subtitle, headers: headers)
            return
        }
        
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 300_000_000)
            
            guard let streamURL = URL(string: url) else {
                Logger.shared.log("Invalid stream URL: \(url)", type: "Error")
                viewModel.streamError = "Invalid stream URL. The source returned a malformed URL."
                viewModel.showingStreamError = true
                return
            }
            
            var finalHeaders: [String: String] = [
                "Origin": service.metadata.baseUrl,
                "Referer": service.metadata.baseUrl,
                "User-Agent": URLSession.randomUserAgent
            ]
            if let custom = headers {
                Logger.shared.log("Using custom headers: \(custom)", type: "Stream")
                for (k, v) in custom { finalHeaders[k] = v }
                if finalHeaders["User-Agent"] == nil { finalHeaders["User-Agent"] = URLSession.randomUserAgent }
            }
            Logger.shared.log("Final headers: \(finalHeaders)", type: "Stream")
            
            let externalRaw = UserDefaults.standard.string(forKey: "externalPlayer") ?? ExternalPlayer.none.rawValue
            let external = ExternalPlayer(rawValue: externalRaw) ?? .none
            let serviceURL = service.metadata.baseUrl
            let needsHeaders = !serviceURL.isEmpty || (headers != nil && !(headers?.isEmpty ?? true))
            
            if external != .none {
                let urlToOpen: String
                let (metadataFilename, displayTitle) = Self.infuseMetadataFilename(mediaTitle: mediaTitle, tmdbId: tmdbId, isMovie: isMovie, episode: selectedEpisode)
                if needsHeaders, let proxyURL = StreamProxyServer.shared.start(streamURL: url, headers: finalHeaders, metadataFilename: metadataFilename, displayTitle: displayTitle) {
                    // Cache-bust so each play = new URL; path already has metadata for Infuse (e.g. Show.S01E01.{tmdb-xxx}.m3u8)
                    let uniqueURL = proxyURL + "?t=" + UUID().uuidString
                    urlToOpen = uniqueURL
                    Logger.shared.log("Proxying stream for external player at \(proxyURL)", type: "Stream")
                    final class TaskIDHolder {
                        var value: UIBackgroundTaskIdentifier = .invalid
                    }
                    let holder = TaskIDHolder()
                    holder.value = UIApplication.shared.beginBackgroundTask {
                        StreamProxyServer.shared.stop()
                        if holder.value != .invalid { UIApplication.shared.endBackgroundTask(holder.value) }
                    }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 180) {
                        StreamProxyServer.shared.stop()
                        if holder.value != .invalid { UIApplication.shared.endBackgroundTask(holder.value) }
                    }
                    // Delay opening Infuse so the proxy listener is ready to accept connections
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                        if let scheme = external.schemeURL(for: uniqueURL), UIApplication.shared.canOpenURL(scheme) {
                            UIApplication.shared.open(scheme, options: [:], completionHandler: nil)
                            Logger.shared.log("Opening external player with scheme: \(scheme)", type: "General")
                        }
                    }
                    return
                } else if !needsHeaders {
                    urlToOpen = url
                } else {
                    Logger.shared.log("Stream requires headers; using in-app player instead of external", type: "Stream")
                    urlToOpen = ""
                }
                if !urlToOpen.isEmpty, let scheme = external.schemeURL(for: urlToOpen), UIApplication.shared.canOpenURL(scheme) {
                    UIApplication.shared.open(scheme, options: [:], completionHandler: nil)
                    Logger.shared.log("Opening external player with scheme: \(scheme)", type: "General")
                    return
                }
                if needsHeaders && urlToOpen.isEmpty {
                    // proxy failed or not attempted; fall through to in-app
                } else if !needsHeaders {
                    return
                }
            }
            
            let inAppRaw = UserDefaults.standard.string(forKey: "inAppPlayer") ?? "Normal"
            let inAppPlayer = (inAppRaw == "mpv") ? "mpv" : "Normal"
            
            if inAppPlayer == "mpv" {
                let preset = PlayerPreset.presets.first
                let subURLs: [String] = externalSubtitleTracks.isEmpty ? (subtitle.map { [$0] } ?? []) : externalSubtitleTracks.map(\.url)
                let subtitleArray: [String]? = subURLs.isEmpty ? nil : subURLs
                let pvc = PlayerViewController(
                    url: streamURL,
                    preset: preset ?? PlayerPreset(title: "Default", summary: "", stream: nil, commands: []),
                    headers: finalHeaders,
                    subtitles: subtitleArray
                )
                if isMovie {
                    pvc.mediaInfo = .movie(id: tmdbId, title: mediaTitle)
                } else if let episode = selectedEpisode {
                    pvc.mediaInfo = .episode(showId: tmdbId, showTitle: mediaTitle, seasonNumber: episode.seasonNumber, episodeNumber: episode.episodeNumber)
                }
                pvc.modalPresentationStyle = .fullScreen
                
                if let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
                   let rootVC = windowScene.windows.first?.rootViewController {
                    rootVC.presentPlayerAvoidingSheet(pvc, animated: true, completion: nil)
                } else {
                    Logger.shared.log("Failed to find root view controller to present MPV player", type: "Error")
                }
                return
            } else {
                var urlToPlay = streamURL
                let isMiruro = service.metadata.sourceName == "Miruro"
                let extSubs = isMiruro ? viewModel.miruroFallbackExternalSubs : externalSubtitleTracks
                let wantsNativeSoftSubs = !extSubs.isEmpty

                var proxyBase: String? = nil
                if needsHeaders || wantsNativeSoftSubs {
                    let (metadataFilename, displayTitle) = Self.infuseMetadataFilename(mediaTitle: mediaTitle, tmdbId: tmdbId, isMovie: isMovie, episode: selectedEpisode)
                    if let proxyURLString = StreamProxyServer.shared.start(streamURL: url, headers: finalHeaders, metadataFilename: metadataFilename, displayTitle: displayTitle),
                       let proxyURL = URL(string: proxyURLString) {
                        proxyBase = "\(proxyURL.scheme ?? "http")://\(proxyURL.host ?? "127.0.0.1"):\(proxyURL.port ?? 80)"

                        urlToPlay = proxyURL
                        Logger.shared.log("Proxying stream for in-app player so segments get headers", type: "Stream")

                        DispatchQueue.main.asyncAfter(deadline: .now() + 300) {
                            StreamProxyServer.shared.stop()
                        }
                    }
                }
                
                Task { @MainActor in
                    var playURL = urlToPlay
                    let playerVC = NormalPlayer()
                    playerVC.miruroTryNextServerOnFailure = isMiruro && !viewModel.miruroFallbackQueue.isEmpty
                    playerVC.miruroLastServerAttempt = isMiruro && viewModel.miruroFallbackQueue.isEmpty && viewModel.miruroFallbackService != nil

                    #if os(iOS)
                    // Keep subtitles in AVPlayer's native "... > Subtitles" menu (no custom subtitle button).
                    playerVC.softSubtitleTracks = []
                    if isMiruro, wantsNativeSoftSubs, let proxyBase {
                        func isEnglishSubtitle(title: String, url: String) -> Bool {
                            let t = title.lowercased()
                            let u = url.lowercased()
                            if t.contains("spanish") || t.contains("espanol") || t.contains("español") || t.contains("french") || t.contains("arabic") || t.contains("portuguese") {
                                return false
                            }
                            if t.contains("english") || t.contains(" eng") || t == "en" || t.contains("[en]") { return true }
                            if u.contains("lang=en") || u.contains("/eng") || u.contains("_en") || u.contains("-en") { return true }
                            // Miruro labels are often generic, so keep known Noir options as English.
                            if t.contains("sign") || t.contains("song") || t.contains("full") || t.contains("dialog") || t.contains("cc") || t.contains("caption") {
                                return true
                            }
                            return false
                        }

                        func isLikelySubtitleURL(_ s: String) -> Bool {
                            let u = s.lowercased()
                            return u.contains(".vtt")
                                || u.contains(".srt")
                                || u.contains("format=vtt")
                                || u.contains("format=srt")
                                || u.contains("/sub")
                                || u.contains("subtitle")
                                || u.contains("captions")
                        }

                        func looksLikeSignsTrack(title: String, url: String) -> Bool {
                            let t = title.lowercased()
                            let u = url.lowercased()
                            if t.contains("signs & songs") || t.contains("signs and songs") { return true }
                            return t.contains("sign") || t.contains("song") || u.contains("sign") || u.contains("song")
                        }

                        func looksLikeFullTrack(title: String, url: String) -> Bool {
                            let t = title.lowercased()
                            let u = url.lowercased()
                            return t.contains("full")
                                || t.contains("dialog")
                                || t.contains("dialogue")
                                || t.contains("cc")
                                || t.contains("caption")
                                || t.contains("english")
                                || u.contains("cc")
                        }

                        let deduped = Array(Dictionary(extSubs.map { ($0.url, $0) }, uniquingKeysWith: { first, _ in first }).values)
                        let englishSubs = deduped.filter { isEnglishSubtitle(title: $0.title, url: $0.url) && isLikelySubtitleURL($0.url) }
                        let fallbackSubs = deduped.filter { isLikelySubtitleURL($0.url) }
                        let pool = englishSubs.isEmpty ? fallbackSubs : englishSubs

                        let signsTrack = pool.first { looksLikeSignsTrack(title: $0.title, url: $0.url) }
                        let fullTrack = pool.first {
                            if looksLikeSignsTrack(title: $0.title, url: $0.url) { return false }
                            return looksLikeFullTrack(title: $0.title, url: $0.url)
                        } ?? pool.first

                        guard !pool.isEmpty else {
                            Logger.shared.log("Native subtitle menu: no likely subtitle tracks available", type: "Stream")
                            return
                        }

                        var nativeSubtitleTracks: [(title: String, url: String)] = []
                        if let fullTrack {
                            nativeSubtitleTracks.append(("Delay", "delay:+0.80|\(fullTrack.url)"))
                        }
                        if let signsTrack {
                            nativeSubtitleTracks.append(("Signs & Songs", signsTrack.url))
                        }
                        if let fullTrack {
                            // Avoid duplicate track entries with different names for same URL.
                            if !nativeSubtitleTracks.contains(where: { $0.url == fullTrack.url }) {
                                nativeSubtitleTracks.append(("Full Dialogue", fullTrack.url))
                            } else if nativeSubtitleTracks.first?.title == "Delay" {
                                nativeSubtitleTracks.append(("Full Dialogue", fullTrack.url))
                            }
                        }

                        let variantForMaster = playURL
                        if !nativeSubtitleTracks.isEmpty,
                           let injectedURL = StreamProxyServer.shared.registerSoftSubHLSMaster(
                                variantURL: variantForMaster,
                                subtitleTracks: nativeSubtitleTracks
                           ) {
                            playURL = injectedURL
                            let labels = nativeSubtitleTracks.map(\.title).joined(separator: ", ")
                            Logger.shared.log("Native subtitle menu tracks: \(labels) via \(proxyBase)", type: "Stream")
                        }
                    }
                    #endif

                    if playURL.host == "127.0.0.1", let scheme = playURL.scheme, let host = playURL.host, let port = playURL.port,
                       let readyURL = URL(string: "\(scheme)://\(host):\(port)/__noir_ready") {
                        func isProxyReady(_ url: URL) async -> Bool {
                            do {
                                let (_, response) = try await URLSession.shared.data(from: url)
                                let code = (response as? HTTPURLResponse)?.statusCode ?? 0
                                return code == 200
                            } catch {
                                return false
                            }
                        }

                        func canFetchPlaylist(_ url: URL) async -> Bool {
                            do {
                                let (data, response) = try await URLSession.shared.data(from: url)
                                let code = (response as? HTTPURLResponse)?.statusCode ?? 0
                                guard code == 200 else { return false }
                                if url.path.hasSuffix(".m3u8") {
                                    return true
                                }
                                return String(data: data, encoding: .utf8)?.contains("#EXTM3U") == true
                            } catch {
                                return false
                            }
                        }

                        var warmed = false
                        for _ in 0..<16 {
                            if await isProxyReady(readyURL) {
                                if await canFetchPlaylist(playURL) {
                                    warmed = true
                                    break
                                }
                                if playURL.absoluteString != urlToPlay.absoluteString,
                                   await canFetchPlaylist(urlToPlay) {
                                    // Keep playback alive even if subtitle-injected master is briefly unavailable.
                                    playURL = urlToPlay
                                    warmed = true
                                    break
                                }
                            }
                            try? await Task.sleep(nanoseconds: 250_000_000)
                        }

                        if !warmed {
                            Logger.shared.log("Proxy warm-up still not ready for \(playURL.absoluteString); starting anyway and allowing fallback chain", type: "Stream")
                        }
                    }

                    let asset: AVURLAsset
                    if playURL.isFileURL {
                        asset = AVURLAsset(url: playURL)
                    } else if playURL.absoluteString == streamURL.absoluteString {
                        asset = AVURLAsset(url: playURL, options: ["AVURLAssetHTTPHeaderFieldsKey": finalHeaders])
                    } else {
                        asset = AVURLAsset(url: playURL)
                    }
                    let item = AVPlayerItem(asset: asset)
                    if isMovie {
                        playerVC.mediaInfo = .movie(id: tmdbId, title: mediaTitle)
                    } else if let episode = selectedEpisode {
                        playerVC.mediaInfo = .episode(showId: tmdbId, showTitle: mediaTitle, seasonNumber: episode.seasonNumber, episodeNumber: episode.episodeNumber)
                    }
                    playerVC.modalPresentationStyle = .fullScreen
                    if let g = try? await item.asset.loadMediaSelectionGroup(for: .legible) {
                        item.select(nil, in: g)
                    }
                    playerVC.player = AVPlayer(playerItem: item)
                    if let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
                       let rootVC = windowScene.windows.first?.rootViewController {
                        rootVC.presentPlayerAvoidingSheet(playerVC, animated: true) {
                            playerVC.player?.play()
                        }
                    } else {
                        Logger.shared.log("Failed to find root view controller to present player", type: "Error")
                        playerVC.player?.play()
                    }
                }
            }
        }
    }
    
    private func safeConvertToHeaders(_ value: Any?) -> [String: String]? {
        guard let value = value else { return nil }
        
        if value is NSNull { return nil }
        
        if let headers = value as? [String: String] {
            return headers
        }
        
        if let headersAny = value as? [String: Any] {
            var safeHeaders: [String: String] = [:]
            for (key, val) in headersAny {
                if let stringValue = val as? String {
                    safeHeaders[key] = stringValue
                } else if let numberValue = val as? NSNumber {
                    safeHeaders[key] = numberValue.stringValue
                } else if !(val is NSNull) {
                    safeHeaders[key] = String(describing: val)
                }
            }
            return safeHeaders.isEmpty ? nil : safeHeaders
        }
        
        if let headersAny = value as? [AnyHashable: Any] {
            var safeHeaders: [String: String] = [:]
            for (key, val) in headersAny {
                let stringKey = String(describing: key)
                if let stringValue = val as? String {
                    safeHeaders[stringKey] = stringValue
                } else if let numberValue = val as? NSNumber {
                    safeHeaders[stringKey] = numberValue.stringValue
                } else if !(val is NSNull) {
                    safeHeaders[stringKey] = String(describing: val)
                }
            }
            return safeHeaders.isEmpty ? nil : safeHeaders
        }
        
        Logger.shared.log("Unable to safely convert headers of type: \(type(of: value))", type: "Warning")
        return nil
    }
}

struct CompactMediaResultRow: View {
    let result: SearchItem
    let originalTitle: String
    let alternativeTitle: String?
    let episode: TMDBEpisode?
    let onTap: () -> Void
    let highQualityThreshold: Double
    
    private var similarityScore: Double {
        let primarySimilarity = calculateSimilarity(original: originalTitle, result: result.title)
        let alternativeSimilarity = alternativeTitle.map { calculateSimilarity(original: $0, result: result.title) } ?? 0.0
        return max(primarySimilarity, alternativeSimilarity)
    }
    
    private var scoreColor: Color {
        if similarityScore >= highQualityThreshold { return .green }
        else if similarityScore >= 0.75 { return .orange }
        else { return .red }
    }
    
    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 12) {
                NoirImage(url: URL(string: result.imageUrl)) {
                        Rectangle()
                            .fill(Color.gray.opacity(0.3))
                            .overlay(
                                Image(systemName: "photo")
                                    .font(.caption)
                                    .foregroundColor(.gray)
                            )
                    }
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: 40, height: 55)
                    .cornerRadius(6)
                
                VStack(alignment: .leading, spacing: 2) {
                    Text(result.title)
                        .font(.caption)
                        .fontWeight(.medium)
                        .lineLimit(1)
                        .multilineTextAlignment(.leading)
                    
                    HStack {
                        Text("\(Int(similarityScore * 100))%")
                            .font(.caption2)
                            .fontWeight(.medium)
                            .foregroundColor(scoreColor)
                        
                        Spacer()
                        
                        Image(systemName: "play.circle")
                            .font(.caption)
                    }
                }
                
                Spacer()
            }
            .padding(.vertical, 4)
        }
        .buttonStyle(PlainButtonStyle())
    }
    
    private func calculateSimilarity(original: String, result: String) -> Double {
        return AlgorithmManager.shared.calculateSimilarity(original: original, result: result)
    }
}

struct EnhancedMediaResultRow: View {
    let result: SearchItem
    let originalTitle: String
    let alternativeTitle: String?
    let episode: TMDBEpisode?
    let onTap: () -> Void
    let highQualityThreshold: Double
    
    private var similarityScore: Double {
        let primarySimilarity = calculateSimilarity(original: originalTitle, result: result.title)
        let alternativeSimilarity = alternativeTitle.map { calculateSimilarity(original: $0, result: result.title) } ?? 0.0
        return max(primarySimilarity, alternativeSimilarity)
    }
    
    private var scoreColor: Color {
        if similarityScore >= highQualityThreshold { return .green }
        else if similarityScore >= 0.75 { return .orange }
        else { return .red }
    }
    
    private var matchQuality: String {
        if similarityScore >= highQualityThreshold { return "Excellent" }
        else if similarityScore >= 0.75 { return "Good" }
        else { return "Fair" }
    }
    
    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 12) {
                NoirImage(url: URL(string: result.imageUrl)) {
                        RoundedRectangle(cornerRadius: 8)
                            .fill(Color.gray.opacity(0.2))
                            .overlay(
                                Image(systemName: "photo")
                                    .font(.title2)
                                    .foregroundColor(.gray)
                            )
                    }
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: 70, height: 95)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                
                VStack(alignment: .leading, spacing: 8) {
                    Text(result.title)
                        .font(.subheadline)
                        .fontWeight(.semibold)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                        .foregroundColor(.primary)
                    
                    if let episode = episode {
                        HStack {
                            Image(systemName: "tv")
                                .font(.caption)
                                .foregroundColor(.secondary)
                            
                            Text("Episode \(episode.episodeNumber)")
                                .font(.caption)
                                .foregroundColor(.secondary)
                            
                            if !episode.name.isEmpty {
                                Text("• \(episode.name)")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                    .lineLimit(1)
                            }
                        }
                    }
                    
                    HStack {
                        HStack(spacing: 4) {
                            Circle()
                                .fill(scoreColor)
                                .frame(width: 6, height: 6)
                            
                            Text(matchQuality)
                                .font(.caption2)
                                .fontWeight(.medium)
                                .foregroundColor(scoreColor)
                        }
                        
                        Text("• \(Int(similarityScore * 100))% match")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                        
                        Spacer()
                        
                        Image(systemName: "play.circle.fill")
                            .font(.title2)
                            .tint(Color.accentColor)
                    }
                }
                
                Spacer()
            }
            .padding(.vertical, 8)
        }
        .buttonStyle(PlainButtonStyle())
    }
    
    private func calculateSimilarity(original: String, result: String) -> Double {
        return AlgorithmManager.shared.calculateSimilarity(original: original, result: result)
    }
}
