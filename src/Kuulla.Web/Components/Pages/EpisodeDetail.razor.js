const PROGRESS_INTERVAL_SECONDS = 15;

export function attach(dotNetRef, audioEl, initialPositionSeconds) {
    let lastReported = 0;

    const onLoadedMetadata = () => {
        if (initialPositionSeconds > 0 && initialPositionSeconds < (audioEl.duration || Infinity)) {
            audioEl.currentTime = initialPositionSeconds;
        }
        lastReported = initialPositionSeconds;
    };

    const onTimeUpdate = () => {
        const now = audioEl.currentTime;
        if (now - lastReported >= PROGRESS_INTERVAL_SECONDS) {
            lastReported = now;
            dotNetRef.invokeMethodAsync("OnPlaybackProgress", Math.floor(now));
        }
    };

    const onPause = () => {
        dotNetRef.invokeMethodAsync("OnPlaybackProgress", Math.floor(audioEl.currentTime));
    };

    const onEnded = () => {
        dotNetRef.invokeMethodAsync("OnPlaybackEnded", Math.floor(audioEl.duration || audioEl.currentTime));
    };

    audioEl.addEventListener("loadedmetadata", onLoadedMetadata);
    audioEl.addEventListener("timeupdate", onTimeUpdate);
    audioEl.addEventListener("pause", onPause);
    audioEl.addEventListener("ended", onEnded);

    return {
        dispose() {
            audioEl.removeEventListener("loadedmetadata", onLoadedMetadata);
            audioEl.removeEventListener("timeupdate", onTimeUpdate);
            audioEl.removeEventListener("pause", onPause);
            audioEl.removeEventListener("ended", onEnded);
        },
    };
}
