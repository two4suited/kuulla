// Triggers a browser "Save as" for bytes produced server-side. Used by the OPML export on the
// Subscriptions page: the file is fetched from the API with the circuit's bearer token, so a
// plain <a href> straight to the API endpoint couldn't authenticate it.
window.kuullaDownloadFile = function (fileName, contentType, base64) {
    const binary = atob(base64);
    const bytes = new Uint8Array(binary.length);
    for (let i = 0; i < binary.length; i++) {
        bytes[i] = binary.charCodeAt(i);
    }

    const url = URL.createObjectURL(new Blob([bytes], { type: contentType }));
    const anchor = document.createElement("a");
    anchor.href = url;
    anchor.download = fileName;
    document.body.appendChild(anchor);
    anchor.click();
    anchor.remove();
    URL.revokeObjectURL(url);
};
