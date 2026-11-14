#include "vt_lowlatency.h"

#import <Foundation/Foundation.h>
#import <VideoToolbox/VideoToolbox.h>

#include <mach-o/dyld.h>
#include <mach-o/loader.h>
#include <mach/mach.h>
#include <dlfcn.h>
#include <string.h>

#include <atomic>
#include <mutex>

#include "SDL_compat.h"

typedef OSStatus (*VtCreateFn)(CFAllocatorRef,
                               CMVideoFormatDescriptionRef,
                               CFDictionaryRef,
                               CFDictionaryRef,
                               const VTDecompressionOutputCallbackRecord*,
                               VTDecompressionSessionRef*);
typedef void (*VtInvalidateFn)(VTDecompressionSessionRef);

static VtCreateFn s_RealCreate;
static VtInvalidateFn s_RealInvalidate;

static std::mutex s_Lock;
static VTDecompressionSessionRef s_Session; // Not retained; cleared on invalidate
static std::atomic<bool> s_RealTime { true };
static std::atomic<bool> s_Installed { false };
static std::once_flag s_InstallOnce;

static void applyRealTime(VTDecompressionSessionRef session, bool enabled)
{
    OSStatus status = VTSessionSetProperty(session,
                                           kVTDecompressionPropertyKey_RealTime,
                                           enabled ? kCFBooleanTrue : kCFBooleanFalse);
    SDL_LogInfo(SDL_LOG_CATEGORY_APPLICATION,
                "[lowlatency] VT RealTime=%d -> status %d",
                enabled ? 1 : 0, (int)status);
}

static OSStatus hookedCreate(CFAllocatorRef allocator,
                             CMVideoFormatDescriptionRef format,
                             CFDictionaryRef decoderSpec,
                             CFDictionaryRef imageBufferAttrs,
                             const VTDecompressionOutputCallbackRecord* callback,
                             VTDecompressionSessionRef* sessionOut)
{
    OSStatus status = s_RealCreate(allocator, format, decoderSpec, imageBufferAttrs, callback, sessionOut);
    if (status == noErr && sessionOut != nullptr && *sessionOut != nullptr) {
        std::lock_guard<std::mutex> guard(s_Lock);
        s_Session = *sessionOut;
        applyRealTime(s_Session, s_RealTime);
    }
    return status;
}

static void hookedInvalidate(VTDecompressionSessionRef session)
{
    {
        std::lock_guard<std::mutex> guard(s_Lock);
        if (s_Session == session) {
            s_Session = nullptr;
        }
    }
    s_RealInvalidate(session);
}

// Replace every symbol pointer in the image that currently points at 'target'.
// With chained fixups (macOS 12+ deployment targets) all imports are bound at
// load time, so the resolved address is already sitting in __got.
static int patchImage(const struct mach_header* header, intptr_t slide, void* target, void* replacement)
{
    if (header->magic != MH_MAGIC_64) {
        return 0;
    }

    int patched = 0;
    const struct mach_header_64* mh = (const struct mach_header_64*)header;
    const uint8_t* cmdPtr = (const uint8_t*)(mh + 1);

    for (uint32_t i = 0; i < mh->ncmds; i++) {
        const struct load_command* lc = (const struct load_command*)cmdPtr;
        if (lc->cmd == LC_SEGMENT_64) {
            const struct segment_command_64* seg = (const struct segment_command_64*)lc;
            if (strncmp(seg->segname, "__DATA", 6) == 0) {
                const struct section_64* sect = (const struct section_64*)(seg + 1);
                for (uint32_t j = 0; j < seg->nsects; j++, sect++) {
                    uint32_t type = sect->flags & SECTION_TYPE;
                    if (type != S_NON_LAZY_SYMBOL_POINTERS && type != S_LAZY_SYMBOL_POINTERS) {
                        continue;
                    }

                    void** ptrs = (void**)(sect->addr + slide);
                    size_t count = sect->size / sizeof(void*);
                    for (size_t k = 0; k < count; k++) {
                        if (ptrs[k] != target) {
                            continue;
                        }

                        vm_address_t page = (vm_address_t)&ptrs[k] & ~((vm_address_t)vm_page_size - 1);
                        kern_return_t kr = vm_protect(mach_task_self(), page, vm_page_size, false,
                                                      VM_PROT_READ | VM_PROT_WRITE | VM_PROT_COPY);
                        if (kr != KERN_SUCCESS) {
                            SDL_LogWarn(SDL_LOG_CATEGORY_APPLICATION,
                                        "[lowlatency] vm_protect() failed: %d", kr);
                            continue;
                        }

                        ptrs[k] = replacement;
                        patched++;
                    }
                }
            }
        }
        cmdPtr += lc->cmdsize;
    }

    return patched;
}

static void doInstall()
{
    s_RealCreate = (VtCreateFn)dlsym(RTLD_DEFAULT, "VTDecompressionSessionCreate");
    s_RealInvalidate = (VtInvalidateFn)dlsym(RTLD_DEFAULT, "VTDecompressionSessionInvalidate");
    if (s_RealCreate == nullptr || s_RealInvalidate == nullptr) {
        SDL_LogWarn(SDL_LOG_CATEGORY_APPLICATION,
                    "[lowlatency] Unable to resolve VideoToolbox functions");
        return;
    }

    int createPatched = 0, invalidatePatched = 0;
    uint32_t imageCount = _dyld_image_count();
    for (uint32_t i = 0; i < imageCount; i++) {
        const char* name = _dyld_get_image_name(i);
        if (name == nullptr || strstr(name, "libavcodec") == nullptr) {
            continue;
        }

        const struct mach_header* header = _dyld_get_image_header(i);
        intptr_t slide = _dyld_get_image_vmaddr_slide(i);
        createPatched += patchImage(header, slide, (void*)s_RealCreate, (void*)hookedCreate);
        invalidatePatched += patchImage(header, slide, (void*)s_RealInvalidate, (void*)hookedInvalidate);

        SDL_LogInfo(SDL_LOG_CATEGORY_APPLICATION,
                    "[lowlatency] Patched %s: create=%d invalidate=%d",
                    name, createPatched, invalidatePatched);
    }

    // Only consider the hook active if both imports were redirected. Otherwise we
    // could hold a dangling session pointer after FFmpeg invalidates it.
    if (createPatched > 0 && invalidatePatched > 0) {
        s_Installed = true;
    }
    else if (createPatched > 0) {
        SDL_LogWarn(SDL_LOG_CATEGORY_APPLICATION,
                    "[lowlatency] Invalidate import not found; session toggling disabled");
        s_Installed = true;
        s_RealInvalidate = nullptr;
    }
    else {
        SDL_LogWarn(SDL_LOG_CATEGORY_APPLICATION,
                    "[lowlatency] VTDecompressionSessionCreate import not found in libavcodec");
    }
}

namespace VtLowLatency {

void installHook()
{
    std::call_once(s_InstallOnce, doInstall);
}

bool isHookInstalled()
{
    return s_Installed;
}

bool hasSession()
{
    std::lock_guard<std::mutex> guard(s_Lock);
    return s_Session != nullptr;
}

bool isRealTimeEnabled()
{
    return s_RealTime;
}

void toggleRealTime()
{
    bool enabled = !s_RealTime;
    s_RealTime = enabled;

    // Without the invalidate hook we can't know if the session is still alive,
    // so the new value only applies to the next session.
    if (s_RealInvalidate == nullptr) {
        return;
    }

    std::lock_guard<std::mutex> guard(s_Lock);
    if (s_Session != nullptr) {
        applyRealTime(s_Session, enabled);
    }
}

}
