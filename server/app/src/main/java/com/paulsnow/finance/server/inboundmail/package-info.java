/**
 * Email receipt forwarding (P1). A member turns on a private address; an
 * inbound email provider posts what is sent to it; attachments are identified
 * from their bytes, scanned and held in private storage until the member's
 * device collects them as ordinary receipts for review. The server never
 * creates a receipt, sends a sync command or stores an email body, and a
 * forwarded email can never post a transaction. Only the {@code sandbox}
 * provider exists, and only when configured: choosing a real inbound email
 * service is a pending decision.
 *
 * @author Paul Snow
 * @since 0.0.0
 */
@org.springframework.modulith.ApplicationModule(displayName = "Inbound mail")
package com.paulsnow.finance.server.inboundmail;
