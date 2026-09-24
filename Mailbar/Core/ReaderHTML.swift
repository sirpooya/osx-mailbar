import Foundation

/// Turns a message body into the document the reader loads.
///
/// Safety is carried by a Content-Security-Policy placed before any of the message's own markup,
/// so it governs everything that follows:
/// - no script, frame, form, font or media load from anywhere (JavaScript is also off in the
///   web view itself; this is the second lock);
/// - images from `data:` only, which is how inline `cid:` images arrive, until the user presses
///   "Load images" for this message. Remote images are the tracking pixels this exists to stop;
/// - no remote stylesheets, ever, since a stylesheet can fetch images of its own.
///
/// DNS prefetch is switched off as well, because a prefetch leaks a lookup even when the load
/// itself is blocked.
enum ReaderHTML {

    static func document(body html: String,
                         images: [String: (type: String, data: Data)],
                         allowRemoteImages: Bool) -> String {
        let imageSources = allowRemoteImages ? "data: https: http:" : "data:"
        let policy = "default-src 'none'; img-src \(imageSources); style-src 'unsafe-inline'; "
            + "font-src data:; form-action 'none'; base-uri 'none'"

        // Before the message's own <html>: the parser opens the head for these, and the message's
        // tags then merge into the same document, so the policy is in force from its first byte.
        let preamble = """
        <meta http-equiv="Content-Security-Policy" content="\(policy)">
        <meta http-equiv="x-dns-prefetch-control" content="off">
        <meta name="color-scheme" content="light only">
        <style>
          html { background: #ffffff; }
          body { margin: 12px 14px; color: #1d1d1f; font: 13px -apple-system, "Helvetica Neue", sans-serif;
                 overflow-wrap: anywhere; }
          img { max-width: 100%; height: auto; }
          pre { white-space: pre-wrap; }
        </style>
        """
        return preamble + inlining(images, into: html)
    }

    /// Replaces each `cid:` reference with the image's bytes as a data URI, in memory.
    static func inlining(_ images: [String: (type: String, data: Data)], into html: String) -> String {
        var result = html
        for (contentID, image) in images {
            let bare = contentID.trimmingCharacters(in: CharacterSet(charactersIn: "<>"))
            let uri = "data:\(image.type);base64,\(image.data.base64EncodedString())"
            result = result.replacingOccurrences(of: "cid:\(bare)", with: uri, options: .caseInsensitive)
        }
        return result
    }

    /// Whether "Load images" would change anything: an http(s) image, background or CSS url.
    static func hasRemoteImages(_ html: String) -> Bool {
        html.range(of: #"(src|background)\s*=\s*["']?\s*https?:"#,
                   options: [.regularExpression, .caseInsensitive]) != nil
            || html.range(of: #"url\(\s*["']?\s*https?:"#,
                          options: [.regularExpression, .caseInsensitive]) != nil
    }
}
