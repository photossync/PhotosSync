//
//  PhotosMetadataReader.swift
//  PhotosSync
//
//  Created by Andreas Bentele on 30.10.19.
//  Copyright © 2019 Andreas Bentele. All rights reserved.
//

import Foundation
import Photos

class PhotosMetadataReader {
    public let logger = Logger(loggerName: "PhotosReader", logLevel: .info)
    
    fileprivate let config: Config
    
    init(config: Config) {
        self.config = config
    }
    
    func readMetadata(completion: @escaping (PhotosMetadata) -> (Void)) {
        do {
            let photosMetadata = try self.readMetadata()
            
            try loadAdditionalDataFromSqliteDatabase(photosMetadata.allMediaObjects)
            
            completion(photosMetadata)
        } catch {
            self.logger.error("Error occured: \(error) => abort export")
        }
    }
    
    func loadAdditionalDataFromSqliteDatabase(_ allMediaObjects: [MediaObject]) throws {
        let photosSqliteDAO = try PhotosSqliteDAO(config: self.config)
        let keywordsMap = try photosSqliteDAO.readKeywords()
        let titleMap = try photosSqliteDAO.readTitles()
        let originalFilePathMap = try photosSqliteDAO.readOriginalFilePath()

        for mediaObject in allMediaObjects {
            let zuuid = mediaObject.zuuid()
            
            if let keywords = keywordsMap[zuuid] {
                mediaObject.keywords = keywords
            }
            if let title = titleMap[zuuid] {
                mediaObject.title = title
            }
            
            // originalUrl
            if let originalFilePath = originalFilePathMap[zuuid] {
                let absolutePath = "\(self.config.photosLibraryPath!)/originals/\(originalFilePath)"
                
                // workaround: Apple doesn't expose the URL via PhotoKit API (PHAssetResource) for some PDF's in the PhotoLibrary => get it from SQLite database
                if mediaObject.originalUrl == nil {
                    mediaObject.originalUrl = URL(fileURLWithPath: absolutePath)
                } else if (mediaObject.originalUrl!.path != absolutePath) {
                    // this case is no problem: if in the Library both Jpeg's and RAW photos are uploaded as "original" => PhotoKit already exposes the RAW photo
                    logger.debug("\(mediaObject.localIdentifier!): originalURL \(mediaObject.originalUrl!.path) not as expected: \(absolutePath)")
                }
            }
            
            // current URL: fallback to originalUrl
            if mediaObject.currentUrl == nil {
                mediaObject.currentUrl = mediaObject.originalUrl
            }
            
            // derived URL
            mediaObject.derivedUrl = getDerivedUrl(mediaObject)
            if mediaObject.derivedUrl == nil {
                mediaObject.derivedUrl = mediaObject.currentUrl
            }
        }
    }
    
    fileprivate func readMetadata() throws -> PhotosMetadata {
        let userCollections = PHCollectionList.fetchTopLevelUserCollections(with: nil)

        let rootCollection = PhotoCollection()
        rootCollection.name = "My albums"
        
        let dispatchGroup = DispatchGroup()
        
        // map [zuuid:MediaObject]
        var allMediaObjects: [String:MediaObject] = [:]
        
        try self.readCollection(fetchResult: userCollections, targetCollection: rootCollection, allMediaObjects: &allMediaObjects, dispatchGroup: dispatchGroup)
        
        dispatchGroup.wait()
        
        var allMediaObjectsArray: [MediaObject] = []
        for mediaObject in allMediaObjects.values {
            allMediaObjectsArray += [mediaObject]
        }
        
        return PhotosMetadata(rootCollection: rootCollection, allMediaObjects: allMediaObjectsArray)
    }
    
    
    func readCollection(fetchResult: PHFetchResult<PHCollection>, targetCollection: PhotoCollection, allMediaObjects: inout [String:MediaObject], dispatchGroup: DispatchGroup) throws {
        if fetchResult.count > 0 {
            for i in 0...fetchResult.count-1 {
                if let result = fetchResult.object(at: i) as? PHCollectionList {
                    let collection = PhotoCollection();
                    collection.localIdentifier = result.localIdentifier
                    collection.name = result.localizedTitle!
                    targetCollection.childCollections += [collection]
                    
                    let subFetchResult = PHCollection.fetchCollections(in: result, options: nil)
                    try readCollection(fetchResult: subFetchResult, targetCollection: collection, allMediaObjects: &allMediaObjects, dispatchGroup: dispatchGroup)
                } else if let result = fetchResult.object(at: i) as? PHAssetCollection {
                    let collection = PhotoCollection();
                    collection.localIdentifier = result.localIdentifier
                    collection.name = result.localizedTitle!
                    targetCollection.childCollections += [collection]
                    
                    let assets = PHAsset.fetchAssets(in: result, options: nil)
                    try readCollection(fetchResult: assets, targetCollection: collection, allMediaObjects: &allMediaObjects, dispatchGroup: dispatchGroup)
                } else {
                    let result = fetchResult.object(at: i)
                    print("Unknown asset collection: \(result.localizedTitle!)")
                }
            }
        }
    }
    
    func readCollection(fetchResult: PHFetchResult<PHAsset>, targetCollection: PhotoCollection, allMediaObjects: inout [String:MediaObject], dispatchGroup: DispatchGroup) throws {
        if fetchResult.count > 0 {
            for i in 0...fetchResult.count-1 {
                let asset = fetchResult.object(at: i)

                let zuuid = PhotoObject.zuuid(localIdentifier: asset.localIdentifier)
                
                var mediaObject: MediaObject
                if let mo = allMediaObjects[zuuid] {
                    mediaObject = mo
                } else {
                    mediaObject = MediaObject()
                    mediaObject.localIdentifier = asset.localIdentifier
                    allMediaObjects[zuuid] = mediaObject
                    
                    mediaObject.creationDate = asset.creationDate
                    
                    let assetResources = PHAssetResource.assetResources(for: asset)
                    
    //                if mediaObject.zuuid() == "DEFDFF1A-11DD-4EC4-A72D-F13FB2B4B2ED" {
    //                    mediaObject.printYaml(indent: 0);
    //                    print("asset: \(asset)")
    //                }
                    
                    for assetResource in assetResources {
                        switch (assetResource.type) {
                        case PHAssetResourceType.photo,
                             PHAssetResourceType.video,
                             PHAssetResourceType.audio,
                             PHAssetResourceType.pairedVideo:
                            if mediaObject.originalUrl == nil {
                                mediaObject.originalFilename = getStringProperty(object: assetResource, propertyName: "filename")
                                //                            self.logger.info("Asset originalFileName: \(mediaObject.originalFilename)")
                                let fileUrlString = getStringProperty(object: assetResource, propertyName: "fileURL")
                                mediaObject.originalUrl = URL(string: fileUrlString);
                                //                            self.logger.info("Asset originalUrl: \(mediaObject.originalUrl)")
                            }
                            break;
                        case PHAssetResourceType.fullSizePhoto,
                             PHAssetResourceType.fullSizeVideo,
                             PHAssetResourceType.fullSizePairedVideo:
                            mediaObject.currentUrl = URL(string: getStringProperty(object: assetResource, propertyName: "fileURL"));
                            //                         self.logger.info("Asset currentUrl: \(mediaObject.currentUrl)")
                            break;
                        case PHAssetResourceType.alternatePhoto:
                            // prefer to export raw image instead of jpeg
                            let utiValue = getStringProperty(object: assetResource, propertyName: "uti")
                            if utiValue.contains("raw-image") {
                                mediaObject.originalFilename = getStringProperty(object: assetResource, propertyName: "filename")
                                mediaObject.originalUrl = URL(string: getStringProperty(object: assetResource, propertyName: "fileURL"));
                                //                            self.logger.info("Prefer raw image URL: \(mediaObject.originalUrl)")
                            }
                            break;
                        case  PHAssetResourceType.adjustmentBasePhoto,
                              PHAssetResourceType.adjustmentBaseVideo,
                              PHAssetResourceType.adjustmentBasePairedVideo:
                            // ignore
                            break;
                        case PHAssetResourceType.adjustmentData:
                            // ignore
                            break;
                        @unknown default:
                            self.logger.info("Invalid asset resource type: \(assetResource.type); asset: \(assetResource)")
                            //fatalError()
                        }
                    }
                }
                targetCollection.mediaObjects += [mediaObject]
            }
        }
    }
    
    // workaround to get the derived URL (didn't find any API for this)
    func getDerivedUrl(_ mediaObject: MediaObject) -> URL? {
        let originalPathComponents = mediaObject.originalUrl!.pathComponents
        let subFolder = originalPathComponents[originalPathComponents.count - 2]
        
        let derivedPath = "\(config.photosLibraryPath!)/resources/derivatives/\(subFolder)/\(mediaObject.zuuid())_1_100_o.jpeg"
        if FileManager.default.fileExists(atPath: derivedPath) {
            return URL(fileURLWithPath: derivedPath)
        }
        return nil
    }
    
    func getStringProperty(object: AnyObject, propertyName: String) -> String {
        //let description: String = String(describing: [object.debugDescription])
        let description = object.debugDescription!
        let properties = String(description[description.index(description.firstIndex(of: "{")!, offsetBy: 1)..<description.lastIndex(of: "}")!])
        //logger.info("description: \(description)")
        //logger.info("properties: \(properties)")
        
        let splittedProperties = properties.split(separator: "\n")
        //logger.info("splittedProperties: \(splittedProperties)")
        for propertyStr in splittedProperties {
            let propertyStr = propertyStr.trimmingCharacters(in: CharacterSet.whitespaces)
            //logger.info("propertyStr: \(propertyStr)")
            let propName = String(propertyStr[..<propertyStr.firstIndex(of: ":")!])
            //logger.info("propName: \(propName)")
            
            if propName == propertyName {
                let propValue = String(propertyStr[propertyStr.index(propertyStr.firstIndex(of: ":")!, offsetBy: 1)...]).trimmingCharacters(in: CharacterSet.whitespaces)
                //logger.info("propValue: \(propValue)")
                return propValue
            }
        }
        
        
        return ""
    }
    
}
