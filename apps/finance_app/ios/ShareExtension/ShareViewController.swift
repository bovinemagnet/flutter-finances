import receive_sharing_intent

/// Share sheet entry point for receipt photos and PDFs.
///
/// `RSIShareViewController` copies the shared files into the App Group
/// container (`group.com.paulsnow.finance.app`) and opens the host app through
/// its `ShareMedia-<bundle id>` URL scheme. The app then reads them through
/// `PluginShareInbox`, where they become unconfirmed receipt captures; nothing
/// is posted without the user's review.
class ShareViewController: RSIShareViewController {

    // Hand the files straight to the app; the review happens there.
    override func shouldAutoRedirect() -> Bool {
        return true
    }
}
