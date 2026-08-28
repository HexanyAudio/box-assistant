(() => {
  const BTN_ID = "hexany-reveal-btn";

  // Candidate anchors in Box's folder header, best first. Box ships UI changes
  // regularly, so none of these are guaranteed — if they all miss, the button
  // falls back to a floating pill rather than disappearing.
  const ANCHORS = [
    ".ContentHeader-secondaryActions",
    ".ContentHeader .bdl-Button-group",
    "[data-testid='content-header'] [role='toolbar']",
    "[data-testid='folder-header'] [role='toolbar']",
    ".ContentHeader",
  ];

  const MESSAGES = {
    host_unavailable: "Finder helper isn't installed on this Mac.",
    box_not_running: "Box Drive isn't running.",
    no_sync_root: "Box Drive isn't set up on this Mac.",
    not_synced: "Not synced to this Mac yet — opened the closest folder.",
    not_found: "Box Drive hasn't indexed this folder yet. Try again shortly.",
    outside_root: "That path resolved outside your Box folder.",
    bad_request: "Couldn't read the item ID from this page.",
    shared_link:
      "Shared links don't include a folder ID. Open the folder from All Files instead.",
  };

  /** Identify the item from the URL. Deliberately not scraped from the DOM. */
  function currentItem() {
    const m = location.pathname.match(/^\/(folder|file)\/(\d+)/);
    if (m) return { type: m[1], id: m[2] };
    if (/^\/s\//.test(location.pathname)) return { shared: true };
    return null;
  }

  function toast(text, isError) {
    document.getElementById("hexany-reveal-toast")?.remove();
    const el = document.createElement("div");
    el.id = "hexany-reveal-toast";
    el.className = isError ? "hexany-toast hexany-toast--error" : "hexany-toast";
    el.textContent = text;
    document.body.appendChild(el);
    setTimeout(() => el.remove(), 5000);
  }

  function reveal() {
    const item = currentItem();
    if (!item) return;
    if (item.shared) {
      toast(MESSAGES.shared_link, true);
      return;
    }

    chrome.runtime.sendMessage(
      { cmd: "reveal", type: item.type, id: item.id },
      (res) => {
        if (chrome.runtime.lastError || !res) {
          toast(MESSAGES.host_unavailable, true);
          return;
        }
        // Success is silent: Finder coming to the front is the feedback.
        if (res.ok) return;
        toast(MESSAGES[res.error] || `Couldn't reveal this item (${res.error}).`, true);
      }
    );
  }

  function makeButton() {
    const btn = document.createElement("button");
    btn.id = BTN_ID;
    btn.type = "button";
    btn.className = "hexany-reveal-btn";
    btn.title = "Reveal in Finder (⌘⇧F)";
    btn.textContent = "Reveal in Finder";
    btn.addEventListener("click", (e) => {
      e.preventDefault();
      e.stopPropagation();
      reveal();
    });
    return btn;
  }

  function render() {
    const existing = document.getElementById(BTN_ID);
    const item = currentItem();

    // Only show on pages that actually have something to reveal.
    if (!item || item.shared) {
      existing?.remove();
      return;
    }
    if (existing?.isConnected) return;
    existing?.remove();

    const btn = makeButton();
    for (const sel of ANCHORS) {
      const host = document.querySelector(sel);
      if (host) {
        host.prepend(btn);
        return;
      }
    }
    // Nothing matched — float it so a Box redesign degrades placement, not function.
    btn.classList.add("hexany-reveal-btn--floating");
    document.body.appendChild(btn);
  }

  chrome.runtime.onMessage.addListener((msg) => {
    if (msg?.cmd === "reveal-current") reveal();
  });

  // Box is a single-page app: the URL changes without a reload, and the header is
  // re-rendered underneath us. Watch both.
  for (const method of ["pushState", "replaceState"]) {
    const original = history[method];
    history[method] = function (...args) {
      const result = original.apply(this, args);
      queueMicrotask(render);
      return result;
    };
  }
  window.addEventListener("popstate", render);

  let lastUrl = location.href;
  setInterval(() => {
    if (location.href !== lastUrl) {
      lastUrl = location.href;
      render();
    } else if (currentItem() && !document.getElementById(BTN_ID)?.isConnected) {
      render(); // header re-rendered and dropped our button
    }
  }, 700);

  render();
})();
