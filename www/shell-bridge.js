// Injected into the Ratify site at document start by the native shell
// (ios/App/App/ShellViewController.swift, android MainActivity.java), after Capacitor's own bridge and
// the plugin objects it exports. The site itself is not changed.
(function () {
  // iOS adds document-start scripts to every page the WebView shows, not
  // only Ratify's own; this is only for the app's pages.
  if (location.hostname !== 'ratifymusic.com') return;
  if (window.__ratifyShell) return;
  window.__ratifyShell = true;

  var cap = window.Capacitor;
  var plugin = cap && cap.Plugins && cap.Plugins.NativeMusicKit;
  if (!plugin) return;

  // The site's bridge (src/lib/nativeMusicKit.js) expects Capacitor's
  // documented addListener, which returns a Promise of a handle with
  // remove(), and only unsubscribes when it gets one. The object Capacitor's
  // iOS runtime exports for a native plugin returns the handle itself, so
  // hand the site a Promise that resolves to it (and still carries remove()
  // for any caller that expects the handle directly).
  var addListener = plugin.addListener;
  plugin.addListener = function (eventName, callback) {
    var handle = addListener.call(plugin, eventName, callback);
    var promise = Promise.resolve(handle);
    promise.remove = function () {
      return handle && handle.remove ? handle.remove() : Promise.resolve();
    };
    return promise;
  };
})();
