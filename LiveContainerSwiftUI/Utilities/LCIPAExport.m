//
//  LCIPAExport.m
//  LiveContainerSwiftUI
//

#import "LCIPAExport.h"
#import "LCUtils.h"

#include <errno.h>
#include <fcntl.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>
#include <mach-o/loader.h>

#include "archive.h"
#include "archive_entry.h"

// Load commands LiveContainer writes in place of ones it turns off (see LCPatchExecSlice).
#define LC_DISABLED_TWEAKLOADER_COMMAND 0x114514
#define LC_DISABLED_DUPLICATE_DYLIB_COMMAND 0x114515

static const char *LCTweakLoaderPath = "@loader_path/../../Tweaks/TweakLoader.dylib";

static void LCRemoveLoadCommand(struct mach_header_64 *header, struct load_command *command) {
    uint8_t *commandsEnd = (uint8_t *)header + sizeof(struct mach_header_64) + header->sizeofcmds;
    uint32_t size = command->cmdsize;
    uint8_t *next = (uint8_t *)command + size;
    memmove(command, next, commandsEnd - next);
    memset(commandsEnd - size, 0, size);
    header->ncmds -= 1;
    header->sizeofcmds -= size;
}

// Undoes LCPatchExecSlice on one 64-bit slice.
static void LCUnpatchExecSlice(struct mach_header_64 *header) {
    if (header->magic != MH_MAGIC_64 || header->filetype != MH_DYLIB) {
        return;
    }

    bool hasDylinker = false;
    struct load_command *command = (struct load_command *)((uint8_t *)header + sizeof(struct mach_header_64));
    for (uint32_t i = 0; i < header->ncmds; i++) {
        if (command->cmd == LC_LOAD_DYLINKER) {
            hasDylinker = true;
        }
        command = (struct load_command *)((uint8_t *)command + command->cmdsize);
    }

    command = (struct load_command *)((uint8_t *)header + sizeof(struct mach_header_64));
    uint32_t index = 0;
    while (index < header->ncmds) {
        bool remove = false;
        switch (command->cmd) {
            case LC_ID_DYLIB: {
                uint32_t size = command->cmdsize;
                if (!hasDylinker && size >= sizeof(struct dylinker_command) + 16) {
                    // LiveContainer used the space of the dyld load command for LC_ID_DYLIB
                    // when there was no room for another command; put the dyld command back.
                    memset((uint8_t *)command + 8, 0, size - 8);
                    struct dylinker_command *dylinker = (struct dylinker_command *)command;
                    dylinker->cmd = LC_LOAD_DYLINKER;
                    dylinker->name.offset = sizeof(struct dylinker_command);
                    strncpy((char *)dylinker + dylinker->name.offset, "/usr/lib/dyld", size - sizeof(struct dylinker_command) - 1);
                    hasDylinker = true;
                } else {
                    remove = true;
                }
                break;
            }
            case LC_LOAD_DYLIB: {
                struct dylib_command *dylib = (struct dylib_command *)command;
                const char *name = (const char *)dylib + dylib->dylib.name.offset;
                if (strncmp(name, LCTweakLoaderPath, strlen(LCTweakLoaderPath)) == 0) {
                    remove = true;
                }
                break;
            }
            case LC_DISABLED_TWEAKLOADER_COMMAND:
            case LC_DISABLED_DUPLICATE_DYLIB_COMMAND:
                remove = true;
                break;
            case LC_SEGMENT_64: {
                struct segment_command_64 *segment = (struct segment_command_64 *)command;
                if (strncmp(segment->segname, "__PAGEZERO", sizeof(segment->segname)) == 0 &&
                    segment->vmaddr == 0x100000000 - 0x4000 && segment->vmsize == 0x4000) {
                    segment->vmaddr = 0;
                    segment->vmsize = 0x100000000;
                }
                break;
            }
            default:
                break;
        }
        if (remove) {
            // The next command has moved into this one's place.
            LCRemoveLoadCommand(header, command);
        } else {
            command = (struct load_command *)((uint8_t *)command + command->cmdsize);
            index++;
        }
    }

    header->filetype = MH_EXECUTE;
    header->flags &= ~MH_NO_REEXPORTED_DYLIBS;
    header->flags |= MH_PIE;
}

NSString *LCUnpatchExecutable(NSString *path) {
    if (![NSFileManager.defaultManager fileExistsAtPath:path]) {
        return [NSString stringWithFormat:@"%@ not found", path.lastPathComponent];
    }
    return LCParseMachO(path.fileSystemRepresentation, false, ^(const char *slicePath, struct mach_header_64 *header, int fd, void *filePtr) {
        if (header->cputype == CPU_TYPE_ARM64) {
            LCUnpatchExecSlice(header);
        }
    });
}

static NSString *LCArchiveError(struct archive *archive, NSString *fallback) {
    const char *message = archive_error_string(archive);
    return message ? [NSString stringWithUTF8String:message] : fallback;
}

NSString *LCWriteZipArchive(NSString *folderPath, NSString *outputPath, NSProgress *progress) {
    NSFileManager *fm = NSFileManager.defaultManager;
    NSError *listError = nil;
    NSArray<NSString *> *items = [fm subpathsOfDirectoryAtPath:folderPath error:&listError];
    if (!items) {
        return listError.localizedDescription ?: @"Couldn't read the folder to archive";
    }
    // Parents before what's in them.
    items = [items sortedArrayUsingSelector:@selector(compare:)];

    int64_t totalBytes = 0;
    for (NSString *item in items) {
        struct stat st;
        NSString *fullPath = [folderPath stringByAppendingPathComponent:item];
        if (lstat(fullPath.fileSystemRepresentation, &st) == 0 && S_ISREG(st.st_mode)) {
            totalBytes += st.st_size;
        }
    }
    progress.totalUnitCount = MAX(totalBytes, 1);
    progress.completedUnitCount = 0;

    struct archive *archive = archive_write_new();
    archive_write_set_format_zip(archive);
    if (archive_write_open_filename(archive, outputPath.fileSystemRepresentation) != ARCHIVE_OK) {
        NSString *error = LCArchiveError(archive, @"Couldn't create the archive");
        archive_write_free(archive);
        return error;
    }

    const size_t bufferSize = 1 << 20;
    char *buffer = malloc(bufferSize);
    NSString *error = buffer ? nil : @"Out of memory";

    for (NSString *item in items) {
        if (error) {
            break;
        }
        if (progress.cancelled) {
            error = @"Cancelled";
            break;
        }
        NSString *fullPath = [folderPath stringByAppendingPathComponent:item];
        struct stat st;
        if (lstat(fullPath.fileSystemRepresentation, &st) != 0) {
            continue;
        }

        struct archive_entry *entry = archive_entry_new();
        archive_entry_set_pathname(entry, item.UTF8String);
        archive_entry_set_perm(entry, st.st_mode & 07777);
        archive_entry_set_mtime(entry, st.st_mtime, 0);

        int fd = -1;
        if (S_ISDIR(st.st_mode)) {
            archive_entry_set_filetype(entry, AE_IFDIR);
            archive_entry_set_size(entry, 0);
        } else if (S_ISLNK(st.st_mode)) {
            NSString *target = [fm destinationOfSymbolicLinkAtPath:fullPath error:nil];
            if (!target) {
                archive_entry_free(entry);
                continue;
            }
            archive_entry_set_filetype(entry, AE_IFLNK);
            archive_entry_set_symlink(entry, target.fileSystemRepresentation);
            archive_entry_set_size(entry, 0);
        } else if (S_ISREG(st.st_mode)) {
            fd = open(fullPath.fileSystemRepresentation, O_RDONLY);
            if (fd < 0) {
                error = [NSString stringWithFormat:@"Couldn't read %@: %s", item, strerror(errno)];
                archive_entry_free(entry);
                break;
            }
            archive_entry_set_filetype(entry, AE_IFREG);
            archive_entry_set_size(entry, st.st_size);
        } else {
            archive_entry_free(entry);
            continue;
        }

        if (archive_write_header(archive, entry) < ARCHIVE_WARN) {
            error = LCArchiveError(archive, @"Couldn't add a file to the archive");
        } else if (fd >= 0) {
            ssize_t count;
            while ((count = read(fd, buffer, bufferSize)) > 0) {
                if (archive_write_data(archive, buffer, (size_t)count) < 0) {
                    error = LCArchiveError(archive, @"Couldn't write the archive");
                    break;
                }
                progress.completedUnitCount += count;
                if (progress.cancelled) {
                    error = @"Cancelled";
                    break;
                }
            }
            if (count < 0 && !error) {
                error = [NSString stringWithFormat:@"Couldn't read %@: %s", item, strerror(errno)];
            }
        }
        if (fd >= 0) {
            close(fd);
        }
        archive_entry_free(entry);
    }

    free(buffer);
    if (archive_write_close(archive) != ARCHIVE_OK && !error) {
        error = LCArchiveError(archive, @"Couldn't finish the archive");
    }
    archive_write_free(archive);
    if (error) {
        [fm removeItemAtPath:outputPath error:nil];
    }
    return error;
}
