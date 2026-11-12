#if DEBUG
import UIKit
import WebKit

/// Diagnostics for maintainers, DEBUG builds only, on only when the process is launched with RAIS_PROBE=1: a timestamped log of what moves when the
/// keyboard opens (native scroll offset and inset, the web view's height, and the page's own scroll positions), written to
/// Documents/rais-probe.log. Used to compare the SDK screen with a plain web view. Not part of the SDK's API.
final class DebugProbe: NSObject, WKScriptMessageHandler {
    static var enabled: Bool { ProcessInfo.processInfo.environment["RAIS_PROBE"] != nil }

    private let path = NSSearchPathForDirectoriesInDomains(.documentDirectory, .userDomainMask, true)[0] + "/rais-probe.log"
    private let start = CACurrentMediaTime()
    private var observation: NSKeyValueObservation?
    private weak var webView: WKWebView?

    func install(on webView: WKWebView, controller: WKUserContentController) {
        self.webView = webView
        try? "".write(toFile: path, atomically: true, encoding: .utf8)
        controller.add(self, name: "raisProbe")
        let source = """
        (function () {
          var vv = window.visualViewport;
          function shell() { return document.querySelector('.shell'); }
          function snap(tag) {
            var s = shell();
            var a = document.activeElement;
            window.webkit.messageHandlers.raisProbe.postMessage('web ' + tag +
              ' innerH=' + window.innerHeight + ' vvH=' + (vv ? Math.round(vv.height) : -1) + ' vvTop=' + (vv ? Math.round(vv.offsetTop * 10) / 10 : -1) +
              ' winY=' + Math.round(window.scrollY * 10) / 10 + ' shellTop=' + (s ? Math.round(s.scrollTop * 10) / 10 : -1) +
              ' focus=' + (a && a.id ? a.id : '-'));
          }
          document.addEventListener('focusin', function () { snap('focusin'); }, true);
          document.addEventListener('focusout', function () { snap('focusout'); }, true);
          window.addEventListener('resize', function () { snap('resize'); });
          if (vv) { vv.addEventListener('resize', function () { snap('vv-resize'); }); vv.addEventListener('scroll', function () { snap('vv-scroll'); }); }
          document.addEventListener('scroll', function () { snap('scroll'); }, true);
        })();
        """
        controller.addUserScript(WKUserScript(source: source, injectionTime: .atDocumentEnd, forMainFrameOnly: true))
        observation = webView.scrollView.observe(\.contentOffset, options: [.new]) { [weak self] scroll, _ in
            self?.write("native offsetY=\(Int(scroll.contentOffset.y * 10)) /10 insetBottom=\(Int(scroll.adjustedContentInset.bottom)) frameH=\(Int(self?.webView?.frame.height ?? 0))")
        }
    }

    func layout(_ webView: WKWebView) {
        write("layout webFrame y=\(Int(webView.frame.minY)) h=\(Int(webView.frame.height)) inset.b=\(Int(webView.scrollView.adjustedContentInset.bottom))")
    }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        if let text = message.body as? String { write(text) }
    }

    private func write(_ text: String) {
        let line = String(format: "%7.0f ms  ", (CACurrentMediaTime() - start) * 1000) + text + "\n"
        guard let data = line.data(using: .utf8), let handle = FileHandle(forWritingAtPath: path) else { return }
        handle.seekToEndOfFile()
        handle.write(data)
        try? handle.close()
    }
}
#endif
