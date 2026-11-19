//
//  LCIPAExport.h
//  LiveContainerSwiftUI
//
//  Helpers for exporting an installed app as an .ipa.
//

#import <Foundation/Foundation.h>

// LiveContainer turns an app's executable (and its extensions' executables) into a dylib so it
// can load it. This turns every arm64 slice of the file at `path` back into an executable.
// A file that isn't patched that way is left as it is. Returns nil, or what went wrong.
// Only for app and app extension executables: real dylibs and frameworks must not be passed.
NSString *LCUnpatchExecutable(NSString *path);

// Writes everything inside `folderPath` (for an .ipa, a single Payload folder) into a zip archive
// at `outputPath`, keeping permissions and symbolic links. `progress` counts bytes and stops the
// work when it's cancelled. Returns nil, or what went wrong; on failure no archive is left behind.
NSString *LCWriteZipArchive(NSString *folderPath, NSString *outputPath, NSProgress *progress);
