// Dead Center. One background script for Chrome (service worker), Firefox and Zen (event page),
// and Safari (non-persistent background page). Clicking the toolbar button, a context menu item or
// the read-page command sends the page, or the selection, to the Dead Center app.

const api = globalThis.browser ?? globalThis.chrome;

const HOST = "com.mason363.deadcenter";
const LIMIT = 8 * 1024 * 1024;
const SAFARI = api.runtime.getURL("").startsWith("safari-web-extension:");

const MENUS = [
  { id: "read-selection", title: "Read Selection in Dead Center", contexts: ["selection"] },
  { id: "read-page", title: "Read Page in Dead Center", contexts: ["page"] },
  { id: "read-link", title: "Read Link in Dead Center", contexts: ["link"] },
];

// Listeners are registered synchronously so a sleeping worker wakes up for them.

api.runtime.onInstalled.addListener(({ reason }) => {
  buildMenus();
  hello({ explainFailure: reason === "install" });
});

api.runtime.onStartup.addListener(() => {
  buildMenus();
  hello({ explainFailure: false });
});

api.action.onClicked.addListener((tab) => run(() => readTab(tab)));

api.commands?.onCommand.addListener((command, tab) => {
  if (command === "read-page") run(() => readTab(tab));
});

api.contextMenus?.onClicked.addListener((info, tab) => {
  switch (info.menuItemId) {
    case "read-selection":
      return run(() => readSelection(tab, info));
    case "read-page":
      return run(() => readTab(tab));
    case "read-link":
      return run(() => send({ kind: "page", url: info.linkUrl, title: info.linkText }));
  }
});

// The setup page's "Try Again".
api.runtime.onMessage.addListener((message, sender, sendResponse) => {
  if (message?.type !== "hello" || sender.id !== api.runtime.id) return;
  send({ kind: "hello" }, { quiet: true }).then(
    () => sendResponse({ ok: true }),
    (error) => sendResponse({ ok: false, error: String(error?.message ?? error) }),
  );
  return true;
});

// Safari may not replay onInstalled/onStartup to a reloaded background page.
if (SAFARI) buildMenus();

// Actions

async function readTab(tab) {
  tab ??= await activeTab();
  if (!tab) return;
  const found = await extract(tab.id);
  if (found) return send(found);
  // Nothing readable in the DOM, or the page can't be scripted (a PDF, a store page): let the app fetch it.
  if (/^(https?|file):/i.test(tab.url ?? "")) {
    return send({ kind: "page", title: tab.title, url: tab.url });
  }
}

async function readSelection(tab, info) {
  tab ??= await activeTab();
  const found = tab ? await extract(tab.id, info.frameId) : null;
  if (found?.kind === "selection") return send(found);
  if (!info.selectionText?.trim()) return;
  return send({ kind: "selection", title: tab?.title, url: info.pageUrl ?? tab?.url, text: info.selectionText });
}

/** Runs Readability on a clone of the live DOM (so signed-in and paywalled pages work), or reads the selection. */
async function extract(tabId, frameId) {
  const target = typeof frameId === "number" ? { tabId, frameIds: [frameId] } : { tabId };
  try {
    const [injection] = await api.scripting.executeScript({
      target,
      files: ["vendor/Readability.js", "content/extract.js"],
    });
    return injection?.result ?? null;
  } catch {
    return null;
  }
}

async function hello({ explainFailure }) {
  try {
    await send({ kind: "hello" }, { quiet: true });
  } catch (error) {
    if (explainFailure) explain(error);
  }
}

// Transport

/** Sends an `InboxPayload`-shaped message to the app. If the app can't be reached, explains why in a
 * new tab, or throws when `quiet`. */
async function send(message, { quiet = false } = {}) {
  const { arc, ...payload } = message;
  let browser = await browserName();
  if (arc && (browser === "chrome" || browser === "chromium")) browser = "arc";
  payload.browser = browser;
  payload.sentAt = new Date().toISOString().replace(/\.\d+Z$/, "Z");
  if (payload.html?.length > LIMIT) delete payload.html;
  if (payload.text?.length > LIMIT) payload.text = payload.text.slice(0, LIMIT);
  for (const key of Object.keys(payload)) if (payload[key] == null || payload[key] === "") delete payload[key];

  try {
    const reply = await api.runtime.sendNativeMessage(SAFARI ? "application.id" : HOST, payload);
    if (reply?.ok !== true) throw new Error(reply?.error ?? "Dead Center didn't answer.");
  } catch (error) {
    if (quiet) throw error;
    explain(error);
  }
}

function explain(error) {
  const detail = encodeURIComponent(String(error?.message ?? error ?? ""));
  api.tabs.create({ url: api.runtime.getURL(`pages/setup.html#${detail}`) });
}

// Helpers

function run(action) {
  action().catch((error) => console.error("Dead Center:", error));
}

async function activeTab() {
  const [tab] = await api.tabs.query({ active: true, currentWindow: true });
  return tab;
}

async function buildMenus() {
  try {
    await api.contextMenus.removeAll();
    for (const item of MENUS) api.contextMenus.create(item, () => void api.runtime.lastError);
  } catch (error) {
    console.error("Dead Center: menus", error);
  }
}

let cachedBrowserName;

/** Best-effort: chrome, edge, brave, opera, vivaldi, chromium, arc (from the page), firefox, zen, safari. */
async function browserName() {
  if (cachedBrowserName) return cachedBrowserName;
  let name = "chrome";
  if (SAFARI) {
    name = "safari";
  } else if (api.runtime.getBrowserInfo) {
    const info = await api.runtime.getBrowserInfo().catch(() => ({ name: "Firefox" }));
    const lower = info.name.toLowerCase();
    name = lower.includes("zen") ? "zen" : lower.includes("firefox") ? "firefox" : lower.replace(/[^a-z0-9]/g, "") || "firefox";
  } else {
    const brands = (navigator.userAgentData?.brands ?? []).map((b) => b.brand.toLowerCase());
    const ua = navigator.userAgent;
    const has = (word) => brands.some((brand) => brand.includes(word));
    if (has("edge") || /\bEdg\//.test(ua)) name = "edge";
    else if (has("brave") || navigator.brave) name = "brave";
    else if (has("opera") || /\bOPR\//.test(ua)) name = "opera";
    else if (has("vivaldi") || /Vivaldi/.test(ua)) name = "vivaldi";
    else if (has("google chrome")) name = "chrome";
    else if (has("chromium")) name = "chromium";
  }
  return (cachedBrowserName = name);
}
