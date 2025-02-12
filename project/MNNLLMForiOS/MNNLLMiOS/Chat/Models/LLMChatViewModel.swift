//
//  LLMChatViewModel.swift
//  MNNLLMiOS
//  Created by 游薪渝(揽清) on 2025/1/8.
//

import Combine
import SwiftUI
import AVFoundation

import ExyteChat
import ExyteMediaPicker


final class LLMChatViewModel: ObservableObject {
    
    private var llm: LLMInferenceEngineWrapper?
//    private var diffusion: DiffusionSession?
    private let llmState = LLMState()
    
    @Published var messages: [Message] = []
    @Published var isModelLoaded = false
    @Published var isProcessing: Bool = false
    
    var chatInputUnavilable: Bool {
        if isModelLoaded == false || isProcessing == true {
            return true
        }
        return false
    }
    
    var chatStatus: String {
        if isModelLoaded {
            if isProcessing {
                "Processing..."
            } else {
                "Ready"
            }
        } else {
            "Model Loading..."
        }
    }
    
    var chatCover: URL? {
        interactor.otherSenders.count == 1 ? interactor.otherSenders.first!.avatar : nil
    }

    private let interactor: LLMChatInteractor
    private var subscriptions = Set<AnyCancellable>()

    var modelInfo: ModelInfo
    var history: ChatHistory?
    private var historyId: String
    
    init(modelInfo: ModelInfo, history: ChatHistory? = nil) {
        self.modelInfo = modelInfo
        self.history = history
        self.historyId = history?.id ?? UUID().uuidString
        let messages = self.history?.messages
        self.interactor = LLMChatInteractor(modelInfo: modelInfo, historyMessages: messages)
    }
    
    deinit {
        print("yxy:: LLMChat View Model deinit")
    }
    
    func setupLLM(modelPath: String) {
        Task { @MainActor in
            self.send(draft: DraftMessage(
                text: NSLocalizedString("ModelLoadingText", comment: ""),
                thinkText: "",
                medias: [],
                recording: nil,
                replyMessage: nil,
                createdAt: Date()
            ), userType: .system)
        }

        /* TODO: support diffusion
        diffusion = DiffusionSession(modelPath: modelPath, completion: { [weak self] success in
            Task { @MainActor in
                print("Diffusion Model \(success)")
                self?.isModelLoaded = success
            }
        })
         */
        llm = LLMInferenceEngineWrapper(modelPath: modelPath) { [weak self] success in
            Task { @MainActor in
                self?.isModelLoaded = success
                
                let modelLoadSuccessText = NSLocalizedString("ModelLoadingSuccessText", comment: "")
                let modelLoadFailText = NSLocalizedString("ModelLoadingFailText", comment: "")
                let loadResult = success ? modelLoadSuccessText : modelLoadFailText
                
                self?.send(draft: DraftMessage(
                    text: loadResult,
                    thinkText: "",
                    medias: [],
                    recording: nil,
                    replyMessage: nil,
                    createdAt: Date()
                ), userType: .system)
                
                self?.processHistoryMessages()
            }
        }
    }
    
    private func processHistoryMessages() {
        guard let history = self.history else { return }
        
        let historyPrompts = history.messages.flatMap { msg -> [[String: String]] in
            var prompts: [[String: String]] = []
            let sender = msg.isUser ? "user" : "assistant"
            
            prompts.append([sender: msg.content])
            
            if let images = msg.images {
                let imgStr = images.map { "<img>\($0.full.path)</img>" }.joined()
                prompts.append([sender: imgStr])
            }
            
            if let audio = msg.audio, let url = audio.url {
                prompts.append([sender: "<audio>\(url.path)</audio>"])
            }
            
            return prompts
        }
        
        let nsArray = historyPrompts as [[AnyHashable: Any]]
        llm?.addPrompts(from: nsArray)
    }
    
    func sendToLLM(draft: DraftMessage) {
        self.send(draft: draft, userType: .user)
        if isModelLoaded {
            /* TODO: support diffusion
             self.getDiffusionResponse(draft: draft)
             */
            self.getLLMRespsonse(draft: draft)
        }
    }
    
    func send(draft: DraftMessage, userType: UserType) {
        interactor.send(draftMessage: draft, userType: userType)
    }
    
//    func getDiffusionResponse(draft: DraftMessage) {
//        Task {
//            diffusion?.run(withPrompt: "one cat", imagePath: "dog.jpg", progressCallback: { progress in
//                print(progress)
//            })
//        }
//    }
    
    func getLLMRespsonse(draft: DraftMessage) {
        Task {
            await llmState.setProcessing(true)
            await MainActor.run { self.isProcessing = true }
            
            var content = draft.text
            let medias = draft.medias
            
            // MARK: Add image
            for media in medias {
                guard media.type == .image, let url = await media.getURL() else {
                    continue
                }

                let isInTempDirectory = url.path.contains("/tmp/")
                let fileName = url.lastPathComponent
                
                if !isInTempDirectory {
                    guard let fileUrl = AssetExtractor.copyFileToTmpDirectory(from: url, fileName: fileName) else {
                        continue
                    }
                    let processedUrl = convertHEICImage(from: fileUrl)
                    content = "<img>\(processedUrl?.path ?? "")</img>" + content
                } else {
                    let processedUrl = convertHEICImage(from: url)
                    content = "<img>\(processedUrl?.path ?? "")</img>" + content
                }
            }
            
            if let audio = draft.recording, let path = audio.url {
//                if let wavFile = await convertACCToWAV(accFileUrl: path) {
                content = "<audio>\(path.path)</audio>" + content
//                }
            }
            
            let convertedContent = self.convertDeepSeekMutliChat(content: content)
            
            await llmState.processContent(convertedContent, llm: self.llm) { [weak self] output in
                Task { @MainActor in
                    if (output.contains("<eop>")) {
                        self?.isProcessing = false
                        await self?.llmState.setProcessing(false)
                    } else {
                        self?.send(draft: DraftMessage(
                            text: output,
                            thinkText: "",
                            medias: [],
                            recording: nil,
                            replyMessage: nil,
                            createdAt: Date()
                        ), userType: .assistant)
                    }
                }
            }
        }
    }
    
    private func convertDeepSeekMutliChat(content: String) -> String {
        if self.modelInfo.name.lowercased().contains("deepseek") {
            /* formate:: <|begin_of_sentence|><|User|>{text}<|Assistant|>{text}<|end_of_sentence|>
             <|User|>{text}<|Assistant|>{text}<|end_of_sentence|>
             */
            var deepSeekContent = "<|begin_of_sentence|>"
            
            for message in messages {
                let senderTag: String
                switch message.user.id {
                case "1":
                    senderTag = "<|User|>"
                case "2":
                    senderTag = "<|Assistant|>"
                default:
                    continue
                }
                deepSeekContent += "\(senderTag)\(message.text)"
            }
            
            deepSeekContent += "<|end_of_sentence|><think><\n>"
            
            return deepSeekContent
        } else {
            return content
        }
    }
    
    private func convertHEICImage(from url: URL) -> URL? {
        var fileUrl = url
        if fileUrl.isHEICImage() {
            if let convertedUrl = AssetExtractor.convertHEICToJPG(heicUrl: fileUrl) {
                fileUrl = convertedUrl
            }
        }
        return fileUrl
    }
    
    func onStart() {
        interactor.messages
            .compactMap { messages in
                messages.map { $0.toChatMessage() }
            }
            .assign(to: &$messages)

        interactor.connect()
        
        self.setupLLM(modelPath: self.modelInfo.localPath)
    }

    func onStop() {
        ChatHistoryManager.shared.saveChat(
            historyId: historyId,
            modelId: modelInfo.modelId,
            modelName: modelInfo.name,
            messages: messages
        )
        
        interactor.disconnect()
        llm = nil
        self.cleanTmpFolder()
    }

    func loadMoreMessage(before message: Message) {
        interactor.loadNextPage()
            .sink { _ in }
            .store(in: &subscriptions)
    }
    
    private func cleanTmpFolder() {
        
        let fileManager = FileManager.default
        let tmpDirectoryURL = fileManager.temporaryDirectory
        
        let tmpFolderURL = URL(fileURLWithPath: self.modelInfo.localPath).appendingPathComponent("temp")
        
        self.cleanFolder(tmpFolderURL: tmpFolderURL)
        self.cleanFolder(tmpFolderURL: tmpDirectoryURL)
    }
    
    private func cleanFolder(tmpFolderURL: URL) {
        let fileManager = FileManager.default
        do {
            let files = try fileManager.contentsOfDirectory(at: tmpFolderURL, includingPropertiesForKeys: nil)
            for file in files {
                if !file.absoluteString.lowercased().contains("networkdownload") {
                    do {
                        try fileManager.removeItem(at: file)
                        print("Deleted file: \(file.path)")
                    } catch {
                        print("Error deleting file: \(file.path), \(error.localizedDescription)")
                    }
                }
            }
        } catch {
            print("Error accessing tmp directory: \(error.localizedDescription)")
        }
    }
}
