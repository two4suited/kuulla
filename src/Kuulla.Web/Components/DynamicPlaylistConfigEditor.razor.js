// Native HTML5 drag-and-drop, mirroring PlaylistDetail.razor.js's pattern — but unlike episode
// items (whose Order is a server-assigned rank string, updated one insert-between-neighbors call
// at a time), PriorityList is a plain array edited wholesale (see DynamicPlaylistConfig's doc
// comment), so a drop just reports the full reordered id list rather than a before/after pair.
export function attach(dotNetRef, listEl) {
    let draggedId = null;

    const onDragStart = (event) => {
        const li = event.target.closest("[data-show-id]");
        if (!li) {
            return;
        }
        draggedId = li.dataset.showId;
        event.dataTransfer.effectAllowed = "move";
    };

    const onDragOver = (event) => {
        if (event.target.closest("[data-show-id]")) {
            event.preventDefault();
        }
    };

    const onDrop = (event) => {
        const targetLi = event.target.closest("[data-show-id]");
        if (!targetLi || draggedId === null) {
            return;
        }
        event.preventDefault();

        const targetId = targetLi.dataset.showId;
        if (targetId === draggedId) {
            draggedId = null;
            return;
        }

        const remaining = Array.from(listEl.querySelectorAll("[data-show-id]"))
            .map((el) => el.dataset.showId)
            .filter((id) => id !== draggedId);
        const targetIndex = remaining.indexOf(targetId);
        const rect = targetLi.getBoundingClientRect();
        const dropAfterTarget = event.clientY - rect.top > rect.height / 2;
        remaining.splice(dropAfterTarget ? targetIndex + 1 : targetIndex, 0, draggedId);

        dotNetRef.invokeMethodAsync("OnReorderedAsync", remaining);
        draggedId = null;
    };

    listEl.addEventListener("dragstart", onDragStart);
    listEl.addEventListener("dragover", onDragOver);
    listEl.addEventListener("drop", onDrop);

    return {
        dispose() {
            listEl.removeEventListener("dragstart", onDragStart);
            listEl.removeEventListener("dragover", onDragOver);
            listEl.removeEventListener("drop", onDrop);
        },
    };
}
