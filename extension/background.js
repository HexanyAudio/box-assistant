const HOST_NAME = "com.hexany.boxreveal";

// The content script cannot talk to the native host directly; only the service
// worker can. This just relays and normalizes failures.
chrome.runtime.onMessage.addListener((msg, _sender, sendResponse) => {
  if (msg?.cmd !== "reveal") return;

  chrome.runtime.sendNativeMessage(
    HOST_NAME,
    { type: msg.type, id: msg.id },
    (response) => {
      if (chrome.runtime.lastError) {
        // Almost always means the helper isn't installed, or its manifest doesn't
        // list this extension's ID in allowed_origins.
        sendResponse({
          ok: false,
          error: "host_unavailable",
          detail: chrome.runtime.lastError.message,
        });
        return;
      }
      sendResponse(response);
    }
  );

  return true; // keep the channel open for the async reply
});

// Keyboard shortcut. Works even if Box changes its DOM and the button fails to
// anchor, so there is always a way to trigger a reveal.
chrome.commands.onCommand.addListener(async (command) => {
  if (command !== "reveal-in-finder") return;
  const [tab] = await chrome.tabs.query({ active: true, currentWindow: true });
  if (tab?.id) chrome.tabs.sendMessage(tab.id, { cmd: "reveal-current" }, () => {
    void chrome.runtime.lastError; // no content script on this tab; ignore
  });
});
