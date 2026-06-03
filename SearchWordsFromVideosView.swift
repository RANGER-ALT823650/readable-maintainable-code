import SwiftUI
import PhotosUI
import NaturalLanguage
import UIKit

/*
 这个视图有三条必须保持一致的状态链：
 1. 以 `selectionItems` 为唯一可信源来追踪 PhotosPicker 的选中项。
 2. `photos` 是根据 `selectionItems` 构建的本地预览缓存。
 3. OCR 与词典派生的输出 (`rawText`, `wordCounts`, `wordMetaByWord`) 是一次性派生状态。

 变更选中、删除或重置逻辑时，需要同步更新这三条链以避免不同步。
 目前的设计故意在用户变更截图后尽快清空 OCR 结果，宁可牺牲历史数据也不让展示结果失真。
 */
struct PickedPhoto: Identifiable, Equatable {
    let id = UUID()
    // 保留原始 picker item，方便后续与 PhotosPicker 的选择做差集。
    // 没有这个引用，删除或重新排序预览就很难安全、唯一地识别目标。
    let item: PhotosPickerItem
    let image: UIImage

    static func == (lhs: PickedPhoto, rhs: PickedPhoto) -> Bool {
        lhs.id == rhs.id
    }
}

struct SearchWordsFromVideosView: View {
    @Environment(\.openURL) private var openURL
    @ObservedObject private var photoPermissionStore = SharedPhotoLibraryPermissionStore.shared
    @StateObject private var profileStore = UserProfileSettingsStore()
    
    // `selectionItems` 是唯一权威的照片选中状态。
    // 所有预览与 OCR 状态都从这里重建，避免 UI 状态分裂。
    @State private var selectionItems: [PhotosPickerItem] = []
    @State private var showPhotoPicker = false
    @State private var showPhotoPermissionAlert = false
    @State private var photoPermissionAlertMessage = SharedPhotoLibraryPermissionPolicy.deniedOrRestrictedMessage
    
    // 当前选中截图的 UIImage 缓存。
    // 仅用于本地渲染性能，应和 `selectionItems` 同步销毁。
    @State private var photos: [PickedPhoto] = []
    
    
    // 识别成功后自动折叠截图区域，让抽词成为焦点。
    // 用户仍可手动展开，后续如果修改体验也应保留这个手动路径。
    @State private var isPickedPhotosExpanded: Bool = true
    
    @State private var loadTask: Task<Void, Never>?
    @State private var processingTask: Task<Void, Never>?
    
    @State private var isProcessing = false
    @State private var rawText = ""
    
    
    @State private var wordCounts: [WordCountItem] = []
    typealias WordCountItem = (word: String, count: Int)//起别名（简称
    
    private enum FilterType: String, CaseIterable, Identifiable {
        case frequency = "frequency"
        case level = "level"
        var id: String { rawValue }
    }
    
    private enum LevelRank: Int, CaseIterable, Identifiable {
        case gaokao = 0
        case cet4 = 1
        case cet6 = 2
        case kaoyan = 3
        case ielts = 4
        case toefl = 5
        case gre = 6
        case gmat = 7
        
        var id: Int { rawValue }
        
        var title: String {
            switch self {
            case .gaokao: return "高考"
            case .cet4: return "四级"
            case .cet6: return "六级"
            case .kaoyan: return "考研"
            case .ielts: return "雅思"
            case .toefl: return "托福"
            case .gre: return "GRE"
            case .gmat: return "GMAT"
            }
        }
    }
    
    private struct WordMeta {
        let frequency: Int?
        let levelRank: LevelRank?
    }
    
    @State private var wordMetaByWord: [String: WordMeta] = [:]
    @State private var isWordMetaReady: Bool = false
    @State private var filterType: FilterType = .frequency
    @State private var frequencyMin: Int = 0
    @State private var frequencyMax: Int = 7
    @State private var levelMin: LevelRank = .gaokao
    @State private var levelMax: LevelRank = .gmat
    
    // MARK: - Preview
    @State private var previewImage: UIImage? = nil
    @State private var isPreviewPresented: Bool = false
    @State private var isClosingPreview = false

    @State private var wordGroups: [UserDataService.WordGroupSummary] = []
    @State private var pendingPhotoForGroup: PickedPhoto?
    @State private var showNoGroupAlert = false
    @State private var showGroupPickerSheet = false
    @State private var ocrTextCache: [UUID: String] = [:]
    
    // 预览浮层依赖 matched-geometry 动画，`activePhotoID` 需在关闭完成前一直有效，否则缩略图无法平滑回到格子中。
    @Namespace private var previewNamespace
    @State private var activePhotoID: UUID? = nil
    
    // MARK: - System Dictionary Sheet
    @State private var isDictionarySheetPresented = false
    @State private var selectedDictionaryTerm: String = ""
    @State private var wordNavigationPath: [String] = []
    @State private var showUserSettingsSheet = false
    @State private var clearButtonBounceTrigger = 0
    // TEMP: iCloud disabled
    // @State private var showSyncConsentAlert = false
    
    
    private func presentPreview(_ photo: PickedPhoto) {
        previewImage = photo.image
        activePhotoID = photo.id
        Haptics.medium()
        withAnimation(.spring(response: 0.25, dampingFraction: 0.9)) {
            isPreviewPresented = true
        }
    }
    
    private func dismissPreview() {
        let closingID = activePhotoID
        isClosingPreview = true
        
        withAnimation(.spring(response: 0.28, dampingFraction: 0.9)) {
            isPreviewPresented = false
            // 在动画结束前保留 `activePhotoID`，以确保 matched geometry 始终有合理的源目标。
        } completion: {
            // 只有当前仍在关闭相同截图时才清理预览。
            // 防止用户快速点开另一个预览时被提前清除状态打断动画。
            if self.activePhotoID == closingID {
                self.activePhotoID = nil
                self.previewImage = nil
            }
            self.isClosingPreview = false
        }
    }
    
    
    private let ocr = OCRService()
    private let gridColumns: [GridItem] = Array(repeating: GridItem(.flexible(), spacing: 10), count: 3)
    
    private enum LookupMode: String, CaseIterable, Identifiable {
        case fast = "Fast"
        case deep = "Deep"
        var id: String { rawValue }
    }
    @State private var lookupMode: LookupMode = .fast
    let dictionaryService: DictionaryService
    
    private var displayedWordCounts: [WordCountItem] {
        wordCounts.filter { item in
            guard let meta = wordMetaByWord[item.word] else { return false }
            switch filterType {
            case .frequency:
                guard let f = meta.frequency else { return false }
                return f >= frequencyMin && f <= frequencyMax
            case .level:
                guard let l = meta.levelRank else { return false }
                return l.rawValue >= levelMin.rawValue && l.rawValue <= levelMax.rawValue
            }
        }
    }
    
    
    var body: some View {
        NavigationStack(path: $wordNavigationPath) {
            mainContent
                .onAppear {
                    photoPermissionStore.refresh()
                }
                .onChange(of: selectionItems) { _, newItems in
                    if !newItems.isEmpty {
                        withAnimation(.spring(response: 0.25, dampingFraction: 0.9)) {
                            isPickedPhotosExpanded = true
                        }
                    }
                    syncPreviewWithPickerSelection(newItems)
                }
                .onChange(of: frequencyMin) { _, newValue in
                    if newValue > frequencyMax {
                        frequencyMax = newValue
                    }
                }
                .onChange(of: frequencyMax) { _, newValue in
                    if newValue < frequencyMin {
                        frequencyMin = newValue
                    }
                }
                .onChange(of: levelMin) { _, newValue in
                    if newValue.rawValue > levelMax.rawValue {
                        levelMax = newValue
                    }
                }
                .onChange(of: levelMax) { _, newValue in
                    if newValue.rawValue < levelMin.rawValue {
                        levelMin = newValue
                    }
                }
                .animation(.spring(response: 0.25, dampingFraction: 0.9), value: isPreviewPresented)
                .navigationBarTitleDisplayMode(.inline)
                .navigationDestination(for: String.self) { word in
                    DictionaryEntryView(service: dictionaryService, word: word)
                }
        }
        .sheet(isPresented: $isDictionarySheetPresented) {
            OfficialDictionaryEntryView(term: selectedDictionaryTerm)
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $showUserSettingsSheet) {
            UserSettingsSheetView(profileStore: profileStore)
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $showGroupPickerSheet, onDismiss: {
            pendingPhotoForGroup = nil
        }) {
            groupPickerSheet
        }
        .alert("暂无可用组", isPresented: $showNoGroupAlert) {
            Button("知道了", role: .cancel) {}
        } message: {
            Text("请先在“集”里创建至少一个组。")
        }
    }

    private var mainContent: some View {
        ZStack(alignment: .topTrailing) {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    topHeaderSection
                    pickerAndActionsSection
                    modePickerSection
                    selectedPhotosSection
                    filterControlsSection
                    wordsSection
                    ocrRawTextSection
                }
            }
            previewOverlay
        }
    }

    private var topHeaderSection: some View {
        HStack {
            Text(GreetingTextBuilder.makeGreeting(nickname: profileStore.nickname))
                .font(.title)
                .bold()
                .padding(.leading)
                .padding(.top)
            Spacer()
            Button {
                showUserSettingsSheet = true
            } label: {
                UserAvatarCircleView(image: profileStore.avatarImage, size: 40)
                    .overlay {
                        Circle()
                            .strokeBorder(.primary.opacity(0.16), lineWidth: 1)
                    }
                    .frame(width: 40, height: 40)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("用户设置")
            .padding(.top, 8)
            .padding(.trailing, 16)
        }
    }

    private var pickerAndActionsSection: some View {
        HStack(spacing: 10) {
            screenshotPickerEntryButton
            actionButtonsSection
        }
        .padding(.horizontal)
    }

    private var screenshotPickerEntryButton: some View {
        Button {
            requestPhotoLibraryAccessAndPresentPicker()
        } label: {
            VStack {
                Image(systemName: "photo.badge.plus")
                    .resizable()
                    .scaledToFit()
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(.gray,.blue)
                Text("选择截图")
            }
            .padding()
            .frame(maxWidth: .infinity)
            .frame(maxHeight: 140)
            .background(.thinMaterial)
            .cornerRadius(12)
        }
        .buttonStyle(.plain)
        .photosPicker(isPresented: $showPhotoPicker, selection: $selectionItems, matching: .images)
        .alert("需要相册访问权限", isPresented: $showPhotoPermissionAlert) {
            Button("取消", role: .cancel) {}
            Button("去设置") {
                guard let settingsURL = URL(string: UIApplication.openSettingsURLString) else { return }
                openURL(settingsURL)
            }
        } message: {
            Text(photoPermissionAlertMessage)
        }
    }

    private var actionButtonsSection: some View {
        VStack(spacing: 10) {
            Button {
                Haptics.soft()
                startProcessing()
            } label: {
                HStack(spacing: 10) {
                    if isProcessing {
                        ProgressView()
                    }
                    Text(isProcessing ? "识别中..." : "开始识别并抽词")
                }
                .frame(maxWidth: .infinity)
                .frame(height: 55)
                .padding(.vertical, 10)
                .background(.blue.opacity(0.15))
                .cornerRadius(12)
            }
            .disabled(photos.isEmpty || isProcessing)

            Button(role: .destructive) {
                clearButtonBounceTrigger += 1
                Haptics.heavy()
                cancelAllTasks()
                selectionItems.removeAll()
                withAnimation(.snappy) {
                    photos.removeAll()
                }
                rawText = ""
                wordCounts = []
                wordMetaByWord = [:]
                isWordMetaReady = false
                isPickedPhotosExpanded = false
            } label: {
                Image(systemName: "trash")
                    .frame(maxWidth: .infinity)
                    .frame(height: 55)
                    .background(.red.opacity(0.12))
                    .cornerRadius(12)
                    .symbolEffect(.bounce, value: clearButtonBounceTrigger)
            }
            .disabled(selectionItems.isEmpty && rawText.isEmpty && wordCounts.isEmpty)
        }
    }

    private var modePickerSection: some View {
        Picker("Mode", selection: $lookupMode) {
            ForEach(LookupMode.allCases) { mode in
                Text(mode.rawValue).tag(mode)
            }
        }
        .pickerStyle(.segmented)
        .padding(.horizontal)
        .onChange(of: lookupMode) { _, _ in
            Haptics.soft()
        }
    }

    @ViewBuilder
    private var selectedPhotosSection: some View {
        if !photos.isEmpty {
            DisclosureGroup(isExpanded: $isPickedPhotosExpanded) {
                LazyVGrid(columns: gridColumns, spacing: 10) {
                    ForEach(photos) { photo in
                        selectedPhotoCell(photo)
                    }
                }
                .padding(.horizontal)
            } label: {
                HStack {
                    Text("已选截图（\(photos.count)）")
                        .font(.headline)
                    Spacer()
                }
                .padding()
                .contentShape(Rectangle())
            }
        }
    }

    private func selectedPhotoCell(_ photo: PickedPhoto) -> some View {
        ZStack(alignment: .topTrailing) {
            ZStack {
                Thumbnail43(image: photo.image)
                    .matchedGeometryEffect(id: photo.id, in: previewNamespace)
                    .opacity(activePhotoID == photo.id ? 0 : 1)
                Thumbnail43(image: photo.image)
                    // 动画关闭时保留额外一份展示，避免格子瞬间留白再跳回原始状态。
                    .opacity((isClosingPreview && activePhotoID == photo.id) ? 1 : 0)
                    .allowsHitTesting(false)
            }
            .onTapGesture {
                presentPreview(photo)
            }
            .contextMenu {
                Button("添加到组", systemImage: "folder.badge.plus") {
                    prepareAddPhotoToGroup(photo)
                }
            }

            Button {
                deletePhoto(photo)
                Haptics.heavy()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(.white)
            }
            .contentShape(Circle())
            .padding(6)
        }
    }

    @ViewBuilder
    private var filterControlsSection: some View {
        if isWordMetaReady && !wordCounts.isEmpty {
            HStack(spacing: 10) {
                Picker("筛选方式", selection: $filterType) {
                    Text("frequency").tag(FilterType.frequency)
                    Text("level").tag(FilterType.level)
                }
                .pickerStyle(.menu)
                .padding(.horizontal, 7)
                .padding(.vertical, 7)
                .frame(minWidth: 100)
                .background(.thinMaterial)
                .clipShape(Capsule())

                Spacer()

                filterRangeControls
                    .background(.thinMaterial)
                    .clipShape(Capsule())
            }
            .padding()
        }
    }

    @ViewBuilder
    private var filterRangeControls: some View {
        if filterType == .frequency {
            Picker("最小值", selection: $frequencyMin) {
                ForEach(Array(0...7), id: \.self) { value in
                    Text("\(value)").tag(value)
                }
            }
            .pickerStyle(.menu)
            .frame(maxWidth: 55)
            .padding(.horizontal, 6)
            .padding(.vertical, 6)

            Picker("最大值", selection: $frequencyMax) {
                ForEach(Array(0...7), id: \.self) { value in
                    Text("\(value)").tag(value)
                }
            }
            .pickerStyle(.menu)
            .frame(minWidth: 55)
            .padding(.horizontal, 6)
            .padding(.vertical, 6)
        } else {
            Picker("最小值", selection: $levelMin) {
                ForEach(LevelRank.allCases) { level in
                    Text(level.title).tag(level)
                }
            }
            .pickerStyle(.menu)
            .frame(minWidth: 55)
            .padding(.horizontal, 6)
            .padding(.vertical, 6)
        }
    }

    @ViewBuilder
    private var wordsSection: some View {
        if !wordCounts.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text("单词")
                    .font(.headline)
                    .padding(.horizontal)
                VStack(spacing: 10) {
                    let rows = displayedWordCounts.chunked(into: 3)
                    ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                        WeightedRow(spacing: 10, minItemWidth: 72, fixedHeight: 44) {
                            ForEach(Array(row.enumerated()), id: \.offset) { _, item in
                                wordCell(item.word)
                                    .layoutValue(key: WeightKey.self, value: CGFloat(max(item.word.count, 1)))
                            }
                        }
                    }
                }
                .padding(.horizontal, 10)
            }
        }
    }

    @ViewBuilder
    private var ocrRawTextSection: some View {
        if !rawText.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text("OCR 原文")
                    .font(.headline)
                    .padding(.horizontal)

                SelectableText(
                    text: rawText.isEmpty ? "（空）" : rawText,
                    showsMarkMenuActions: false
                )
                .padding(.vertical, 12)
                .padding(.horizontal, 12)
                .background(.thinMaterial)
                .cornerRadius(12)
                .padding(.horizontal)
            }
        }
    }

    @ViewBuilder
    private var previewOverlay: some View {
        if let image = previewImage, isPreviewPresented, let id = activePhotoID {
            ZStack {
                Color.black.opacity(0.35)
                    .ignoresSafeArea()
                    .onTapGesture {
                        dismissPreview()
                    }

                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                    .shadow(radius: 30)
                    .padding(10)
                    .matchedGeometryEffect(id: id, in: previewNamespace)
                    .onTapGesture {
                        dismissPreview()
                    }
            }
            .zIndex(999)
            .transition(.opacity)
        }
    }
    
    @ViewBuilder
    private func wordCell(_ word: String) -> some View {
        Text(word)
            .fontWeight(.semibold)
            // 为了保持行高一致：加权布局假定每个词卡都占据固定高度的一行。
            .lineLimit(1)
            .truncationMode(.tail)
            .minimumScaleFactor(0.85)
            .textSelection(.enabled)
            .simultaneousGesture(
                LongPressGesture(minimumDuration: 0.25).onEnded { _ in
                    Haptics.medium()
                }
            )
            .onTapGesture {
                openWordForCurrentMode(word)
            }
            // 自定义布局根据 `WeightKey` 重新分配剩余宽度，保持该 View 先 flex 再填充。
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 15)
            .padding(.horizontal, 12)
            .background(.thinMaterial)
            .cornerRadius(12)
            .contentShape(Rectangle())
    }

    private func openWordForCurrentMode(_ word: String) {
        switch lookupMode {
        case .fast:
            selectedDictionaryTerm = word
            isDictionarySheetPresented = true
        case .deep:
            wordNavigationPath.append(word)
        }
        Haptics.light()
    }

    private var groupPickerSheet: some View {
        NavigationStack {
            List(wordGroups) { group in
                Button {
                    addPendingPhoto(to: group.id)
                } label: {
                    HStack {
                        Text(group.breadcrumbName)
                        Spacer()
                        Text("\(group.wordCount)")
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle("选择组")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") {
                        pendingPhotoForGroup = nil
                        showGroupPickerSheet = false
                    }
                }
            }
        }
    }

    private func prepareAddPhotoToGroup(_ photo: PickedPhoto) {
        Task { @MainActor in
            let groups = await UserDataService.shared.fetchSelectableWordGroups()
            wordGroups = groups

            guard !groups.isEmpty else {
                showNoGroupAlert = true
                return
            }

            if groups.count == 1, let onlyGroup = groups.first {
                await addPhotoAndOCRText(photo, to: onlyGroup.id)
                return
            }

            pendingPhotoForGroup = photo
            showGroupPickerSheet = true
        }
    }

    private func addPendingPhoto(to groupID: Int64) {
        guard let photo = pendingPhotoForGroup else { return }
        pendingPhotoForGroup = nil
        showGroupPickerSheet = false

        Task { @MainActor in
            await addPhotoAndOCRText(photo, to: groupID)
        }
    }

    @MainActor
    private func addPhotoAndOCRText(_ photo: PickedPhoto, to groupID: Int64) async {
        // 分别持久化图片与 OCR 文本，方便其他界面按需只取其中之一。
        if let imageData = photo.image.jpegData(compressionQuality: 0.82) {
            let input = UserDataService.WordGroupImageInput(imageData: imageData, assetIdentifier: nil)
            await UserDataService.shared.appendWordGroupImages(groupID: groupID, images: [input])
        }

        // OCR 文本用预览 UUID 缓存，避免重复添加同一张图时重复识别。
        let cachedOCRText = ocrTextCache[photo.id]
        let ocrText: String
        if let cachedOCRText {
            ocrText = cachedOCRText
        } else {
            ocrText = await ocr.recognizeEnglishText(from: photo.image)
            ocrTextCache[photo.id] = ocrText
        }

        await UserDataService.shared.appendWordGroupOCRText(groupID: groupID, text: ocrText)
        Haptics.soft()
    }

    private func requestPhotoLibraryAccessAndPresentPicker() {
        Task {
            let status = await photoPermissionStore.requestReadWriteStatusIfNeeded()
            let decision = SharedPhotoLibraryPermissionPolicy.decision(for: status)
            await MainActor.run {
                if decision.canPresentPicker {
                    showPhotoPicker = true
                } else if let alertMessage = decision.alertMessage {
                    photoPermissionAlertMessage = alertMessage
                    showPhotoPermissionAlert = true
                }
            }
        }
    }


    private func syncPreviewWithPickerSelection(_ newItems: [PhotosPickerItem]) {
        // 取消所有加载任务：它们正处理旧 selection，必须先停掉才能安全 diff。
        loadTask?.cancel()

        withAnimation(.snappy) {
            photos.removeAll { photo in
                !newItems.contains(photo.item)
            }
        }

        // 只为新加的 picker item 重新加载图片，已有预览继续复用。
        let toLoad = newItems.filter { item in
            !photos.contains(where: { $0.item == item })
        }
        
        // picker 一旦变动就清空 OCR 输出。
        // 虽然保守，但能确保抽出的词与当前展示的截图一一对应。
        rawText = ""
        wordCounts = []
        wordMetaByWord = [:]
        isWordMetaReady = false

        loadTask = Task {
            for item in toLoad {
                if Task.isCancelled { return }

                if let data = try? await item.loadTransferable(type: Data.self),
                   let img = UIImage(data: data) {
                    if Task.isCancelled { return }

                    await MainActor.run {
                        // 回到主线程重新确认状态：图片加载过程中用户可能已经换了选中的截图。
                        guard selectionItems.contains(item) else { return }
                        guard !photos.contains(where: { $0.item == item }) else { return }

                        photos.append(PickedPhoto(item: item, image: img))
                    }
                }
            }
        }
    }

    private func startProcessing() {
        guard !isProcessing else { return }
        processingTask?.cancel()
        processingTask = Task { await runOCRAndExtract() }
    }

    private func deletePhoto(_ photo: PickedPhoto) {
        cancelAllTasks()
        selectionItems.removeAll { $0 == photo.item }
        rawText = ""
        wordCounts = []
        wordMetaByWord = [:]
        isWordMetaReady = false
    }

    private func cancelAllTasks() {
        loadTask?.cancel()
        processingTask?.cancel()
    }

    private func runOCRAndExtract() async {
        // 每次开始识别前都先清空派生结果，避免界面同时显示新旧信息。
        await MainActor.run {
            isProcessing = true
            rawText = ""
            wordCounts = []
            wordMetaByWord = [:]
            isWordMetaReady = false
        }

        defer {
            Task { @MainActor in isProcessing = false }
        }

        var allText = ""
        for p in photos {
            if Task.isCancelled { return }
            let t = await ocr.recognizeEnglishText(from: p.image)
            if Task.isCancelled { return }
            // 保留截图顺序拼接 OCR 文本，后续的词序依赖出现顺序，比随意乱序更符合直觉。
            if !t.isEmpty { allText += t + "\n" }
        }

        let finalText = allText.trimmingCharacters(in: .whitespacesAndNewlines)
        let counts = WordExtractor.extractWords(from: finalText)
        let ordered = buildOrderedUniqueList(from: finalText, counts: counts)
        let uniqueWords = Array(Set(ordered.map { $0.word }))

        await MainActor.run {
            rawText = finalText
            wordCounts = ordered
            wordMetaByWord = [:]
            isWordMetaReady = false

            // 只有在成功得到词表后才折叠已选截图；若 OCR 为空则保持可视，提醒用户需要更换素材。
            if !ordered.isEmpty {
                withAnimation(.spring(response: 0.25, dampingFraction: 0.9)) {
                    isPickedPhotosExpanded = false
                }
            }
        }
        
        let rawMeta: [String: WordMetaRaw]
        do {
            rawMeta = try dictionaryService.fetchWordMeta(words: uniqueWords)
        } catch {
            // 词典元数据失败不应否定 OCR 成功。我们回退到无元数据模式，确保用户依然能看到抽词结果。
            rawMeta = [:]
        }
        
        if Task.isCancelled { return }
        
        var parsedMeta: [String: WordMeta] = [:]
        parsedMeta.reserveCapacity(uniqueWords.count)
        for word in uniqueWords {
            let raw = rawMeta[word]
            let frequency = raw?.frequency.map { Int($0) }
            let levelRank = raw?.level.flatMap(levelRankFromRaw)
            parsedMeta[word] = WordMeta(frequency: frequency, levelRank: levelRank)
        }
        
        await MainActor.run {
            wordMetaByWord = parsedMeta
            isWordMetaReady = true
        }
    }
}

private extension SearchWordsFromVideosView {
    
    private func levelRankFromRaw(_ raw: String) -> LevelRank? {
        // 原始数据不够标准化：某些等级是中文，GRE/GMAT 又是英文缩写。
        // 这里匹配所有候选并取最高级别，避免像 “四级/六级” 这样的组合被错误地降级。
        let normalized = raw.replacingOccurrences(of: " ", with: "")
        let upper = normalized.uppercased()
        let matched = LevelRank.allCases.filter { level in
            switch level {
            case .gre, .gmat:
                return upper.contains(level.title)
            default:
                return normalized.contains(level.title)
            }
        }
        return matched.max(by: { $0.rawValue < $1.rawValue })
    }

    func buildOrderedUniqueList(from text: String, counts: [String: Int]) -> [(word: String, count: Int)] {
        // 这个 helper 故意保留 OCR 文本中首次出现的顺序，而非按频次排序。
        // 这样输出列表更容易对应用户刚刚扫描的截图。
        let tokenizer = NLTokenizer(unit: .word)
        tokenizer.string = text

        var seen = Set<String>()
        var result: [(word: String, count: Int)] = []

        tokenizer.enumerateTokens(in: text.startIndex..<text.endIndex) { range, _ in
            let rawToken = String(text[range])

            var w = WordNormalization.normalizeToken(rawToken)
            if w.count < 2 { return true }

            if let lemma = WordNormalization.lemmatizeEnglish(w) {
                w = lemma
            }

            guard seen.insert(w).inserted else { return true }

            let c = counts[w] ?? 1
            result.append((word: w, count: c))

            return true
        }

        return result
    }
}

private struct Thumbnail43: View {
    let image: UIImage

    var body: some View {
        Image(uiImage: image)
            .resizable()
            .scaledToFit()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(.secondarySystemBackground))
            .aspectRatio(4 / 2.7, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

private extension Array {
    func chunked(into size: Int) -> [[Element]] {
        guard size > 0 else { return [] }
        var result: [[Element]] = []
        // 提前知道行数后可 reserve 容量，避免布局重建时频繁 reallocate。
        result.reserveCapacity((count + size - 1) / size)
        var i = 0
        while i < count {
            let end = Swift.min(i + size, count)
            result.append(Array(self[i..<end]))
            i = end
        }
        return result
    }
}

// MARK: - Weighted Row Layout (iOS 16+)

private struct WeightKey: LayoutValueKey {
    static let defaultValue: CGFloat = 1
}

private struct WeightedRow<Content: View>: View {
    let spacing: CGFloat
    let minItemWidth: CGFloat
    let fixedHeight: CGFloat
    @ViewBuilder var content: Content

    init(spacing: CGFloat, minItemWidth: CGFloat, fixedHeight: CGFloat, @ViewBuilder content: () -> Content) {
        self.spacing = spacing
        self.minItemWidth = minItemWidth
        self.fixedHeight = fixedHeight
        self.content = content()
    }

    var body: some View {
        _WeightedRowLayout(spacing: spacing, minItemWidth: minItemWidth, fixedHeight: fixedHeight) {
            content
        }
    }
}

private struct _WeightedRowLayout: Layout {
    let spacing: CGFloat
    let minItemWidth: CGFloat
    let fixedHeight: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        // 固定行高保证视觉一致；宽度交给父容器处理。
        let width = proposal.width ?? 0
        return CGSize(width: width, height: fixedHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard !subviews.isEmpty else { return }

        let count = subviews.count
        let totalSpacing = spacing * CGFloat(max(count - 1, 0))
        let available = max(bounds.width - totalSpacing, 0)

        // 所有词卡先分配最小宽度，然后再分发剩余空间。
        let minTotal = minItemWidth * CGFloat(count)
        let remaining = max(available - minTotal, 0)

        // 剩余宽度按照词长度分配，较长词卡因此不易被截断。
        // 以后如果换权重策略，记得保留最小宽度的底线，否则短词会让行高失衡。
        let weights = subviews.map { $0[WeightKey.self] }
        let weightSum = max(weights.reduce(0, +), 1)

        var x = bounds.minX
        for i in 0..<count {
            let extra = remaining * (weights[i] / weightSum)
            let w = minItemWidth + extra

            subviews[i].place(
                at: CGPoint(x: x, y: bounds.minY),
                proposal: ProposedViewSize(width: w, height: fixedHeight)
            )
            x += w + spacing
        }
    }
}
