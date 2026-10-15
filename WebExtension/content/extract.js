// Injected into the page after vendor/Readability.js. Evaluates to what Dead Center should read:
// the selection if there is one, otherwise the article (or, failing that, the page's visible text),
// or null when the page has nothing readable in its DOM.

(() => {
  const LIMIT = 8 * 1024 * 1024;
  const cap = (text) => (text && text.length > LIMIT ? text.slice(0, LIMIT) : text);
  const fit = (html) => (html && html.length <= LIMIT ? html : undefined);

  const found = selection() ?? article();
  return found && { title: document.title, url: location.href, arc: isArc(), ...found };

  function selection() {
    const field = document.activeElement;
    try {
      if (field && typeof field.value === "string" && field.selectionEnd > field.selectionStart) {
        const text = field.value.slice(field.selectionStart, field.selectionEnd);
        if (text.trim()) return { kind: "selection", text: cap(text) };
      }
    } catch {
      // Inputs like type=email throw on selectionStart.
    }

    const current = window.getSelection();
    if (!current || current.isCollapsed || current.rangeCount === 0) return null;
    const text = current.toString();
    if (!text.trim()) return null;
    const container = document.createElement("div");
    for (let i = 0; i < current.rangeCount; i++) container.append(current.getRangeAt(i).cloneContents());
    return { kind: "selection", text: cap(text), html: fit(container.innerHTML) };
  }

  function article() {
    // PDFs, images and media are better fetched by the app.
    if (!/^text\/|html|xml/.test(document.contentType)) return null;
    try {
      // Readability rewrites the document it's given, so it gets a clone of the live DOM.
      const parsed = new Readability(document.cloneNode(true)).parse();
      if (parsed?.textContent?.trim()) {
        return {
          kind: "page",
          title: parsed.title || document.title,
          html: fit(parsed.content),
          text: cap(parsed.textContent),
        };
      }
    } catch {
      // Fall through to the page text.
    }
    const text = document.body?.innerText ?? document.documentElement.textContent ?? "";
    return text.trim() ? { kind: "page", text: cap(text) } : null;
  }

  function isArc() {
    try {
      return getComputedStyle(document.documentElement).getPropertyValue("--arc-palette-title").trim() !== "";
    } catch {
      return false;
    }
  }
})();
