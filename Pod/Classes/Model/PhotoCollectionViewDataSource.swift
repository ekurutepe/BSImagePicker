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

/**
Gives UICollectionViewDataSource functionality with a given data source and cell factory
*/
final class PhotoCollectionViewDataSource : NSObject, UICollectionViewDataSource {
    var selections = [PHAsset]()
    var fetchResult: PHFetchResult<AnyObject>
    
    private let photoCellIdentifier = "photoCellIdentifier"
    private let photosManager = PHCachingImageManager.default()
    private let imageContentMode: PHImageContentMode = .aspectFill
    
    let settings: BSImagePickerSettings?
    var imageSize: CGSize = CGSize()
    
  init(fetchResult: PHFetchResult<AnyObject>, selections: PHFetchResult<AnyObject>? = nil, settings: BSImagePickerSettings?) {
        self.fetchResult = fetchResult
        self.settings = settings
        if let selections = selections {
            var selectionsArray = [PHAsset]()
            selections.enumerateObjects { (asset, idx, stop) -> Void in
                if let asset = asset as? PHAsset {
                    selectionsArray.append(asset)
                }
            }
            self.selections = selectionsArray
        }
    
        super.init()
    }
    
    func numberOfSectionsInCollectionView(collectionView: UICollectionView) -> Int {
        return 1
    }
    
    func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int {
        return fetchResult.count
    }
    
    func collectionView(_ collectionView: UICollectionView, cellForItemAt indexPath: IndexPath) -> UICollectionViewCell {
        UIView.setAnimationsEnabled(false)
        let cell = collectionView.dequeueReusableCell(withReuseIdentifier: photoCellIdentifier, for: indexPath) as! PhotoCell
        if let settings = settings {
            cell.settings = settings
        }
        
        // Cancel any pending image requests
        if cell.tag != 0 {
            photosManager.cancelImageRequest(PHImageRequestID(cell.tag))
        }
        
        if let asset = fetchResult[indexPath.row] as? PHAsset {
            cell.asset = asset
            
            // Request image
            cell.tag = Int(photosManager.requestImage(for: asset, targetSize: imageSize, contentMode: imageContentMode, options: nil) { (result, _) in
                cell.imageView.image = result
            })
            
            // Set selection number
            if let asset = fetchResult[indexPath.row] as? PHAsset, let index = selections.index(of: asset) {
                if let character = settings?.selectionCharacter {
                    cell.selectionString = String(character)
                } else {
                    cell.selectionString = String(index+1)
                }
                
                cell.isSelected = true
            } else {
                cell.isSelected = false
            }
        }
        
        UIView.setAnimationsEnabled(true)
        
        return cell
    }
    
    func registerCellIdentifiersForCollectionView(collectionView: UICollectionView?) {
        collectionView?.register(UINib(nibName: "PhotoCell", bundle: BSImagePickerViewController.bundle), forCellWithReuseIdentifier: photoCellIdentifier)
    }
}
