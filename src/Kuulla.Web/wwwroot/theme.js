// Applies the persisted or system-preferred theme to <html data-bs-theme>, and exposes a
// toggle used by the sidebar's theme switch. Also inlined (minified) in App.razor's <head> so
// the theme is set before first paint; this file is the source of truth for that snippet and
// backs the interactive toggle after the page has loaded.
(function () {
    var STORAGE_KEY = "kuulla-theme";

    function preferredTheme() {
        var stored = localStorage.getItem(STORAGE_KEY);
        if (stored === "light" || stored === "dark") {
            return stored;
        }
        return window.matchMedia("(prefers-color-scheme: light)").matches ? "light" : "dark";
    }

    function applyTheme(theme) {
        document.documentElement.setAttribute("data-bs-theme", theme);
        var meta = document.querySelector('meta[name="theme-color"]');
        if (meta) {
            meta.setAttribute("content", theme === "dark" ? "#171A21" : "#faf9f7");
        }
    }

    function currentTheme() {
        return document.documentElement.getAttribute("data-bs-theme") || preferredTheme();
    }

    window.kuullaTheme = {
        current: currentTheme,
        toggle: function () {
            var next = currentTheme() === "dark" ? "light" : "dark";
            localStorage.setItem(STORAGE_KEY, next);
            applyTheme(next);
            return next;
        },
    };

    applyTheme(preferredTheme());

    // Blazor's enhanced navigation replaces <html>'s attributes from the server-rendered
    // markup (which never includes data-bs-theme, since it's applied client-side), so the
    // theme has to be reapplied after every enhanced-nav page swap. This must go through
    // Blazor's own event bus (not document.addEventListener) — blazor.web.js dispatches
    // 'enhancedload' there, not as a plain DOM event.
    function registerEnhancedLoadHandler() {
        if (window.Blazor && typeof window.Blazor.addEventListener === "function") {
            window.Blazor.addEventListener("enhancedload", function () {
                applyTheme(preferredTheme());
            });
        } else {
            // blazor.web.js loads after this script; retry until it's ready.
            setTimeout(registerEnhancedLoadHandler, 50);
        }
    }

    registerEnhancedLoadHandler();
})();
