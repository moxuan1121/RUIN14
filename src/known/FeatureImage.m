#import "FeatureImage.h"
#import "../core/StartupProfiler.h"
#import <dlfcn.h>
#import <objc/runtime.h>
#import <os/lock.h>
#import <mach-o/dyld.h>
#import <mach-o/dyld_images.h>
#import <mach/mach.h>
#include <limits.h>
#include <stdlib.h>
#include <string.h>
#include <stdatomic.h>

static _Atomic(const char *) resolutionStatus = "notAttempted";
NSString *RUINFeatureImageResolutionStatus(void) { return @(atomic_load(&resolutionStatus)); }

static BOOL CopyReadable(uintptr_t address, void *output, size_t length) {
    if (!address || !output || !length || address > UINTPTR_MAX - length) return NO;
    vm_size_t copied = 0;
    return vm_read_overwrite(mach_task_self(), (vm_address_t)address, length,
        (vm_address_t)output, &copied) == KERN_SUCCESS && copied == length;
}

// Copy first: a removed or malformed candidate must never be dereferenced while
// walking dyld's list. Loaded images are pinned before feature bytes are read.
static NSData *CopyCommands(const struct mach_header_64 *address,
    struct mach_header_64 *header, uint8_t uuid[16], BOOL *converted) {
    if (!CopyReadable((uintptr_t)address, header, sizeof(*header)) ||
        header->magic != MH_MAGIC_64 || header->cputype != CPU_TYPE_ARM64 ||
        header->cpusubtype != CPU_SUBTYPE_ARM64_ALL ||
        (header->filetype != MH_EXECUTE && header->filetype != MH_DYLIB) ||
        !header->sizeofcmds || header->sizeofcmds > 1024 * 1024 ||
        header->ncmds > header->sizeofcmds / sizeof(struct load_command) ||
        (uintptr_t)address > UINTPTR_MAX - sizeof(*header)) return nil;
    NSMutableData *data = [NSMutableData dataWithLength:header->sizeofcmds];
    if (!CopyReadable((uintptr_t)address + sizeof(*header), data.mutableBytes, data.length)) return nil;
    const uint8_t *cursor = data.bytes, *end = cursor + data.length;
    BOOL found = NO, dylibID = NO;
    for (uint32_t i = 0; i < header->ncmds; i++) {
        if ((size_t)(end - cursor) < sizeof(struct load_command)) return nil;
        const struct load_command *command = (const void *)cursor;
        if (command->cmdsize < sizeof(*command) || command->cmdsize > (size_t)(end - cursor)) return nil;
        if (command->cmd == LC_UUID) {
            if (found || command->cmdsize != sizeof(struct uuid_command)) return nil;
            memcpy(uuid, ((const struct uuid_command *)command)->uuid, 16);
            found = YES;
        } else if (command->cmd == LC_ID_DYLIB) {
            if (dylibID || command->cmdsize < sizeof(struct dylib_command)) return nil;
            const struct dylib_command *dylib = (const void *)command;
            uint32_t offset = dylib->dylib.name.offset;
            if (offset < sizeof(*dylib) || offset >= command->cmdsize ||
                !memchr(cursor + offset, 0, command->cmdsize - offset)) return nil;
            dylibID = YES;
        } else if (command->cmd == LC_SEGMENT_64 && command->cmdsize < sizeof(struct segment_command_64)) {
            return nil;
        }
        cursor += command->cmdsize;
    }
    if (!found || cursor != end) return nil;
    // LC can change the in-memory type back to MH_EXECUTE. Its conversion still
    // has an LC_ID_DYLIB, clears PIE and sets NO_REEXPORTED_DYLIBS.
    *converted = dylibID && !(header->flags & MH_PIE) && (header->flags & MH_NO_REEXPORTED_DYLIBS);
    return data;
}

BOOL RUINFeatureImageMatches(const RUINFeatureImage *image, const RUINHostIdentity *host) {
    if (!image || !host || !host->uuid) return NO;
    struct mach_header_64 header;
    uint8_t uuid[16]; BOOL converted = NO;
    if (!CopyCommands(image->image.header, &header, uuid, &converted)) return NO;
    uuid_t expected;
    NSUUID *identity = [[NSUUID alloc] initWithUUIDString:@(host->uuid)];
    if (!identity) return NO;
    [identity getUUIDBytes:expected];
    return header.filetype == image->fileType && converted == image->convertedExecutable &&
        !memcmp(uuid, expected, 16) && !memcmp(uuid, image->image.uuid, 16) &&
        header.cputype == image->image.cpuType && header.cpusubtype == image->image.cpuSubtype;
}

static char *CanonicalPath(const char *path) {
    return path && *path ? realpath(path, NULL) : NULL;
}

static BOOL MatchesCanonicalPath(const char *raw, const char *canonical, const char *candidate) {
    if (!canonical || !candidate || !*candidate) return NO;
    if ((raw && !strcmp(raw, candidate)) || !strcmp(canonical, candidate)) return YES;
    char *resolved = CanonicalPath(candidate);
    BOOL matches = resolved && !strcmp(canonical, resolved);
    free(resolved);
    return matches;
}

static BOOL SamePath(const char *left, const char *right) {
    char *canonical = CanonicalPath(left);
    BOOL same = MatchesCanonicalPath(left, canonical, right);
    free(canonical);
    return same;
}

static BOOL HeaderMatchesSlide(NSData *commands, const struct mach_header_64 *header,
    const RUINDyldImageCandidate *candidate) {
    const uint8_t *cursor = commands.bytes;
    BOOL found = NO;
    for (uint32_t i = 0; i < header->ncmds; i++) {
        const struct load_command *command = (const void *)cursor;
        if (command->cmd == LC_SEGMENT_64) {
            const struct segment_command_64 *segment = (const void *)command;
            if (!strncmp(segment->segname, "__TEXT", 16)) {
                if (found || segment->fileoff || segment->vmsize < sizeof(*header) + commands.length)
                    return NO;
                uintptr_t address = (uintptr_t)candidate->header;
                // Subtract the signed slide without overflow.
                if (candidate->slide >= 0) {
                    if (address < (uintptr_t)candidate->slide ||
                        address - (uintptr_t)candidate->slide != segment->vmaddr) return NO;
                } else {
                    uintptr_t magnitude = (uintptr_t)(-(candidate->slide + 1)) + 1;
                    if (address > UINTPTR_MAX - magnitude || address + magnitude != segment->vmaddr) return NO;
                }
                found = YES;
            }
        }
        cursor += command->cmdsize;
    }
    return found;
}

BOOL RUINResolveFeatureImageFromCandidates(const RUINHostIdentity *host,
    const char *bundleExecutable, const char *processExecutable, const char *ownerExecutable,
    const struct mach_header_64 *ownerHeader, const RUINDyldImageCandidate *candidates,
    size_t count, RUINFeatureImage *result) {
    if (!result) return NO;
    memset(result, 0, sizeof(*result));
    RUIN_PROFILE_BEGIN("resolve.fc_paths");
    char *canonicalBundle = CanonicalPath(bundleExecutable);
    BOOL pathsValid = host && ownerHeader &&
        MatchesCanonicalPath(bundleExecutable, canonicalBundle, ownerExecutable) &&
        (candidates || !count) && count <= UINT32_MAX;
    RUIN_PROFILE_END(pathsValid ? RUINProfileStatusOK : RUINProfileStatusFailed);
    if (!pathsValid) {
        free(canonicalBundle);
        return NO;
    }
    BOOL found = NO, sameProcessPath = MatchesCanonicalPath(bundleExecutable, canonicalBundle, processExecutable);
    RUIN_PROFILE_BEGIN("resolve.fc_scan");
    for (size_t i = 0; i < count; i++) {
        const RUINDyldImageCandidate *candidate = &candidates[i];
        if (!MatchesCanonicalPath(bundleExecutable, canonicalBundle, candidate->imageName)) continue;
        struct mach_header_64 header; uint8_t uuid[16]; BOOL converted = NO;
        NSData *commands = CopyCommands(candidate->header, &header, uuid, &converted);
        if (candidate->header != ownerHeader || !commands ||
            !HeaderMatchesSlide(commands, &header, candidate) ||
            ((!sameProcessPath || header.filetype == MH_DYLIB) && !converted)) goto reject;
        if (found) {
            // dyld index aliases are one image; another instance at the same
            // path is ambiguous, even when one candidate is otherwise invalid.
            if (result->image.header != candidate->header || result->image.slide != candidate->slide ||
                result->fileType != header.filetype || memcmp(result->image.uuid, uuid, 16)) goto reject;
            continue;
        }
        result->image = (RUINMainExecutableImage){.header=candidate->header,
            .slide=candidate->slide, .imageIndex=(uint32_t)i,
            .cpuType=header.cputype, .cpuSubtype=header.cpusubtype};
        memcpy(result->image.uuid, uuid, 16);
        result->fileType = header.filetype;
        result->convertedExecutable = converted;
        if (!RUINFeatureImageMatches(result, host)) goto reject;
        found = YES;
    }
    if (found) {
        free(canonicalBundle);
        RUIN_PROFILE_END(RUINProfileStatusOK);
        return YES;
    }
reject:
    free(canonicalBundle);
    RUIN_PROFILE_END(RUINProfileStatusFailed);
    memset(result, 0, sizeof(*result));
    return NO;
}

static atomic_uint_fast64_t imageGeneration;
static void ImageListChanged(const struct mach_header *header, intptr_t slide) {
    (void)header; (void)slide;
    atomic_fetch_add_explicit(&imageGeneration, 1, memory_order_relaxed);
}

static char *CopyImageName(const char *name) {
    if (!name) return NULL;
    char path[PATH_MAX];
    for (size_t offset = 0; offset < sizeof(path);) {
        uintptr_t address = (uintptr_t)name;
        if (address > UINTPTR_MAX - offset) return NULL;
        address += offset;
        size_t length = MIN((size_t)64, MIN(sizeof(path) - offset,
            (size_t)vm_page_size - address % vm_page_size));
        if (!CopyReadable(address, path + offset, length)) return NULL;
        if (memchr(path + offset, 0, length)) return strdup(path);
        offset += length;
    }
    return NULL;
}

static BOOL IsProcessMain(const void *header) {
    // LC virtualizes dyld indexes and can rewrite MH_DYLIB to MH_EXECUTE. Only
    // the kernel's process image list proves the no-dlopen, process-lifetime case.
    task_dyld_info_data_t task = {0};
    mach_msg_type_number_t count = TASK_DYLD_INFO_COUNT;
    if (task_info(mach_task_self(), TASK_DYLD_INFO, (task_info_t)&task, &count) != KERN_SUCCESS)
        return NO;
    struct { uint32_t version, count; const struct dyld_image_info *images; } info;
    struct dyld_image_info first;
    return task.all_image_info_format == TASK_DYLD_ALL_IMAGE_INFO_64 && task.all_image_info_size >= sizeof(info) &&
        CopyReadable((uintptr_t)task.all_image_info_addr, &info, sizeof(info)) &&
        info.version && info.count && info.images &&
        CopyReadable((uintptr_t)info.images, &first, sizeof(first)) && first.imageLoadAddress == header;
}

#if defined(RUIN_HOST_CHECK)
BOOL RUINFeatureImageIsProcessMainForTesting(const void *header) { return IsProcessMain(header); }
#endif

static char *CopyProcessExecutablePath(void) {
    uint32_t size = 0;
    _NSGetExecutablePath(NULL, &size);
    char *path = size && size <= 1024 * 1024 ? malloc(size) : NULL;
    if (path && !_NSGetExecutablePath(path, &size)) return path;
    free(path);
    return NULL;
}

// Cache only a successful kernel proof. The genuine process main cannot unload;
// current bundle identity, conversion shape, CPU, UUID and slide are still
// checked on every use. A miss during early initialization remains retryable.
static _Atomic(const struct mach_header_64 *) nativeProcessHeader;

BOOL RUINResolveNativeFeatureImage(const RUINHostIdentity *host, RUINFeatureImage *result) {
    if (!result) return NO;
    memset(result, 0, sizeof(*result));
    if (!host || !host->uuid) return NO;
    RUINMainExecutableImage native;
    if (!RUINResolveMainExecutableImage(&native)) return NO;
    const char *bundle = NSBundle.mainBundle.executablePath.fileSystemRepresentation;
    char *process = CopyProcessExecutablePath();
    BOOL samePath = SamePath(bundle, process);
    free(process);
    if (!samePath) return NO;

    struct mach_header_64 header;
    uint8_t uuid[16]; BOOL converted = NO;
    NSData *commands = CopyCommands(native.header, &header, uuid, &converted);
    RUINDyldImageCandidate candidate = {.header=native.header, .slide=native.slide};
    if (!commands || header.filetype != MH_EXECUTE || converted ||
        !HeaderMatchesSlide(commands, &header, &candidate)) return NO;
    RUINFeatureImage image = {.image=native, .fileType=MH_EXECUTE};
    if (!RUINFeatureImageMatches(&image, host)) return NO;
    if (atomic_load_explicit(&nativeProcessHeader, memory_order_acquire) != native.header) {
        if (!IsProcessMain(native.header)) return NO;
        atomic_store_explicit(&nativeProcessHeader, native.header, memory_order_release);
    }
    *result = image;
    return YES;
}

// Shared converted-image resolution cache. A successful full resolution is
// expensive (a guarded snapshot of every dyld image plus per-candidate path
// canonicalization), and several features resolve the same host image during
// startup. Only the discovery result is cached: a hit takes the same guarded
// name/header snapshot as the full path (never per-candidate canonicalization
// or command copies for non-matching images), confirms the stored image is
// still present at its index and unambiguous, then revalidates it through
// RUINResolveFeatureImageFromCandidates, so path identity, UUID/CPU/filetype/
// conversion shape, slide consistency and the lifetime proof are rechecked on
// every use. The cache holds no loader pin of its own: the caller's NOLOAD
// reference (obtained once per resolution) is the only lifetime proof, and a
// stale entry simply fails the live snapshot comparison. Failures are never
// cached, so an early-initialization miss stays retryable.
typedef NS_ENUM(NSInteger, RUINFeatureImageCacheOutcome) {
    RUINFeatureImageCacheMiss = 0,
    RUINFeatureImageCacheHit,
    RUINFeatureImageCacheLifetimeRejected,
};

static os_unfair_lock resolvedImageCacheLock = OS_UNFAIR_LOCK_INIT;
static BOOL resolvedImageCacheFilled;
static RUINFeatureImage resolvedImageCache;
static uint8_t resolvedImageCacheUUID[16];
static char *resolvedImageCacheName;

static BOOL CopyHostUUID(const RUINHostIdentity *host, uuid_t output) {
    if (!host || !host->uuid) return NO;
    NSUUID *identity = [[NSUUID alloc] initWithUUIDString:@(host->uuid)];
    if (!identity) return NO;
    [identity getUUIDBytes:output];
    return YES;
}

static const char *PathBasename(const char *path) {
    const char *slash = strrchr(path, '/');
    return slash ? slash + 1 : path;
}

// `reference` is owned by the caller and is never closed here. On a miss the
// caller continues with full resolution using the same reference.
static RUINFeatureImageCacheOutcome RUINResolveFeatureImageFromCache(const RUINHostIdentity *host,
    const char *bundle, const char *ownerPath, void *reference, RUINFeatureImage *result) {
    uuid_t expected;
    if (!CopyHostUUID(host, expected)) return RUINFeatureImageCacheMiss;
    RUINFeatureImage cached = {0};
    char *cachedName = NULL;
    os_unfair_lock_lock(&resolvedImageCacheLock);
    if (resolvedImageCacheFilled && !memcmp(resolvedImageCacheUUID, expected, 16)) {
        cached = resolvedImageCache;
        cachedName = resolvedImageCacheName ? strdup(resolvedImageCacheName) : NULL;
    }
    os_unfair_lock_unlock(&resolvedImageCacheLock);
    if (!cachedName) return RUINFeatureImageCacheMiss;
    RUIN_PROFILE_BEGIN("resolve.cache");
    RUINFeatureImageCacheOutcome outcome = RUINFeatureImageCacheMiss;
    uint64_t generation = atomic_load_explicit(&imageGeneration, memory_order_acquire);
    uint32_t count = _dyld_image_count();
    RUINDyldImageCandidate *candidates = count ? calloc(count, sizeof(*candidates)) : NULL;
    BOOL complete = candidates != NULL;
    for (uint32_t i = 0; complete && i < count; i++) {
        candidates[i] = (RUINDyldImageCandidate){
            .header=(const void *)_dyld_get_image_header(i), .slide=_dyld_get_image_vmaddr_slide(i),
            .imageName=CopyImageName(_dyld_get_image_name(i))};
        if (!candidates[i].imageName) complete = NO;
    }
    BOOL stable = complete && count == _dyld_image_count() &&
        generation == atomic_load_explicit(&imageGeneration, memory_order_acquire);
    uint32_t index = cached.image.imageIndex;
    char *canonicalCached = stable ? CanonicalPath(cachedName) : NULL;
    if (canonicalCached && index < count && candidates[index].header == (const void *)cached.image.header &&
        candidates[index].slide == cached.image.slide &&
        !strcmp(candidates[index].imageName, cachedName) &&
        MatchesCanonicalPath(cachedName, canonicalCached, ownerPath)) {
        // Ambiguity spot-check: no other image may share the stored path
        // (byte-identical, or canonically equal when the final component
        // matches) under a different header; same-header entries are dyld
        // index aliases of one image.
        const char *cachedBase = PathBasename(cachedName);
        BOOL unambiguous = YES;
        for (uint32_t i = 0; unambiguous && i < count; i++) {
            if (i == index || candidates[i].header == (const void *)cached.image.header) continue;
            const char *name = candidates[i].imageName;
            if (!strcmp(name, cachedName) || (!strcmp(PathBasename(name), cachedBase) &&
                MatchesCanonicalPath(cachedName, canonicalCached, name))) unambiguous = NO;
        }
        char *process = unambiguous ? CopyProcessExecutablePath() : NULL;
        if (process) {
            RUINDyldImageCandidate candidate = {.header=cached.image.header,
                .slide=cached.image.slide, .imageName=cachedName};
            if (RUINResolveFeatureImageFromCandidates(host, bundle, process,
                    ownerPath, cached.image.header, &candidate, 1, result)) {
                result->image.imageIndex = index;
                // Same lifetime rule as the full path. The candidate is the
                // proven owner image, so a rescan cannot reach another verdict.
                if (!reference && (result->convertedExecutable || !IsProcessMain(result->image.header)))
                    outcome = RUINFeatureImageCacheLifetimeRejected;
                else {
                    result->loaderReference = reference;
                    outcome = RUINFeatureImageCacheHit;
                }
            }
        }
        free(process);
    }
    free(canonicalCached);
    for (uint32_t i = 0; i < count && candidates; i++) free((void *)candidates[i].imageName);
    free(candidates);
    free(cachedName);
    if (outcome != RUINFeatureImageCacheHit) memset(result, 0, sizeof(*result));
    RUIN_PROFILE_END(outcome == RUINFeatureImageCacheHit ? RUINProfileStatusOK : RUINProfileStatusFailed);
    return outcome;
}

static void RUINCacheResolvedFeatureImage(const RUINHostIdentity *host,
    const RUINFeatureImage *image, const char *imageName) {
    uuid_t expected;
    if (!imageName || !CopyHostUUID(host, expected)) return;
    char *nameCopy = strdup(imageName);
    if (!nameCopy) return;
    os_unfair_lock_lock(&resolvedImageCacheLock);
    char *previous = resolvedImageCacheName;
    resolvedImageCache = *image;
    resolvedImageCache.loaderReference = NULL; // Callers own their pins.
    memcpy(resolvedImageCacheUUID, expected, 16);
    resolvedImageCacheName = nameCopy;
    resolvedImageCacheFilled = YES;
    os_unfair_lock_unlock(&resolvedImageCacheLock);
    free(previous);
}

BOOL RUINResolveFeatureImage(const RUINHostIdentity *host, Class nativeClass,
    RUINFeatureImage *result) {
    if (!result) return NO;
    memset(result, 0, sizeof(*result));
    // A method IMP can belong to an inspection/third-party hook. Objective-C's
    // class image identity remains the native owner after such replacement.
    const char *ownerPath = nativeClass ? class_getImageName(nativeClass) : NULL;
    const char *bundle = NSBundle.mainBundle.executablePath.fileSystemRepresentation;
    atomic_store(&resolutionStatus, "nativeClassOwnerUnavailable");
    if (!bundle || !ownerPath || !SamePath(bundle, ownerPath)) return NO;
    RUIN_PROFILE_BEGIN("resolve.native");
    BOOL native = RUINResolveNativeFeatureImage(host, result);
    RUIN_PROFILE_END(native ? RUINProfileStatusOK : RUINProfileStatusSkipped);
    if (native) {
        atomic_store(&resolutionStatus, "nativeProcessImage");
        return YES;
    }
    static dispatch_once_t observers;
    dispatch_once(&observers, ^{
        _dyld_register_func_for_add_image(ImageListChanged);
        _dyld_register_func_for_remove_image(ImageListChanged);
    });
    // NOLOAD never loads a substitute. A genuine process executable may have no
    // dlopen handle; only the kernel image-list proof permits that lifetime case.
    // The single reference serves both the cache probe and full resolution.
    void *reference = dlopen(bundle, RTLD_LAZY | RTLD_NOLOAD);
    RUINFeatureImageCacheOutcome cacheOutcome =
        RUINResolveFeatureImageFromCache(host, bundle, ownerPath, reference, result);
    if (cacheOutcome == RUINFeatureImageCacheHit) {
        atomic_store(&resolutionStatus, "resolvedCached");
        return YES;
    }
    if (cacheOutcome == RUINFeatureImageCacheLifetimeRejected) {
        if (reference) dlclose(reference);
        atomic_store(&resolutionStatus, "imageLifetimeUnproven");
        return NO;
    }
    char *process = CopyProcessExecutablePath();
    RUIN_PROFILE_BEGIN("resolve.snapshot");
    uint64_t generation = atomic_load_explicit(&imageGeneration, memory_order_acquire);
    uint32_t count = _dyld_image_count();
    RUINDyldImageCandidate *candidates = count ? calloc(count, sizeof(*candidates)) : NULL;
    BOOL complete = process && candidates;
    const struct mach_header_64 *ownerHeader = NULL;
    char *canonicalOwner = CanonicalPath(ownerPath);
    for (uint32_t i = 0; complete && i < count; i++) {
        candidates[i] = (RUINDyldImageCandidate){
            .header=(const void *)_dyld_get_image_header(i), .slide=_dyld_get_image_vmaddr_slide(i),
            .imageName=CopyImageName(_dyld_get_image_name(i))};
        if (!candidates[i].imageName) complete = NO;
        else if (!ownerHeader && MatchesCanonicalPath(ownerPath, canonicalOwner, candidates[i].imageName))
            ownerHeader = candidates[i].header;
    }
    free(canonicalOwner);
    BOOL stable = complete && count == _dyld_image_count() &&
        generation == atomic_load_explicit(&imageGeneration, memory_order_acquire);
    RUIN_PROFILE_END(stable ? RUINProfileStatusOK : RUINProfileStatusFailed);
    RUIN_PROFILE_BEGIN("resolve.from_candidates");
    BOOL resolved = stable && RUINResolveFeatureImageFromCandidates(host, bundle, process, ownerPath,
        ownerHeader, candidates, count, result);
    RUIN_PROFILE_END(resolved ? RUINProfileStatusOK : RUINProfileStatusFailed);
    char *resolvedName = NULL;
    if (resolved && result->image.imageIndex < count)
        resolvedName = strdup(candidates[result->image.imageIndex].imageName);
    for (uint32_t i = 0; i < count && candidates; i++) free((void *)candidates[i].imageName);
    free(candidates); free(process);
    atomic_store(&resolutionStatus, resolved ? "resolved" : complete ? "imageCandidateRejected" : "imageSnapshotUnavailable");
    if (resolved && !reference && (result->convertedExecutable || !IsProcessMain(result->image.header))) {
        atomic_store(&resolutionStatus, "imageLifetimeUnproven");
        resolved = NO;
    }
    if (!resolved) {
        if (reference) dlclose(reference);
        free(resolvedName);
        memset(result, 0, sizeof(*result));
        return NO;
    }
    result->loaderReference = reference;
    RUINCacheResolvedFeatureImage(host, result, resolvedName);
    free(resolvedName);
    return YES;
}

void RUINReleaseFeatureImage(RUINFeatureImage *image) {
    if (!image) return;
    if (image->loaderReference) dlclose(image->loaderReference);
    memset(image, 0, sizeof(*image));
}

BOOL RUINReadFeatureImageBytes(const RUINFeatureImage *image, uintptr_t address,
    void *output, size_t length, const char *segmentName) {
    if (!image || !output || !length || !segmentName || strlen(segmentName) > 16 ||
        address > UINTPTR_MAX - length) return NO;
    struct mach_header_64 header; uint8_t uuid[16]; BOOL converted = NO;
    NSData *commands = CopyCommands(image->image.header, &header, uuid, &converted);
    if (!commands || header.filetype != image->fileType || converted != image->convertedExecutable ||
        memcmp(uuid, image->image.uuid, 16)) return NO;
    const uint8_t *cursor = commands.bytes;
    BOOL contained = NO;
    for (uint32_t i = 0; i < header.ncmds; i++) {
        const struct load_command *command = (const void *)cursor;
        if (command->cmd == LC_SEGMENT_64) {
            const struct segment_command_64 *segment = (const void *)command;
            if (!strncmp(segment->segname, segmentName, 16) && (segment->initprot & VM_PROT_READ) &&
                address >= segment->vmaddr && address - segment->vmaddr <= segment->vmsize &&
                length <= segment->vmsize - (address - segment->vmaddr)) contained = YES;
        }
        cursor += command->cmdsize;
    }
    uintptr_t resolved;
    intptr_t slide = image->image.slide;
    if (!contained) return NO;
    if (slide >= 0) {
        if (address > UINTPTR_MAX - (uintptr_t)slide) return NO;
        resolved = address + (uintptr_t)slide;
    } else {
        uintptr_t magnitude = (uintptr_t)(-(slide + 1)) + 1;
        if (address < magnitude) return NO;
        resolved = address - magnitude;
    }
    return CopyReadable(resolved, output, length);
}

BOOL RUINVerifyFeatureInstructions(const RUINFeatureImage *image,
    const RUINInstructionAnchor *anchors, size_t count) {
    if (!anchors || !count) return NO;
    for (size_t i = 0; i < count; i++) {
        uint32_t actual[4]; const RUINInstructionAnchor *anchor = &anchors[i];
        if (!anchor->wordCount || anchor->wordCount > 4 || anchor->address % 4 ||
            !RUINReadFeatureImageBytes(image, anchor->address, actual, anchor->wordCount * 4, "__TEXT") ||
            memcmp(actual, anchor->words, anchor->wordCount * 4)) return NO;
    }
    return YES;
}
