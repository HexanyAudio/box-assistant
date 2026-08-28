(() => {
  const BTN_ID = "hexany-reveal-btn";
  const ROW_BTN_CLASS = "hexany-row-reveal";
  const ACTIONS_CELL = '[data-testid="actions-cell"]';
  const ROW_SELECTOR = ".ReactVirtualized__Table__row, [role='row']";

  // Finder-style mark: split rectangle with a face. Drawn as line art to match
  // Box's other row icons — not Apple's actual asset.
  // Eye radius and stroke weight are tuned for 16px: at the original 0.9 radius
  // the pupils fell below a pixel and smeared into the divider.
  const ICON = `<svg viewBox="0 0 20 20" width="16" height="16" fill="none"
      stroke="currentColor" stroke-width="1.35" stroke-linecap="round"
      stroke-linejoin="round" aria-hidden="true" focusable="false">
    <rect x="2.6" y="3.6" width="14.8" height="12.8" rx="2.6"/>
    <path d="M10 3.6v12.8"/>
    <circle cx="6.7" cy="8.4" r="1.15" fill="currentColor" stroke="none"/>
    <circle cx="13.3" cy="8.4" r="1.15" fill="currentColor" stroke="none"/>
    <path d="M6.6 12.1c2 1.7 4.8 1.7 6.8 0"/>
  </svg>`;

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

  /** Identify a listed item from its name link, which carries the real ID. */
  function itemFromRow(row) {
    const link = row.querySelector('a[href*="/folder/"], a[href*="/file/"]');
    const m = link?.getAttribute("href")?.match(/\/(folder|file)\/(\d+)/);
    return m ? { type: m[1], id: m[2] } : null;
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

  function revealItem(item) {
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

  // MARK: - Header button (current folder/file page)

  function makeHeaderButton() {
    const btn = document.createElement("button");
    btn.id = BTN_ID;
    btn.type = "button";
    btn.className = "hexany-reveal-btn";
    btn.title = "Reveal in Finder (⌘⇧F)";
    btn.textContent = "Reveal in Finder";
    btn.addEventListener("click", (e) => {
      e.preventDefault();
      e.stopPropagation();
      revealItem(currentItem());
    });
    return btn;
  }

  function renderHeader() {
    const existing = document.getElementById(BTN_ID);
    const item = currentItem();

    if (!item || item.shared) {
      existing?.remove();
      return;
    }
    if (existing?.isConnected) return;
    existing?.remove();

    const btn = makeHeaderButton();
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

  // MARK: - Per-row button (folder listing)

  function injectRowButton(cell) {
    if (!cell || cell.querySelector("." + ROW_BTN_CLASS)) return;
    const row = cell.closest(ROW_SELECTOR);
    const item = row && itemFromRow(row);
    if (!item) return;

    const btn = document.createElement("button");
    btn.type = "button";
    // Adopt a neighbouring action button's classes so we inherit Box's own icon
    // styling. Those class names carry a per-build hash, so they are copied at
    // runtime and never used as selectors.
    const sibling = [...cell.querySelectorAll("button")].find((b) =>
      /iconButton/.test(b.className || "")
    );
    btn.className = `${sibling?.className ?? ""} ${ROW_BTN_CLASS}`.trim();
    btn.setAttribute("aria-label", "Show in Finder");
    btn.title = "Show in Finder";
    btn.innerHTML = ICON;
    btn.addEventListener("click", (e) => {
      e.preventDefault();
      e.stopPropagation(); // don't let the row treat this as a navigation click
      revealItem(item);
    });

    cell.prepend(btn);
  }

  function sweepRows(root = document) {
    root.querySelectorAll?.(ACTIONS_CELL).forEach(injectRowButton);
  }

  // The action buttons only exist while a row is hovered, and the list is
  // virtualized so rows are recycled constantly. Injecting on hover matches that
  // lifecycle exactly and avoids observing the whole document. The cell is often
  // mounted a frame or two after the pointer arrives, hence the short retries.
  document.addEventListener(
    "mouseover",
    (e) => {
      const row = e.target instanceof Element && e.target.closest(ROW_SELECTOR);
      if (!row) return;
      sweepRows(row);
      requestAnimationFrame(() => sweepRows(row));
      setTimeout(() => sweepRows(row), 80);
    },
    true
  );

  // MARK: - Wiring

  chrome.runtime.onMessage.addListener((msg) => {
    if (msg?.cmd === "reveal-current") revealItem(currentItem());
  });

  // Box is a single-page app: the URL changes without a reload, and the header is
  // re-rendered underneath us. Watch both.
  for (const method of ["pushState", "replaceState"]) {
    const original = history[method];
    history[method] = function (...args) {
      const result = original.apply(this, args);
      queueMicrotask(renderHeader);
      return result;
    };
  }
  window.addEventListener("popstate", renderHeader);

  let lastUrl = location.href;
  setInterval(() => {
    if (location.href !== lastUrl) {
      lastUrl = location.href;
      renderHeader();
    } else if (currentItem() && !document.getElementById(BTN_ID)?.isConnected) {
      renderHeader(); // header re-rendered and dropped our button
    }
  }, 700);

  renderHeader();
})();
