import 'package:finance_store/finance_store.dart';
import 'package:http/http.dart' as http;

import 'receipt_service.dart';

/// The app's sync client. Every sync, in the foreground or the background, goes
/// through this so they all resolve conflicts the same way.
SyncClient appSyncClient(
  FinanceStore store, {
  required http.Client httpClient,
  required Uri baseUri,
  required Future<String?> Function() accessToken,
  RetryPolicy retry = const RetryPolicy(),
}) => SyncClient(
  store,
  httpClient: httpClient,
  baseUri: baseUri,
  accessToken: accessToken,
  retry: retry,
  derivedFields: receiptDerivedFields,
);
