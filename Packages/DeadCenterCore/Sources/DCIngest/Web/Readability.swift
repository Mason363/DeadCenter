import Foundation
import JavaScriptCore

/// Mozilla Readability, run in JavaScriptCore on Readability's own JSDOMParser (no WebKit).
enum Readability {
    struct Article: Sendable {
        var title: String?
        var contentHTML: String
        var textLength: Int
        var siteName: String?
    }

    /// Bundled scripts plus a `URL` shim (JavaScriptCore has no URL class) and the entry point.
    private static let script: String? = {
        func load(_ name: String) -> String? {
            let url = Bundle.module.url(forResource: name, withExtension: "js", subdirectory: "Resources")
                ?? Bundle.module.url(forResource: name, withExtension: "js")
            return url.flatMap { try? String(contentsOf: $0, encoding: .utf8) }
        }
        guard let parser = load("JSDOMParser"), let readability = load("Readability") else { return nil }
        return """
        var URL = function URL(url, base) {
          var href = __dcResolveURL(String(url), (base === undefined || base === null) ? "" : String(base));
          if (!href) { throw new TypeError("Invalid URL: " + url); }
          this.href = href;
        };
        URL.prototype.toString = function () { return this.href; };
        \(parser)
        \(readability)
        function __dcExtract(html, url) {
          var doc = new JSDOMParser().parse(html, url || undefined);
          if (!doc || !doc.documentElement) { return null; }
          var article = new Readability(doc, { charThreshold: 250, maxElemsToParse: 60000, keepClasses: true }).parse();
          if (!article || !article.content) { return null; }
          return { title: article.title || "", content: article.content, length: article.length || 0,
                   siteName: article.siteName || "" };
        }
        """
    }()

    /// Extracts the article from a well-formed document (see `HTMLElement.wellFormedDocument()`).
    /// Returns nil when Readability finds nothing, fails, or takes longer than `timeout` seconds
    /// (JavaScriptCore can't be interrupted, so a runaway script is left to finish on its own thread).
    static func extract(wellFormedHTML html: String, url: URL?, timeout: TimeInterval = 10) -> Article? {
        let result = ResultBox<Article?>()
        let done = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInitiated).async {
            result.set(run(html, url: url))
            done.signal()
        }
        let deadline = Date().addingTimeInterval(timeout)
        while done.wait(timeout: .now() + .milliseconds(50)) == .timedOut {
            if Task.isCancelled || Date() >= deadline { return nil }
        }
        return result.value ?? nil
    }

    private static func run(_ html: String, url: URL?) -> Article? {
        guard let script, html.utf8.count < 8_000_000,
              let vm = JSVirtualMachine(), let context = JSContext(virtualMachine: vm) else { return nil }

        let resolve: @convention(block) (String, String) -> String = { reference, base in
            let baseURL = base.isEmpty ? nil : URL(string: base)
            guard let url = URL(string: reference, relativeTo: baseURL)?.absoluteURL, url.scheme != nil else { return "" }
            return url.absoluteString
        }
        context.setObject(resolve, forKeyedSubscript: "__dcResolveURL" as NSString)
        context.evaluateScript(script)
        guard context.exception == nil, let extract = context.objectForKeyedSubscript("__dcExtract") else { return nil }

        let result = extract.call(withArguments: [html, url?.absoluteString ?? ""])
        guard context.exception == nil, let result, result.isObject,
              let content = result.objectForKeyedSubscript("content")?.toString(), !content.isEmpty
        else { return nil }

        func string(_ key: String) -> String? {
            guard let value = result.objectForKeyedSubscript(key), value.isString,
                  let s = value.toString()?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty else { return nil }
            return s
        }
        let length = Int(result.objectForKeyedSubscript("length")?.toInt32() ?? 0)
        return Article(title: string("title"), contentHTML: content, textLength: length, siteName: string("siteName"))
    }
}
