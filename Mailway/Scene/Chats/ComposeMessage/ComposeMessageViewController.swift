//
//  ComposeMessageViewController.swift
//  Mailway
//
//  Created by Cirno MainasuK on 2020-7-6.
//  Copyright © 2020 Dimension. All rights reserved.
//

import os
import UIKit
import Combine
import CoreData
import CoreDataStack
import NtgeCore

final class ComposeMessageViewModel: NSObject {
    
    var disposeBag = Set<AnyCancellable>()
    
    let fetchedResultsController: NSFetchedResultsController<Contact>

    // input
    let context: AppContext
    let recipientPublicKeys: [Ed25519.PublicKey]
    let message = CurrentValueSubject<String, Never>("")
    
    // output
    let isComposeBarButtonEnabled = CurrentValueSubject<
        Bool, Never>(false)
    let titleViewContentInset = CurrentValueSubject<UIEdgeInsets, Never>(UIEdgeInsets())
    let titleViewHeight = CurrentValueSubject<CGFloat, Never>(.zero)
    let identities = CurrentValueSubject<[Contact], Never>([])
    let selectedIdentity = CurrentValueSubject<Contact?, Never>(nil)
    let selectedIdentityPrivateKey = CurrentValueSubject<Ed25519.PrivateKey?, Never>(nil)
    
    init(context: AppContext, recipientPublicKeys: [Ed25519.PublicKey]) {
        self.fetchedResultsController = {
            let fetchRequest = Contact.sortedFetchRequest
            fetchRequest.returnsObjectsAsFaults = false
            fetchRequest.fetchBatchSize = 20
            fetchRequest.predicate = Contact.isIdentityPredicate
            
            let controller = NSFetchedResultsController(
                fetchRequest: fetchRequest,
                managedObjectContext: context.managedObjectContext,
                sectionNameKeyPath: nil,
                cacheName: nil
            )
            
            return controller
        }()
        self.context = context
        self.recipientPublicKeys = recipientPublicKeys
        
        super.init()
        
        fetchedResultsController.delegate = self
        
        message
            .map { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .assign(to: \.value, on: isComposeBarButtonEnabled)
            .store(in: &disposeBag)
        
        identities
            .sink { identities in
                if let selectedIdentity = self.selectedIdentity.value {
                    guard identities.contains(selectedIdentity) else {
                        // update selection if old removed
                        self.selectedIdentity.value = identities.first
                        return
                    }

                    // do nothing

                } else {
                    // fulfill if nil
                    self.selectedIdentity.value = identities.first
                }
            }
            .store(in: &disposeBag)
        
        selectedIdentity
            .map { identity in
                identity.flatMap { identity in
                    guard let privateKeyText = identity.keypair?.privateKey,
                        let privateKey = Ed25519.PrivateKey.deserialize(from: privateKeyText) else {
                            return nil
                    }
                    return privateKey
                }
            }
            .assign(to: \.value, on: selectedIdentityPrivateKey)
            .store(in: &disposeBag)
    }
    
}

extension ComposeMessageViewModel {
    
    func composeMessage() -> Future<Result<ChatMessage, Swift.Error>, Never> {
        guard let signer = selectedIdentityPrivateKey.value else {
            return Future { promise in
                promise(.success(.failure(Error.identityNotFound)))
            }
        }
        
        guard !recipientPublicKeys.isEmpty else {
            return Future { promise in
                promise(.success(.failure(Error.recipientNotFound)))
            }
        }
        
        let plaintext = message.value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !plaintext.isEmpty else {
            return Future { promise in
                promise(.success(.failure(Error.emptyMessage)))
            }
        }
        let plaintextData = Data(plaintext.utf8)
                
        return DocumentStore.createChatMessage(into: context.managedObjectContext, plaintextData: plaintextData, recipientPublicKeys: recipientPublicKeys, signerPrivateKey: signer)
    }
    
}

extension ComposeMessageViewModel {
    
    enum Error: Swift.Error, LocalizedError {
        case identityNotFound
        case recipientNotFound
        case emptyMessage
        
        var errorDescription: String? {
            switch self {
            case .identityNotFound:
                return L10n.ComposeMessage.Error.IdentityNotFound.errorDescription
            case .recipientNotFound:
                return L10n.ComposeMessage.Error.RecipientNotFound.errorDescription
            case .emptyMessage:
                return L10n.ComposeMessage.Error.EmptyMessage.errorDescription
            }
        }
        
        var failureReason: String? {
            switch self {
            case .identityNotFound:
                return L10n.ComposeMessage.Error.IdentityNotFound.failureReason
            case .recipientNotFound:
                return L10n.ComposeMessage.Error.RecipientNotFound.failureReason
            case .emptyMessage:
                return L10n.ComposeMessage.Error.EmptyMessage.failureReason
            }
        }
        
        var recoverySuggestion: String? {
            switch self {
            case .identityNotFound:
                return L10n.ComposeMessage.Error.IdentityNotFound.recoverySuggestion
            case .recipientNotFound:
                return L10n.ComposeMessage.Error.RecipientNotFound.recoverySuggestion
            case .emptyMessage:
                return L10n.ComposeMessage.Error.EmptyMessage.recoverySuggestion
            }
        }
    }
    
}

// MARK: - NSFetchedResultsControllerDelegate
extension ComposeMessageViewModel: NSFetchedResultsControllerDelegate {
    
    func controller(_ controller: NSFetchedResultsController<NSFetchRequestResult>, didChangeContentWith snapshot: NSDiffableDataSourceSnapshotReference) {
        let identities = fetchedResultsController.sections?.first?.objects as? [Contact] ?? []
        self.identities.value = identities
    }
    
}

final class ComposeMessageViewController: UIViewController, NeedsDependency, ComposeMessageTransitionableViewController {
    
    var disposeBag = Set<AnyCancellable>()
    var observations = Set<NSKeyValueObservation>()
    
    weak var context: AppContext! { willSet { precondition(!isViewLoaded) } }
    weak var coordinator: SceneCoordinator! { willSet { precondition(!isViewLoaded) } }
    
    var viewModel: ComposeMessageViewModel!
    
    private(set) var transitionController: ComposeMessageTransitionController!
    
    let identitySelectionNavigationItemTitleViewTapGestureRecognizer = UITapGestureRecognizer()
    private lazy var identitySelectionNavigationItemTitleView: IdentitySelectionNavigationItemTitleView = {
        let titleView = IdentitySelectionNavigationItemTitleView()
        titleView.addGestureRecognizer(identitySelectionNavigationItemTitleViewTapGestureRecognizer)
        titleView.entryView.disclosureButton.isHidden = false
        return titleView
    }()
    
    private lazy var closeBarButtonItem: UIBarButtonItem = {
        let item = UIBarButtonItem()
        item.image = Asset.NavigationBar.close.image
        item.tintColor = Asset.Color.Tint.barButtonItem.color
        item.target = self
        item.action = #selector(ComposeMessageViewController.closeBarButtonItemPressed(_:))
        return item
    }()
    
    private lazy var composeBarButtonItem: UIBarButtonItem = {
        let item = UIBarButtonItem()
        item.image = Asset.Communication.paperplane.image
        //item.tintColor = Asset.Color.Tint.barButtonItem.color
        item.target = self
        item.action = #selector(ComposeMessageViewController.composeBarButtonItemPressed(_:))
        return item
    }()
    
    let messageTextView: UITextView = {
        let textView = UITextView()
        textView.font = .systemFont(ofSize: 17)
        textView.showsVerticalScrollIndicator = false
        return textView
    }()
    
}

extension ComposeMessageViewController {
    
    override func viewDidLoad() {
        super.viewDidLoad()
    
        view.backgroundColor = .systemBackground
        navigationItem.leftBarButtonItem = closeBarButtonItem
        navigationItem.rightBarButtonItem = composeBarButtonItem
        navigationItem.titleView = identitySelectionNavigationItemTitleView
        
        identitySelectionNavigationItemTitleView.observe(\.frame) { [weak self] titleView, change in
            guard let `self` = self else { return }

            let margin = titleView.frame.origin.y
            let left = titleView.frame.origin.x
            let right = left
            self.viewModel.titleViewContentInset.value = UIEdgeInsets(top: margin, left: left, bottom: margin, right: right)
            self.viewModel.titleViewHeight.value = titleView.frame.height
        }.store(in: &observations)
        
        transitionController = ComposeMessageTransitionController(viewController: self)
        
        identitySelectionNavigationItemTitleViewTapGestureRecognizer.addTarget(self, action: #selector(ComposeMessageViewController.tapGestureRecognizerHandler(_:)))
        
        messageTextView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(messageTextView)
        NSLayoutConstraint.activate([
            messageTextView.topAnchor.constraint(equalTo: view.topAnchor),
            messageTextView.leadingAnchor.constraint(equalTo: view.readableContentGuide.leadingAnchor),
            messageTextView.trailingAnchor.constraint(equalTo: view.readableContentGuide.trailingAnchor),
            messageTextView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        
        do {
            try viewModel.fetchedResultsController.performFetch()
        } catch {
            assertionFailure(error.localizedDescription)
        }
        
        viewModel.isComposeBarButtonEnabled
            .assign(to: \.isEnabled, on: composeBarButtonItem)
            .store(in: &disposeBag)
        
        // handle keyboard overlap
        Publishers.CombineLatest3(
            KeyboardResponderService.shared.isShow.eraseToAnyPublisher(),
            KeyboardResponderService.shared.state.eraseToAnyPublisher(),
            KeyboardResponderService.shared.endFrame.eraseToAnyPublisher()
        )
        .sink(receiveValue: { isShow, state, endFrame in
            guard isShow, state == .dock else {
                self.messageTextView.contentInset.bottom = 0.0
                self.messageTextView.verticalScrollIndicatorInsets.bottom = 0.0
                return
            }
            
            // isShow AND dock state
            let textViewFrame = self.view.convert(self.messageTextView.frame, to: nil)
            let padding = textViewFrame.maxY - endFrame.minY
            guard padding > 0 else {
                self.messageTextView.contentInset.bottom = 0.0
                self.messageTextView.verticalScrollIndicatorInsets.bottom = 0.0
                return
            }
            
            self.messageTextView.contentInset.bottom = padding
            self.messageTextView.verticalScrollIndicatorInsets.bottom = padding
        })
        .store(in: &disposeBag)
        
        viewModel.selectedIdentity
            .sink { [weak self] identity in
                guard let `self` = self else { return }
                let entryView = self.identitySelectionNavigationItemTitleView.entryView
                entryView.avatarImageView.image = identity?.avatar ?? UIImage.placeholder(color: .systemFill)
                entryView.nameLabel.text = identity?.name ?? "-"
                entryView.shortKeyIDLabel.text = identity?.keypair.flatMap { String($0.keyID.suffix(8)).separate(every: 4, with: " ") } ?? "-"
            }
            .store(in: &disposeBag)
        
        messageTextView.delegate = self
        messageTextView.becomeFirstResponder()        
    }
    
}


extension ComposeMessageViewController {
    
    @objc private func closeBarButtonItemPressed(_ sender: UIBarButtonItem) {
        guard viewModel.message.value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            let alertController = UIAlertController(title: "Discard Compose", message: "Please confirm discard message composing.", preferredStyle: .alert)
            let discardAction = UIAlertAction(title: "Confirm Discard", style: .destructive) { _ in
                self.dismiss(animated: true, completion: nil)
            }
            alertController.addAction(discardAction)
            let cancelAction = UIAlertAction(title: "Cancel", style: .cancel, handler: nil)
            alertController.addAction(cancelAction)
            
            present(alertController, animated: true, completion: nil)
            return
        }
        
        dismiss(animated: true, completion: nil)
    }
    
    @objc private func composeBarButtonItemPressed(_ sender: UIBarButtonItem) {
        sender.isEnabled = false
        viewModel.composeMessage()
            .sink(
                receiveCompletion: { _ in
                    sender.isEnabled = true
                }, receiveValue: { [weak self] result in
                    switch result {
                    case .success(let chatMessage):
                        self?.dismiss(animated: true) {
                            guard let `self` = self else { return }
                            guard let chat = chatMessage.chat else {
                                assertionFailure()
                                return
                            }
                            let chatRoomViewModel = ChatViewModel(context: self.context, chat: chat)
                            self.coordinator.present(scene: .chatRoom(viewModel: chatRoomViewModel), from: nil, transition: .showDetail)
                        }
                    case .failure(let error):
                        let alertController = UIAlertController.standardAlert(of: error)
                        self?.present(alertController, animated: true, completion: nil)
                    }
                }
            )
            .store(in: &disposeBag)
    }
    
    @objc private func tapGestureRecognizerHandler(_ sender: UITapGestureRecognizer) {
        os_log("%{public}s[%{public}ld], %{public}s: sender: %s", ((#file as NSString).lastPathComponent), #line, #function, sender.debugDescription)

        guard sender === identitySelectionNavigationItemTitleViewTapGestureRecognizer else {
            return
        }
        let identities = viewModel.identities.value
        guard !identities.isEmpty else {
            return
        }
        
        guard let selectIdentity = viewModel.selectedIdentity.value,
        let selectIndex = identities.firstIndex(of: selectIdentity) else {
            return
        }
            
        let selectIdentityDropdownMenuViewModel = SelectIdentityDropdownMenuViewModel(context: context, identities: identities, selectIndex: selectIndex)
        viewModel.titleViewContentInset.assign(to: \.value, on: selectIdentityDropdownMenuViewModel.cellContentInset).store(in: &selectIdentityDropdownMenuViewModel.disposeBag)
        viewModel.titleViewHeight.assign(to: \.value, on: selectIdentityDropdownMenuViewModel.cellEntryViewHeight).store(in: &disposeBag)
        coordinator.present(scene: .selectIdentityDropdownMenu(viewModel: selectIdentityDropdownMenuViewModel, delegate: self), from: self, transition: .custom(transitioningDelegate: transitionController))
    }
    
}

// MARK: - UITextViewDelegate
extension ComposeMessageViewController: UITextViewDelegate {
    
    func textViewDidChange(_ textView: UITextView) {
        guard textView === messageTextView else {
            return
        }
        
        viewModel.message.value = textView.text ?? ""
    }
    
}


// MARK: - SelectIdentityDropdownMenuViewControllerDelegate
extension ComposeMessageViewController: SelectIdentityDropdownMenuViewControllerDelegate {
    
    func selectIdentityDropdownMenuViewController(_ controller: SelectIdentityDropdownMenuViewController, didSelectIdentity identity: Contact) {
        viewModel.selectedIdentity.value = identity
    }
    
}
