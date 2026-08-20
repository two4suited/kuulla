// Applies the persisted or system-preferred theme to <html data-bs-theme>, and exposes a
// toggle used by the sidebar's theme switch. Also inlined (minified) in App.razor's <head> so
// the theme is set before first paint; this file is the source of truth for that snippet and
// backs the interactive toggle after the page has loaded.
(function () {
    var STORAGE_KEY = "kuulla-theme";

    // Private browsing / storage-blocked browsers can throw on any localStorage access, not
    // just when full — treat that as "no stored preference" rather than breaking theme setup.
    function readStoredTheme() {
        try {
            return localStorage.getItem(STORAGE_KEY);
        } catch (e) {
            return null;
        }
    }

    function writeStoredTheme(theme) {
        try {
            localStorage.setItem(STORAGE_KEY, theme);
        } catch (e) {
            // Best-effort; the toggle still applies the theme for this page view.
        }
    }

    function systemTheme() {
        return window.matchMedia("(prefers-color-scheme: light)").matches ? "light" : "dark";
    }

    function preferredTheme() {
        var stored = readStoredTheme();
        return stored === "light" || stored === "dark" ? stored : systemTheme();
    }

    function applyTheme(theme) {
        document.documentElement.setAttribute("data-bs-theme", theme);
        var meta = document.querySelector('meta[name="theme-color"]');
        if (meta) {
            meta.setAttribute("content", theme === "dark" ? "#171A21" : "#faf9f7");
        }
        var toggle = document.querySelector(".theme-toggle");
        if (toggle) {
            toggle.setAttribute("aria-pressed", theme === "dark" ? "true" : "false");
        }
    }

    function currentTheme() {
        return document.documentElement.getAttribute("data-bs-theme") || preferredTheme();
    }

    window.kuullaTheme = {
        current: currentTheme,
        toggle: function () {
            var next = currentTheme() === "dark" ? "light" : "dark";
            writeStoredTheme(next);
            applyTheme(next);
            return next;
        },
    };

    applyTheme(preferredTheme());

    // Follow OS theme changes live, but only while the user hasn't made an explicit choice —
    // once they have, readStoredTheme() returns it and this listener becomes a no-op.
    if (window.matchMedia) {
        window.matchMedia("(prefers-color-scheme: light)").addEventListener("change", function () {
            if (readStoredTheme() === null) {
                applyTheme(systemTheme());
            }
        });
    }

    // Blazor's enhanced navigation replaces <html>'s attributes from the server-rendered
    // markup (which never includes data-bs-theme, since it's applied client-side), so the
    // theme has to be reapplied after every enhanced-nav page swap. This must go through
    // Blazor's own event bus (not document.addEventListener) — blazor.web.js dispatches
    // 'enhancedload' there, not as a plain DOM event.
    var ENHANCED_LOAD_RETRY_LIMIT = 100; // ~5s at 50ms — blazor.web.js loads moments after this script.
    var enhancedLoadRetries = 0;

    function registerEnhancedLoadHandler() {
        if (window.Blazor && typeof window.Blazor.addEventListener === "function") {
            window.Blazor.addEventListener("enhancedload", function () {
                applyTheme(preferredTheme());
            });
        } else if (enhancedLoadRetries < ENHANCED_LOAD_RETRY_LIMIT) {
            enhancedLoadRetries++;
            setTimeout(registerEnhancedLoadHandler, 50);
        }
        // If blazor.web.js never loads, there's a bigger problem than the theme not
        // re-applying after enhanced nav — give up rather than polling forever.
    }

    registerEnhancedLoadHandler();
})();
