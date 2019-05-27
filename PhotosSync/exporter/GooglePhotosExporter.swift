//
//  GooglePhotosExporter.swift
//  PhotosSync
//
//  Created by Adam Fletcher on 5/26/19.
//  Copyright © 2019 Andreas Bentele. All rights reserved.
//

import Foundation
import AppAuth


class GooglePhotosExporter : PhotosExporter {
    var currentAuthorizationFlow: OIDAuthorizationFlowSession?
    var authConfiguration: OIDServiceConfiguration?
    var authorization: GTMAppAuthFetcherAuthorization?
    var kClientSecret = "" // this doesn't need to get set, but needs to be passed to the auth methods
    var kClientID = ""
    var kAuthKey = ""
    var redirectHTTPHandler: OIDRedirectHTTPHandler?
    let home = FileManager.default.homeDirectoryForCurrentUser
    let filemgr = FileManager.default
    
    private struct googleAuth : Decodable {
        var kClientID: String
        var kAuthKey: String
    }
    var scopes = [kGTLRAuthScopePhotosLibrary]
    
    func authCallback(authState: OIDAuthState?, error: Error?) {
        if authState != nil {
            let auth: GTMAppAuthFetcherAuthorization = GTMAppAuthFetcherAuthorization.init(authState: authState!)
            self.authorization = auth
            print(authState?.lastTokenResponse?.accessToken)
            if ((self.authorization?.canAuthorize())!) {
                GTMAppAuthFetcherAuthorization.save(self.authorization!, toKeychainForName: kAuthKey)
            }
            if self.authorization != nil {
                var photosService = GTLRPhotosLibraryService.init()
                photosService.fetcherService.authorizer = self.authorization
                let query = GTLRPhotosLibraryQuery_AlbumsList.query()
               // photosService.executeQuery(query, completionHandler: albumsListCallback as! GTLRServiceCompletionHandler)
            }
        } else {
            self.authorization = nil
        }
    }
    
    private func loadJson(filename filePath: String) -> googleAuth? {
        if filemgr.fileExists(atPath: filePath) {
            print("File exists")
        } else {
            print("File not found")
            return nil
        }
        let data = filemgr.contents(atPath: filePath)!
        do {
            let decoder = JSONDecoder()
            let jsonData = try decoder.decode(googleAuth.self, from: data)
            return jsonData
        } catch {
            print("error:\(error)")
        }
        
        return nil
    }

    func albumsListCallback(ticket: GTLRServiceTicket, albums: Any?, error: Error?) {
        if error != nil {
            print(error)
        }
        var _albums: GTLRPhotosLibrary_ListAlbumsResponse? = albums as! GTLRPhotosLibrary_ListAlbumsResponse
        
        print(_albums!.albums)
    }
    
    private var subTargetPath: String {
        return "\(targetPath)/Current"
    }
    
    public var deleteFlatPath = true
    
    override func exportFoldersFlat() throws {
        if exportOriginals {
            logger.info("export originals photos to \(inProgressPath)/\(originalsRelativePath)/\(flatRelativePath) folder")
            try exportFolderFlat(
                flatPath: "\(inProgressPath)/\(originalsRelativePath)/\(flatRelativePath)",
                candidatesToLinkTo: [],
                exportOriginals: true)
            
        }
        if exportCalculated {
            logger.info("export calculated photos to \(inProgressPath)/\(calculatedRelativePath)/\(flatRelativePath) folder")
            try exportFolderFlat(
                flatPath: "\(inProgressPath)/\(calculatedRelativePath)/\(flatRelativePath)",
                candidatesToLinkTo: [FlatFolderDescriptor(folderName: "\(inProgressPath)/\(originalsRelativePath)/\(flatRelativePath)", countSubFolders: countSubFolders)],
                exportOriginals: false)
        }
    }
    
    let stopWatchLinkFile = StopWatch("fileManager.linkItem", LogLevel.info, addFileSizes: false)
    
    override func copyOrLinkFileInPhotosLibrary(sourceUrl: URL, targetUrl: URL) throws {
    }
    
    private func filesAreOnSameDevice(path1: String, path2: String) throws -> Bool {
        return false
    }
    
    /**
     * Finish the filesystem structures; invariant:
     * if no folder "InProgress" but folders with date exist, and there is a symbolic link "Latest", there was no error.
     */
    override func finishExport() throws {
        try super.finishExport()
        
        // remove the ".flat" folders
        if (deleteFlatPath) {
            try deleteFolderIfExists(atPath: "\(inProgressPath)/\(originalsRelativePath)/\(flatRelativePath)")
            try deleteFolderIfExists(atPath: "\(inProgressPath)/\(calculatedRelativePath)/\(flatRelativePath)")
        }
        
        // remove the "Current" folder
        try deleteFolderIfExists(atPath: subTargetPath)
        
        // rename "InProgress" folder to "Current"
        do {
            try fileManager.moveItem(atPath: inProgressPath, toPath: subTargetPath)
        } catch {
            logger.error("Error renaming InProgress folder: \(error) => abort export")
            throw error
        }
    }
    
    func deleteFolderIfExists(atPath path: String) throws {
    }
}
