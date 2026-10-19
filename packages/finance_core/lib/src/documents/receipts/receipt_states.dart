/// The two independent receipt state machines (REC 04).
///
/// Extraction and upload progress separately: a receipt can be reviewed
/// while its image is still uploading, and an extraction failure never
/// affects the stored document.
library;

/// Text extraction and review progress of a receipt.
enum ExtractionState {
  captured,
  extractionQueued,
  extracting,
  needsReview,
  reviewed,
  extractionFailed,
}

enum ExtractionEvent {
  /// Hand a captured receipt to the extraction queue.
  queue,

  /// A worker picks the receipt up.
  start,

  /// Extraction produced candidates that now need review.
  succeed,

  /// Extraction failed; the document is kept.
  fail,

  /// Try a failed extraction again.
  retry,

  /// The worker stopped (for example the app was closed); queue again.
  interrupt,

  /// The user confirmed the fields, by review or manual entry.
  review,

  /// Run extraction again, for example with a newer engine. Confirmed
  /// fields are kept because they live on the receipt, not the extraction.
  rerun,
}

/// Upload progress of one document asset (SYNC 05).
enum UploadState {
  /// Sync is off; the asset exists on this device only.
  localOnly,
  uploadQueued,
  uploading,
  uploaded,
  uploadFailed,
}

enum UploadEvent {
  /// Queue an upload (also used when sync is first enabled).
  queue,
  start,
  complete,
  fail,
  retry,

  /// The transfer stopped part way; queue it to resume or restart.
  interrupt,
}

class IllegalTransitionException implements Exception {
  IllegalTransitionException(this.from, this.event);

  final Enum from;
  final Enum event;

  @override
  String toString() =>
      'IllegalTransitionException: cannot apply ${event.name} '
      'in state ${from.name}';
}

const _extractionTransitions =
    <ExtractionState, Map<ExtractionEvent, ExtractionState>>{
      ExtractionState.captured: {
        ExtractionEvent.queue: ExtractionState.extractionQueued,
        ExtractionEvent.review: ExtractionState.reviewed,
      },
      ExtractionState.extractionQueued: {
        ExtractionEvent.start: ExtractionState.extracting,
        ExtractionEvent.review: ExtractionState.reviewed,
      },
      ExtractionState.extracting: {
        ExtractionEvent.succeed: ExtractionState.needsReview,
        ExtractionEvent.fail: ExtractionState.extractionFailed,
        ExtractionEvent.interrupt: ExtractionState.extractionQueued,
      },
      ExtractionState.needsReview: {
        ExtractionEvent.review: ExtractionState.reviewed,
        ExtractionEvent.rerun: ExtractionState.extractionQueued,
      },
      ExtractionState.reviewed: {
        ExtractionEvent.rerun: ExtractionState.extractionQueued,
      },
      ExtractionState.extractionFailed: {
        ExtractionEvent.retry: ExtractionState.extractionQueued,
        ExtractionEvent.review: ExtractionState.reviewed,
      },
    };

const _uploadTransitions = <UploadState, Map<UploadEvent, UploadState>>{
  UploadState.localOnly: {UploadEvent.queue: UploadState.uploadQueued},
  UploadState.uploadQueued: {UploadEvent.start: UploadState.uploading},
  UploadState.uploading: {
    UploadEvent.complete: UploadState.uploaded,
    UploadEvent.fail: UploadState.uploadFailed,
    UploadEvent.interrupt: UploadState.uploadQueued,
  },
  UploadState.uploaded: {},
  UploadState.uploadFailed: {UploadEvent.retry: UploadState.uploadQueued},
};

/// The extraction state after [event], or [IllegalTransitionException].
ExtractionState nextExtractionState(
  ExtractionState from,
  ExtractionEvent event,
) =>
    _extractionTransitions[from]![event] ??
    (throw IllegalTransitionException(from, event));

/// The upload state after [event], or [IllegalTransitionException].
UploadState nextUploadState(UploadState from, UploadEvent event) =>
    _uploadTransitions[from]![event] ??
    (throw IllegalTransitionException(from, event));

/// Summarises asset upload states for a receipt, most urgent first:
/// failed, uploading, queued, local only, then uploaded. Null when the
/// receipt has no assets (for example metadata synced before its image).
UploadState? aggregateUploadState(Iterable<UploadStateHolder> assets) {
  const order = [
    UploadState.uploadFailed,
    UploadState.uploading,
    UploadState.uploadQueued,
    UploadState.localOnly,
    UploadState.uploaded,
  ];
  final states = assets.map((a) => a.uploadState).toSet();
  for (final state in order) {
    if (states.contains(state)) return state;
  }
  return null;
}

/// Anything with an upload state, such as a document asset.
abstract interface class UploadStateHolder {
  UploadState get uploadState;
}
