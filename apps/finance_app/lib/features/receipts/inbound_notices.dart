import 'package:finance_store/finance_store.dart';
import 'package:flutter/material.dart';

import '../../app/theme.dart';

/// How many notices show at once, and refused files within each, so receipts
/// stay in view however many an email brings.
const _maxShown = 3;
const _maxRejectionsShown = 3;

String _who(InboundNotice notice) =>
    notice.sender.isEmpty ? 'An email' : 'Email from ${notice.sender}';

String _headline(InboundNotice notice) => switch (notice.outcome) {
  'no_attachment' => '${_who(notice)} had no attachment',
  'rate_limited' =>
    '${_who(notice)} arrived after the daily limit and was not kept',
  'failed' => '${_who(notice)} could not be processed. Try forwarding it again',
  'not_collected' => 'An emailed attachment has not reached this device',
  'documents' => 'Some attachments from ${_sender(notice)} were not kept',
  _ => 'Nothing from ${_sender(notice)} could be kept',
};

String _sender(InboundNotice notice) =>
    notice.sender.isEmpty ? 'an email' : notice.sender;

String _reason(InboundRejection rejection) => switch (rejection.code) {
  'UNSUPPORTED_TYPE' => 'not an image or PDF',
  'TOO_LARGE' => 'larger than 20 MB',
  'TOO_MANY' => 'too many attachments',
  'NOT_COLLECTED' => 'expires 30 days after it arrived',
  'REJECTED_ON_DEVICE' => rejection.detail ?? 'this device could not save it',
  _ => 'failed the safety check',
};

/// Says what happened to forwarded emails that did not fully become receipts,
/// so none is lost without the user being able to tell. Everything here came
/// from an outside sender, and is only ever shown as plain text.
class InboundNotices extends StatelessWidget {
  const InboundNotices({
    super.key,
    required this.notices,
    required this.onDismiss,
  });

  final List<InboundNotice> notices;
  final ValueChanged<String> onDismiss;

  Widget? _rejections(InboundNotice notice) {
    final rejections = notice.rejections;
    if (rejections.isEmpty) return null;
    final hidden = rejections.length - _maxRejectionsShown;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (final r in rejections.take(_maxRejectionsShown))
          Text(
            '${r.fileName}: ${_reason(r)}',
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
          ),
        if (hidden > 0) Text('and $hidden more'),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    if (notices.isEmpty) return const SizedBox.shrink();
    final palette = FinancePalette.of(context);
    final hidden = notices.length - _maxShown;
    return ConstrainedBox(
      constraints: BoxConstraints(
        maxHeight: MediaQuery.sizeOf(context).height * 0.35,
      ),
      child: SingleChildScrollView(
        child: Column(
          children: [
            for (final notice in notices.take(_maxShown))
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                child: Card(
                  margin: EdgeInsets.zero,
                  color: palette.warningSoft,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(16),
                    side: BorderSide(color: palette.warningLine),
                  ),
                  child: ListTile(
                    iconColor: palette.onWarningSoft,
                    textColor: palette.onWarningSoft,
                    leading: const Icon(Icons.mail_outline),
                    title: Text(
                      _headline(notice),
                      maxLines: 3,
                      overflow: TextOverflow.ellipsis,
                    ),
                    subtitle: _rejections(notice),
                    trailing: IconButton(
                      tooltip: 'Dismiss',
                      icon: const Icon(Icons.close),
                      onPressed: () => onDismiss(notice.messageId),
                    ),
                  ),
                ),
              ),
            if (hidden > 0)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                child: Text(
                  hidden == 1
                      ? '1 more email to look at'
                      : '$hidden more emails to look at',
                ),
              ),
          ],
        ),
      ),
    );
  }
}
