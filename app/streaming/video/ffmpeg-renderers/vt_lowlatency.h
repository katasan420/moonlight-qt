#pragma once

// [lowlatency] Experimental VideoToolbox decoder tuning (macOS only).
//
// FFmpeg creates the VTDecompressionSession internally and offers no way to
// set session properties on it. We redirect libavcodec's import of
// VTDecompressionSessionCreate/VTDecompressionSessionInvalidate to our own
// wrappers so we can set kVTDecompressionPropertyKey_RealTime on the session
// and toggle it at runtime (Ctrl+Alt+Shift+R) for A/B latency comparisons.

namespace VtLowLatency {
    // Idempotent. Safe to call before any decoder is created.
    void installHook();

    bool isHookInstalled();
    bool hasSession();
    bool isRealTimeEnabled();
    void toggleRealTime();
}
