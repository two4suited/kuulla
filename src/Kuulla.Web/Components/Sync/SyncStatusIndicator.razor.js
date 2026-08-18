// Poll-on-focus trigger for SyncStatusIndicator (#86): calls back into .NET whenever the tab
// regains focus or becomes visible again, since that's when a device is most likely to have
// missed changes made elsewhere while it was in the background.
export function register(dotNetRef) {
    const handler = () => {
        if (document.visibilityState === "visible") {
            dotNetRef.invokeMethodAsync("OnFocusRegained");
        }
    };

    window.addEventListener("focus", handler);
    document.addEventListener("visibilitychange", handler);

    return {
        dispose() {
            window.removeEventListener("focus", handler);
            document.removeEventListener("visibilitychange", handler);
        },
    };
}
