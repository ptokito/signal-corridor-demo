// Client-side behavior for the Operations Portal.
//
// 1. Auto-refresh: the corridor overview reloads every 30 seconds, the way a
//    traffic operations center wall display would. Each reload is a real page
//    view for New Relic Browser.
// 2. A deliberate JavaScript bug: on intersection pages, the "map preview" widget
//    references a library that was never loaded. Browser monitoring captures the
//    error with its stack trace, which is useful in the demo to show front-end
//    errors that never reach the server.
document.addEventListener("DOMContentLoaded", function () {
  if (document.getElementById("corridor")) {
    setTimeout(function () { window.location.reload(); }, 30000);
  }
  if (document.getElementById("plan") && Math.random() < 0.25) {
    setTimeout(function () {
      var mapPreview = window.CorridorMap; // never defined: deliberate bug
      mapPreview.render("#plan");
    }, 300);
  }
});
