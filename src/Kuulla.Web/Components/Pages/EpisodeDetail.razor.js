const PROGRESS_INTERVAL_SECONDS = 15;

// Best-effort Wi-Fi-only streaming gate (#273), mirroring iOS's AudioPlayer gate (#271). The
// Network Information API's connection.type field (distinguishing "wifi" from cellular) is only
// implemented in Chromium browsers, and even there it's not always populated — Safari and Firefox
// expose no connection object at all. Per the issue's own guidance, an unreadable connection type
// fails OPEN (playback proceeds ungated) rather than blocking playback on browsers we can't
// reliably read from.
function isStreamBlocked() {
    let wifiOnlyStreaming = false;
    try {
        wifiOnlyStreaming = localStorage.getItem("wifiOnlyStreaming") === "true";
    } catch (e) {
        return false;
    }
    if (!wifiOnlyStreaming) {
        return false;
    }

    const connection = navigator.connection || navigator.webkitConnection || navigator.mozConnection;
    if (!connection || typeof connection.type === "undefined") {
        return false;
    }

    return connection.type !== "wifi";
}

// This browser's last-known playback position for an episode, plus the server UpdatedAt it was
// last in sync with — the Web side of the cross-device resume prompt (#243). Stored per (user,
// episode) so opening one on this browser can tell "another device moved this" from "I did",
// and so a second account signed into the same browser profile can't read or clobber the first
// account's progress. Best-effort: a private window or disabled storage just means the prompt
// never fires here.
const LOCAL_PLAYBACK_PREFIX = "kuulla.ep.playback.";

function localPlaybackKey(userId, episodeId) {
    return LOCAL_PLAYBACK_PREFIX + encodeURIComponent(userId) + "." + encodeURIComponent(episodeId);
}

export function readLocalPlayback(userId, episodeId) {
    try {
        const raw = localStorage.getItem(localPlaybackKey(userId, episodeId));
        if (!raw) {
            return null;
        }
        const parsed = JSON.parse(raw);
        // `pos` must be a non-negative integer — anything else (a decimal from a hand-edited
        // entry, NaN, a string) would throw when Blazor deserializes it into `int Pos`, so treat
        // a malformed entry as "no record" rather than letting it break rendering.
        if (!Number.isInteger(parsed.pos) || parsed.pos < 0 || typeof parsed.at !== "string") {
            return null;
        }
        return { pos: parsed.pos, at: parsed.at };
    } catch (e) {
        return null;
    }
}

export function writeLocalPlayback(userId, episodeId, pos, at) {
    try {
        localStorage.setItem(localPlaybackKey(userId, episodeId), JSON.stringify({ pos, at }));
    } catch (e) {
        // No-op — storage unavailable just disables the cross-device prompt on this browser.
    }
}

// Coerces whatever Blazor passes for the playback rate into a value the media element accepts —
// a non-finite or non-positive rate (0, negative, NaN) throws when assigned to playbackRate, so
// those fall back to normal speed (#443).
function normalizePlaybackRate(rate) {
    return Number.isFinite(rate) && rate > 0 ? rate : 1.0;
}

export function attach(dotNetRef, audioEl, initialPositionSeconds, playbackRate) {
    let lastReported = 0;
    // The browser fires 'pause' immediately before 'ended' when playback finishes naturally —
    // once 'ended' has been observed, suppress further progress reporting (pause/timeupdate) so a
    // stale completed:false update can't be sent after the completed:true one.
    let hasEnded = false;

    // The user's effective playback speed (#443). Some browsers reset audioEl.playbackRate to 1.0
    // when a new source loads, so it's re-applied on 'loadedmetadata' as well as set here.
    let currentRate = normalizePlaybackRate(playbackRate);
    const applyRate = () => {
        try {
            audioEl.playbackRate = currentRate;
        } catch (e) {
            // Nothing to recover — playback just stays at the browser default rate.
        }
    };
    applyRate();

    const onLoadedMetadata = () => {
        if (initialPositionSeconds > 0 && initialPositionSeconds < (audioEl.duration || Infinity)) {
            audioEl.currentTime = initialPositionSeconds;
        }
        lastReported = initialPositionSeconds;
        applyRate();
    };

    const onTimeUpdate = () => {
        if (hasEnded) {
            return;
        }
        const now = audioEl.currentTime;
        if (now - lastReported >= PROGRESS_INTERVAL_SECONDS) {
            lastReported = now;
            dotNetRef.invokeMethodAsync("OnPlaybackProgress", Math.floor(now));
        }
    };

    const onPause = () => {
        // #244: stop polling for a cross-device takeover once this browser isn't playing.
        dotNetRef.invokeMethodAsync("OnPlaybackStateChanged", false);
        if (hasEnded) {
            return;
        }
        dotNetRef.invokeMethodAsync("OnPlaybackProgress", Math.floor(audioEl.currentTime));
    };

    const onEnded = () => {
        hasEnded = true;
        dotNetRef.invokeMethodAsync("OnPlaybackStateChanged", false);
        dotNetRef.invokeMethodAsync("OnPlaybackEnded", Math.floor(audioEl.duration || audioEl.currentTime));
    };

    // The native controls allow replaying an ended episode without a page navigation (which would
    // otherwise reset hasEnded via a fresh attach() call) — clear it so progress reporting resumes.
    const onPlay = () => {
        hasEnded = false;

        // Checked here rather than before playback starts: the native <audio controls> element
        // has no pre-play hook to intercept, so this immediately pauses what the browser just
        // started rather than truly preventing it from starting — a brief flash of "playing" in
        // the native UI is an acceptable tradeoff for a best-effort gate (see isStreamBlocked).
        if (isStreamBlocked()) {
            audioEl.pause();
            dotNetRef.invokeMethodAsync("OnStreamBlocked");
            return;
        }

        dotNetRef.invokeMethodAsync("OnStreamAllowed");
        // #244: start polling for a newer position written by another device while this plays.
        dotNetRef.invokeMethodAsync("OnPlaybackStateChanged", true);
    };

    audioEl.addEventListener("loadedmetadata", onLoadedMetadata);
    audioEl.addEventListener("timeupdate", onTimeUpdate);
    audioEl.addEventListener("pause", onPause);
    audioEl.addEventListener("ended", onEnded);
    audioEl.addEventListener("play", onPlay);

    return {
        // Changes the position the next (or in-progress) playback resumes from — used when the
        // cross-device resume prompt (#243) is answered before or during playback. Seeks
        // immediately if metadata is already loaded; otherwise onLoadedMetadata will apply it.
        setInitialPosition(seconds) {
            initialPositionSeconds = seconds;
            lastReported = seconds;
            if (audioEl.readyState >= 1 /* HAVE_METADATA */) {
                this.seekTo(seconds);
            }
        },
        // The live element time, floored — used by the #244 handoff poll so its "where this
        // browser is" comparison isn't stale between 15s progress ticks. NaN before metadata
        // loads becomes 0.
        getCurrentPositionSeconds() {
            const t = audioEl.currentTime;
            return Number.isFinite(t) ? Math.floor(t) : 0;
        },
        // Called from a chapter list click — jumps playback to that chapter's start time.
        // Best-effort: setting currentTime can throw (e.g. metadata not loaded yet, a
        // non-finite/negative value), and a chapter click isn't worth surfacing an interop error to
        // the user over — clamp to what's known to be valid and swallow anything else that throws.
        seekTo(seconds) {
            try {
                const duration = audioEl.duration;
                const clamped = Number.isFinite(duration) ? Math.min(Math.max(seconds, 0), duration) : Math.max(seconds, 0);
                audioEl.currentTime = clamped;
            } catch (e) {
                // Nothing to recover — the click simply doesn't seek.
            }
        },
        // Called from the speed selector — changes the rate of playback in progress (and any
        // that follows on this element) immediately (#443).
        setPlaybackRate(rate) {
            currentRate = normalizePlaybackRate(rate);
            applyRate();
        },
        dispose() {
            audioEl.removeEventListener("loadedmetadata", onLoadedMetadata);
            audioEl.removeEventListener("timeupdate", onTimeUpdate);
            audioEl.removeEventListener("pause", onPause);
            audioEl.removeEventListener("ended", onEnded);
            audioEl.removeEventListener("play", onPlay);
        },
    };
}
