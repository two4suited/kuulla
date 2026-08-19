const PROGRESS_INTERVAL_SECONDS = 15;

export function attach(dotNetRef, audioEl, initialPositionSeconds) {
    let lastReported = 0;
    // The browser fires 'pause' immediately before 'ended' when playback finishes naturally —
    // once 'ended' has been observed, suppress further progress reporting (pause/timeupdate) so a
    // stale completed:false update can't be sent after the completed:true one.
    let hasEnded = false;

    const onLoadedMetadata = () => {
        if (initialPositionSeconds > 0 && initialPositionSeconds < (audioEl.duration || Infinity)) {
            audioEl.currentTime = initialPositionSeconds;
        }
        lastReported = initialPositionSeconds;
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
        if (hasEnded) {
            return;
        }
        dotNetRef.invokeMethodAsync("OnPlaybackProgress", Math.floor(audioEl.currentTime));
    };

    const onEnded = () => {
        hasEnded = true;
        dotNetRef.invokeMethodAsync("OnPlaybackEnded", Math.floor(audioEl.duration || audioEl.currentTime));
    };

    // The native controls allow replaying an ended episode without a page navigation (which would
    // otherwise reset hasEnded via a fresh attach() call) — clear it so progress reporting resumes.
    const onPlay = () => {
        hasEnded = false;
    };

    audioEl.addEventListener("loadedmetadata", onLoadedMetadata);
    audioEl.addEventListener("timeupdate", onTimeUpdate);
    audioEl.addEventListener("pause", onPause);
    audioEl.addEventListener("ended", onEnded);
    audioEl.addEventListener("play", onPlay);

    return {
        dispose() {
            audioEl.removeEventListener("loadedmetadata", onLoadedMetadata);
            audioEl.removeEventListener("timeupdate", onTimeUpdate);
            audioEl.removeEventListener("pause", onPause);
            audioEl.removeEventListener("ended", onEnded);
            audioEl.removeEventListener("play", onPlay);
        },
    };
}
