// The MIT License (MIT)
//
// Copyright (c) 2015 Joakim Gyllström
//
// Permission is hereby granted, free of charge, to any person obtaining a copy
// of this software and associated documentation files (the "Software"), to deal
// in the Software without restriction, including without limitation the rights
// to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
// copies of the Software, and to permit persons to whom the Software is
// furnished to do so, subject to the following conditions:
//
// The above copyright notice and this permission notice shall be included in all
// copies or substantial portions of the Software.
//
// THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
// IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
// FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
// AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
// LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
// OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
// SOFTWARE.

import UIKit
import Photos
import BSGridCollectionViewLayout

final class PhotosViewController : UICollectionViewController {    
    var selectionClosure: ((asset: PHAsset) -> Void)?
    var deselectionClosure: ((asset: PHAsset) -> Void)?
    var cancelClosure: ((assets: [PHAsset]) -> Void)?
    var finishClosure: ((assets: [PHAsset]) -> Void)?
    
    var doneBarButton: UIBarButtonItem?
    var cancelBarButton: UIBarButtonItem?
    var albumTitleView: AlbumTitleView?
    
    let expandAnimator = ZoomAnimator()
    let shrinkAnimator = ZoomAnimator()
    
    private var photosDataSource: PhotoCollectionViewDataSource?
    private var albumsDataSource: AlbumTableViewDataSource
    private let cameraDataSource: CameraCollectionViewDataSource
    private var composedDataSource: ComposedCollectionViewDataSource?
    
    private var defaultSelections: PHFetchResult<AnyObject>?
    
    let settings: BSImagePickerSettings
    
    private var doneBarButtonTitle: String?
    
    lazy var albumsViewController: AlbumsViewController = {
        let storyboard = UIStoryboard(name: "Albums", bundle: BSImagePickerViewController.bundle)
        let vc = storyboard.instantiateInitialViewController() as! AlbumsViewController
        vc.tableView.dataSource = self.albumsDataSource
        vc.tableView.delegate = self
        
        return vc
    }()
    
    private lazy var previewViewContoller: PreviewViewController? = {
        return PreviewViewController(nibName: nil, bundle: nil)
    }()
    
    required init(fetchResults: [PHFetchResult<PHAssetCollection>], defaultSelections: PHFetchResult<AnyObject>? = nil, settings aSettings: BSImagePickerSettings) {
        albumsDataSource = AlbumTableViewDataSource(fetchResults: fetchResults)
        cameraDataSource = CameraCollectionViewDataSource(settings: aSettings, cameraAvailable: UIImagePickerController.isSourceTypeAvailable(.camera))
        self.defaultSelections = defaultSelections
        settings = aSettings
        
        super.init(collectionViewLayout: GridCollectionViewLayout())
        
        PHPhotoLibrary.shared().register(self)
    }

    required init?(coder aDecoder: NSCoder) {
        fatalError("b0rk: initWithCoder not implemented")
    }
    
    deinit {
        PHPhotoLibrary.shared().unregisterChangeObserver(self)
    }
    
    override func loadView() {
        super.loadView()
        
        // Setup collection view
        collectionView?.backgroundColor = UIColor.white()
        collectionView?.allowsMultipleSelection = true
        
        // Set an empty title to get < back button
        title = " "
        
        // Set button actions and add them to navigation item
        doneBarButton?.target = self
        doneBarButton?.action = #selector(self.doneButtonPressed(sender:))
        cancelBarButton?.target = self
        cancelBarButton?.action = #selector(self.cancelButtonPressed(sender:))
        albumTitleView?.albumButton?.addTarget(self, action: #selector(self.albumButtonPressed(sender:)), for: .touchUpInside)
        navigationItem.leftBarButtonItem = cancelBarButton
        navigationItem.rightBarButtonItem = doneBarButton
        navigationItem.titleView = albumTitleView

        if let album = albumsDataSource.fetchResults.first?.firstObject {
            initializePhotosDataSource(album: album, selections: defaultSelections)
            updateAlbumTitle(album: album)
            synchronizeCollectionView()
        }
        
        // Add long press recognizer
        let longPressRecognizer = UILongPressGestureRecognizer(target: self, action: #selector(self.collectionViewLongPressed(sender:)))
        longPressRecognizer.minimumPressDuration = 0.5
        collectionView?.addGestureRecognizer(longPressRecognizer)
        
        // Set navigation controller delegate
        navigationController?.delegate = self
        
        // Register cells
        photosDataSource?.registerCellIdentifiersForCollectionView(collectionView: collectionView)
        cameraDataSource.registerCellIdentifiersForCollectionView(collectionView: collectionView)
    }
    
    // MARK: Appear/Disappear
    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        
        updateDoneButton()
    }
    
    // MARK: Button actions
    func cancelButtonPressed(sender: UIBarButtonItem) {
        guard let closure = cancelClosure, let photosDataSource = photosDataSource else {
            dismiss(animated: true, completion: nil)
            return
        }
        
        DispatchQueue.global().async {
            closure(assets: photosDataSource.selections)
        }
        
        dismiss(animated: true, completion: nil)
    }
    
    func doneButtonPressed(sender: UIBarButtonItem) {
        guard let closure = finishClosure, let photosDataSource = photosDataSource else {
            dismiss(animated: true, completion: nil)
            return
        }
        
        DispatchQueue.global().async {
            closure(assets: photosDataSource.selections)
        }
        
        dismiss(animated: true, completion: nil)
    }
    
    func albumButtonPressed(sender: UIButton) {
        guard let popVC = albumsViewController.popoverPresentationController else {
            return
        }
        
        popVC.permittedArrowDirections = .up
        popVC.sourceView = sender
        let senderRect = sender.convert(sender.frame, from: sender.superview)
        let sourceRect = CGRect(x: senderRect.origin.x, y: senderRect.origin.y + (sender.frame.size.height / 2), width: senderRect.size.width, height: senderRect.size.height)
        popVC.sourceRect = sourceRect
        popVC.delegate = self
        albumsViewController.tableView.reloadData()
        
        present(albumsViewController, animated: true, completion: nil)
    }
    
    func collectionViewLongPressed(sender: UIGestureRecognizer) {
        if sender.state == .began {
            // Disable recognizer while we are figuring out location and pushing preview
            sender.isEnabled = false
            collectionView?.isUserInteractionEnabled = false
            
            // Calculate which index path long press came from
            let location = sender.location(in: collectionView)
            let indexPath = collectionView?.indexPathForItem(at: location)
            
            if let vc = previewViewContoller, let indexPath = indexPath, let cell = collectionView?.cellForItem(at: indexPath) as? PhotoCell, let asset = cell.asset {
                // Setup fetch options to be synchronous
                let options = PHImageRequestOptions()
                options.isSynchronous = true
                
                // Load image for preview
                if let imageView = vc.imageView {
                    PHCachingImageManager.default().requestImage(for: asset, targetSize:imageView.frame.size, contentMode: .aspectFit, options: options) { (result, _) in
                        imageView.image = result
                    }
                }
                
                // Setup animation
                expandAnimator.sourceImageView = cell.imageView
                expandAnimator.destinationImageView = vc.imageView
                shrinkAnimator.sourceImageView = vc.imageView
                shrinkAnimator.destinationImageView = cell.imageView
                
                navigationController?.pushViewController(vc, animated: true)
            }
            
            // Re-enable recognizer, after animation is done
            DispatchQueue.main.after(when: DispatchTime.now() + DispatchTimeInterval.seconds(Int(expandAnimator.transitionDuration(using: nil)))) {
                sender.isEnabled = true
                self.collectionView?.isUserInteractionEnabled = true
            }
        }
    }
    
    // MARK: Private helper methods
    func updateDoneButton() {
        // Find right button
        if let subViews = navigationController?.navigationBar.subviews, let photosDataSource = photosDataSource {
            for view in subViews {
                if let btn = view as? UIButton where checkIfRightButtonItem(btn: btn) {
                    // Store original title if we havn't got it
                    if doneBarButtonTitle == nil {
                        doneBarButtonTitle = btn.title(for: .normal)
                    }
                    
                    // Update title
                    if let doneBarButtonTitle = doneBarButtonTitle {
                        // Special case if we have selected 1 image and that is
                        // the max number of allowed selections
                        if (photosDataSource.selections.count == 1 && self.settings.maxNumberOfSelections == 1) {
                            btn.bs_setTitleWithoutAnimation(title: "\(doneBarButtonTitle)", forState: .normal)
                        } else if photosDataSource.selections.count > 0 {
                            btn.bs_setTitleWithoutAnimation(title: "\(doneBarButtonTitle) (\(photosDataSource.selections.count))", forState: .normal)
                        } else {
                            btn.bs_setTitleWithoutAnimation(title: doneBarButtonTitle, forState: .normal)
                        }
                        
                        // Enabled?
                        doneBarButton?.isEnabled = photosDataSource.selections.count > 0
                    }
                    
                    // Stop loop
                    break
                }
            }
        }
    }
    
    // Check if a give UIButton is the right UIBarButtonItem in the navigation bar
    // Somewhere along the road, our UIBarButtonItem gets transformed to an UINavigationButton
    func checkIfRightButtonItem(btn: UIButton) -> Bool {
        guard let rightButton = navigationItem.rightBarButtonItem else {
            return false
        }
        
        // Store previous values
        let wasRightEnabled = rightButton.isEnabled
        let wasButtonEnabled = btn.isEnabled
        
        // Set a known state for both buttons
        rightButton.isEnabled = false
        btn.isEnabled = false
        
        // Change one and see if other also changes
        rightButton.isEnabled = true
        let isRightButton = btn.isEnabled
        
        // Reset
        rightButton.isEnabled = wasRightEnabled
        btn.isEnabled = wasButtonEnabled
        
        return isRightButton
    }
    
    func synchronizeSelectionInCollectionView(collectionView: UICollectionView) {
        guard let photosDataSource = photosDataSource else {
            return
        }
        
        // Get indexes of the selected assets
        var mutableIndexSet = IndexSet()
        for object in photosDataSource.selections {
            let index = photosDataSource.fetchResult.index(of: object)
            if index != NSNotFound {
                mutableIndexSet.insert(index)
            }
        }
        
        // Convert into index paths
        let indexPaths = mutableIndexSet.bs_indexPaths(for: 1)
        
        // Loop through them and set them as selected in the collection view
        for indexPath in indexPaths {
            collectionView.selectItem(at: indexPath as IndexPath, animated: false, scrollPosition: [])
        }
    }
    
    func updateAlbumTitle(album: PHAssetCollection) {
        if let title = album.localizedTitle {
            // Update album title
            albumTitleView?.albumTitle = title
        }
    }
    
  func initializePhotosDataSource(album: PHAssetCollection, selections: PHFetchResult<AnyObject>? = nil) {
        // Set up a photo data source with album
        let fetchOptions = PHFetchOptions()
        fetchOptions.sortDescriptors = [
            SortDescriptor(key: "creationDate", ascending: false)
        ]
        fetchOptions.predicate = Predicate(format: "mediaType = %d", PHAssetMediaType.image.rawValue)
        initializePhotosDataSourceWithFetchResult(fetchResult: PHAsset.fetchAssets(in: album, options: fetchOptions), selections: selections)
    }
    
    func initializePhotosDataSourceWithFetchResult(fetchResult: PHFetchResult<PHAsset>, selections: PHFetchResult<AnyObject>? = nil) {
        let newDataSource = PhotoCollectionViewDataSource(fetchResult: fetchResult, selections: selections, settings: settings)
        
        // Transfer image size
        // TODO: Move image size to settings
        if let photosDataSource = photosDataSource {
            newDataSource.imageSize = photosDataSource.imageSize
            newDataSource.selections = photosDataSource.selections
        }
        
        photosDataSource = newDataSource
        
        // Hook up data source
        composedDataSource = ComposedCollectionViewDataSource(dataSources: [cameraDataSource, newDataSource])
        collectionView?.dataSource = composedDataSource
        collectionView?.delegate = self
    }
    
    func synchronizeCollectionView() {
        guard let collectionView = collectionView else {
            return
        }
        
        // Reload and sync selections
        collectionView.reloadData()
        synchronizeSelectionInCollectionView(collectionView: collectionView)
    }
}

// MARK: UICollectionViewDelegate
extension PhotosViewController {
    override func collectionView(_ collectionView: UICollectionView, shouldSelectItemAt indexPath: IndexPath) -> Bool {
        // Camera shouldn't be selected, but pop the UIImagePickerController!
        if let composedDataSource = composedDataSource where composedDataSource.dataSources[indexPath.section].isEqual(cameraDataSource) {
            let cameraController = UIImagePickerController()
            cameraController.allowsEditing = false
            cameraController.sourceType = .camera
            cameraController.delegate = self
            
            self.present(cameraController, animated: true, completion: nil)
            
            return false
        }
        
        return collectionView.isUserInteractionEnabled && photosDataSource!.selections.count < settings.maxNumberOfSelections
    }
    
    override func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        guard let photosDataSource = photosDataSource, let cell = collectionView.cellForItem(at: indexPath as IndexPath) as? PhotoCell else {
            return
        }
        
        let asset = photosDataSource.fetchResult.object(at: indexPath.row)
        // Select asset if not already selected
        photosDataSource.selections.append(asset)
        
        // Set selection number
        if let selectionCharacter = settings.selectionCharacter {
            cell.selectionString = String(selectionCharacter)
        } else {
            cell.selectionString = String(photosDataSource.selections.count)
        }
        
        // Update done button
        updateDoneButton()
        
        // Call selection closure
        if let closure = selectionClosure {
            DispatchQueue.global().async{ () -> Void in
                closure(asset: asset)
            }
        }
    }
    
    override func collectionView(_ collectionView: UICollectionView, didDeselectItemAt indexPath: IndexPath) {
    
        guard let photosDataSource = photosDataSource else { return }
        
        let asset = photosDataSource.fetchResult.object(at: indexPath.row)
        
        guard let index = photosDataSource.selections.index(of: asset) else { return }
        
        // Deselect asset
        photosDataSource.selections.remove(at: index)
        
        // Update done button
        updateDoneButton()
        
        // Reload selected cells to update their selection number
        if let selectedIndexPaths = collectionView.indexPathsForSelectedItems() {
            UIView.setAnimationsEnabled(false)
            collectionView.reloadItems(at: selectedIndexPaths)
            synchronizeSelectionInCollectionView(collectionView: collectionView)
            UIView.setAnimationsEnabled(true)
        }
        
        // Call deselection closure
        if let closure = deselectionClosure {
            DispatchQueue.global().async {
                closure(asset: asset)
            }
        }
    }
    
    override func collectionView(_ collectionView: UICollectionView, willDisplay cell: UICollectionViewCell, forItemAt indexPath: IndexPath) {
        guard let cell = cell as? CameraCell else {
            return
        }
        
        cell.startLiveBackground() // Start live background
    }
}

// MARK: UIPopoverPresentationControllerDelegate
extension PhotosViewController: UIPopoverPresentationControllerDelegate {
    func adaptivePresentationStyleForPresentationController(controller: UIPresentationController) -> UIModalPresentationStyle {
        return .none
    }
    
    func popoverPresentationControllerShouldDismissPopover(_ popoverPresentationController: UIPopoverPresentationController) -> Bool {
        return true
    }
}
// MARK: UINavigationControllerDelegate
extension PhotosViewController: UINavigationControllerDelegate {
    func navigationController(_ navigationController: UINavigationController, animationControllerFor operation: UINavigationControllerOperation, from fromVC: UIViewController, to toVC: UIViewController) -> UIViewControllerAnimatedTransitioning? {
        if operation == .push {
            return expandAnimator
        } else {
            return shrinkAnimator
        }
    }
}

// MARK: UITableViewDelegate
extension PhotosViewController: UITableViewDelegate {
    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) -> () {
        // Update photos data source
        let album = albumsDataSource.fetchResults[indexPath.section][indexPath.row]
        initializePhotosDataSource(album: album)
        updateAlbumTitle(album: album)
        synchronizeCollectionView()
        // Dismiss album selection
        albumsViewController.dismiss(animated: true, completion: nil)
    }
}

// MARK: Traits
extension PhotosViewController {
    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        
        if let collectionViewFlowLayout = collectionViewLayout as? GridCollectionViewLayout {
            let itemSpacing: CGFloat = 2.0
            let cellsPerRow = settings.cellsPerRow(verticalSize: traitCollection.verticalSizeClass, horizontalSize: traitCollection.horizontalSizeClass)
            
            collectionViewFlowLayout.itemSpacing = itemSpacing
            collectionViewFlowLayout.itemsPerRow = cellsPerRow
            
            photosDataSource?.imageSize = collectionViewFlowLayout.itemSize
            
            updateDoneButton()
        }
    }
}

// MARK: UIImagePickerControllerDelegate
extension PhotosViewController: UIImagePickerControllerDelegate {
    func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [String : AnyObject]) {
        guard let image = info[UIImagePickerControllerOriginalImage] as? UIImage else {
            picker.dismiss(animated: true, completion: nil)
            return
        }
        
        var placeholder: PHObjectPlaceholder?
        PHPhotoLibrary.shared().performChanges({
            let request = PHAssetChangeRequest.creationRequestForAsset(from: image)
            placeholder = request.placeholderForCreatedAsset
            }, completionHandler: { success, error in
                guard let placeholder = placeholder,
                    let asset = PHAsset.fetchAssets(withLocalIdentifiers: [placeholder.localIdentifier], options: nil).firstObject where success == true else {
                    picker.dismiss(animated: true, completion: nil)
                    return
                }

                DispatchQueue.main.async {
                    // TODO: move to a function. this is duplicated in didSelect
                    self.photosDataSource?.selections.append(asset)
                    self.updateDoneButton()
                    
                    // Call selection closure
                    if let closure = self.selectionClosure {
                        DispatchQueue.global().async {
                            closure(asset: asset)
                        }
                    }
                    
                    picker.dismiss(animated: true, completion: nil)
                }
        })
    }
    
    func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
        picker.dismiss(animated: true, completion: nil)
    }
}

// MARK: PHPhotoLibraryChangeObserver
extension PhotosViewController: PHPhotoLibraryChangeObserver {
    func photoLibraryDidChange(_ changeInstance: PHChange) {
        guard let photosDataSource = photosDataSource, let collectionView = collectionView else {
            return
        }
        
        DispatchQueue.main.async {
            if let photosChanges = changeInstance.changeDetails(for: photosDataSource.fetchResult as! PHFetchResult<AnyObject>) {
                // Update collection view
                // Alright...we get spammed with change notifications, even when there are none. So guard against it
                if photosChanges.hasIncrementalChanges && (photosChanges.removedIndexes?.count > 0 || photosChanges.insertedIndexes?.count > 0 || photosChanges.changedIndexes?.count > 0) {
                    // Update fetch result
                    photosDataSource.fetchResult = photosChanges.fetchResultAfterChanges as! PHFetchResult<PHAsset>
                    
                    if let removed = photosChanges.removedIndexes {
                        collectionView.deleteItems(at: removed.bs_indexPaths(for: 1))
                    }
                    
                    if let inserted = photosChanges.insertedIndexes {
                        collectionView.insertItems(at: inserted.bs_indexPaths(for: 1))
                    }
                    
                    // Changes is causing issues right now...fix me later
                    // Example of issue:
                    // 1. Take a new photo
                    // 2. We will get a change telling to insert that asset
                    // 3. While it's being inserted we get a bunch of change request for that same asset
                    // 4. It flickers when reloading it while being inserted
                    // TODO: FIX
                    //                    if let changed = photosChanges.changedIndexes {
                    //                        print("changed")
                    //                        collectionView.reloadItemsAtIndexPaths(changed.bs_indexPathsForSection(1))
                    //                    }
                    
                    // Sync selection
                    self.synchronizeSelectionInCollectionView(collectionView: collectionView)
                } else if photosChanges.hasIncrementalChanges == false {
                    // Update fetch result
                    photosDataSource.fetchResult = photosChanges.fetchResultAfterChanges as! PHFetchResult<PHAsset>
                    
                    collectionView.reloadData()
                    
                    // Sync selection
                    self.synchronizeSelectionInCollectionView(collectionView: collectionView)
                }
            }
        }
        
        
        // TODO: Changes in albums
    }
}
