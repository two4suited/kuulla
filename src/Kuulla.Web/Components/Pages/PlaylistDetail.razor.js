// Native HTML5 drag-and-drop (no library) — each list item is draggable="true" and carries a
// data-episode-id attribute (set in PlaylistDetail.razor). Dropping computes the dropped-on
// item's neighbors and hands them to the server's existing "insert between these two neighbors"
// contract (PUT .../items/{episodeId}/order), so the client never invents its own rank string.
export function attach(dotNetRef, listEl) {
    let draggedId = null;

    const onDragStart = (event) => {
        const li = event.target.closest("[data-episode-id]");
        if (!li) {
            return;
        }
        draggedId = li.dataset.episodeId;
        event.dataTransfer.effectAllowed = "move";
    };

    const onDragOver = (event) => {
        if (event.target.closest("[data-episode-id]")) {
            event.preventDefault();
        }
    };

    const onDrop = (event) => {
        const targetLi = event.target.closest("[data-episode-id]");
        if (!targetLi || draggedId === null) {
            return;
        }
        event.preventDefault();

        const targetId = targetLi.dataset.episodeId;
        if (targetId === draggedId) {
            draggedId = null;
            return;
        }

        // Exclude the dragged item itself from neighbor computation — it's still in its old DOM
        // position until Blazor re-renders after the server responds, so leaving it in would let
        // it be picked as its own neighbor when dropped next to where it started.
        const items = Array.from(listEl.querySelectorAll("[data-episode-id]"))
            .filter((el) => el.dataset.episodeId !== draggedId);
        const targetIndex = items.indexOf(targetLi);
        const rect = targetLi.getBoundingClientRect();
        const dropAfterTarget = event.clientY - rect.top > rect.height / 2;

        let beforeId = null;
        let afterId = null;
        if (dropAfterTarget) {
            beforeId = targetId;
            afterId = items[targetIndex + 1]?.dataset.episodeId ?? null;
        } else {
            afterId = targetId;
            beforeId = items[targetIndex - 1]?.dataset.episodeId ?? null;
        }

        dotNetRef.invokeMethodAsync("OnReorderedAsync", draggedId, beforeId, afterId);
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
