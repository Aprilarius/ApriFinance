import 'dart:convert';

import 'package:cryptography/dart.dart';

import '../models.dart';

enum SeriesCadence { weekly, monthly, yearly }

enum SeriesDecision { accepted, rejected }

class SeriesPlanLink {
  const SeriesPlanLink({
    required this.planId,
    required this.planHash,
    required this.linkedOn,
  });
  final String planId, planHash;
  final DateTime linkedOn;
  Map<String, Object> toJson() => {
    'planId': planId,
    'planHash': planHash,
    'linkedOn': calendarDate(linkedOn),
  };
  factory SeriesPlanLink.fromJson(Map<String, dynamic> json) {
    final id = json['planId'] as String, hash = json['planHash'] as String;
    if (id.isEmpty ||
        id.length > 80 ||
        !RegExp(r'^[a-f0-9]{64}$').hasMatch(hash)) {
      throw const FormatException('Некорректная связь с планом');
    }
    return SeriesPlanLink(
      planId: id,
      planHash: hash,
      linkedOn: parseCalendarDate(json['linkedOn'] as String),
    );
  }
}

String seriesDigest(Object value) => const DartSha256()
    .hashSync(utf8.encode(jsonEncode(value)))
    .bytes
    .map((b) => b.toRadixString(16).padLeft(2, '0'))
    .join();
String _canonical(String value) =>
    value.trim().replaceAll(RegExp(r'\s+'), ' ').toLowerCase();
String seriesKey(String currency, LedgerEntry entry) => seriesDigest([
  currency,
  entry.accountId,
  entry.kind.name,
  _canonical(entry.category),
  _canonical(entry.note),
]);
String seriesRawKey(String currency, LedgerEntry entry) => jsonEncode([
  currency,
  entry.accountId,
  entry.kind.name,
  _canonical(entry.category),
  _canonical(entry.note),
]);
String seriesSourceHash(String currency, Iterable<LedgerEntry> entries) {
  final sorted = entries.toList()..sort((a, b) => a.id.compareTo(b.id));
  return seriesDigest([currency, sorted.map((e) => e.toJson()).toList()]);
}

bool followsCadence(DateTime a, DateTime b, SeriesCadence cadence) {
  final days = DateTime.utc(
    b.year,
    b.month,
    b.day,
  ).difference(DateTime.utc(a.year, a.month, a.day)).inDays;
  final months = (b.year - a.year) * 12 + b.month - a.month;
  final bothEnds =
      a.day == DateTime(a.year, a.month + 1, 0).day &&
      b.day == DateTime(b.year, b.month + 1, 0).day;
  return switch (cadence) {
    SeriesCadence.weekly => days >= 6 && days <= 8,
    SeriesCadence.monthly =>
      months == 1 && ((a.day - b.day).abs() <= 3 || bothEnds),
    SeriesCadence.yearly =>
      b.year - a.year == 1 && a.month == b.month && (a.day - b.day).abs() <= 7,
  };
}

class SeriesProposal {
  SeriesProposal({
    required this.key,
    required this.cadence,
    required this.sourceHash,
    required Iterable<String> sourceIds,
  }) : sourceIds = List.unmodifiable(sourceIds.toSet().toList()..sort());
  final String key, sourceHash;
  final SeriesCadence cadence;
  final List<String> sourceIds;
  List<LedgerEntry>? sources(LedgerSnapshot snapshot) {
    if (snapshot.currency == null) return null;
    if (sourceIds.length < (cadence == SeriesCadence.weekly ? 4 : 3) ||
        sourceIds.length > 100) {
      return null;
    }
    final wanted = sourceIds.toSet();
    final entries = snapshot.entries
        .where((e) => wanted.contains(e.id))
        .toList();
    if (entries.length != sourceIds.length ||
        entries.isEmpty ||
        entries.any((e) => seriesKey(snapshot.currency!, e) != key) ||
        seriesSourceHash(snapshot.currency!, entries) != sourceHash) {
      return null;
    }
    entries.sort((a, b) => a.date.compareTo(b.date));
    if (entries.first.kind != EntryKind.expense &&
        entries.first.kind != EntryKind.income) {
      return null;
    }
    if (_canonical(entries.first.note).length < 3) return null;
    for (var n = 1; n < entries.length; n++) {
      if (!followsCadence(entries[n - 1].date, entries[n].date, cadence)) {
        return null;
      }
    }
    return entries;
  }
}

class SeriesReview {
  SeriesReview({
    required this.proposal,
    required this.decision,
    required this.reviewedOn,
    this.planLink,
  });
  final SeriesProposal proposal;
  final SeriesDecision decision;
  final DateTime reviewedOn;
  final SeriesPlanLink? planLink;
  SeriesReview withLink(SeriesPlanLink? link) => SeriesReview(
    proposal: proposal,
    decision: decision,
    reviewedOn: reviewedOn,
    planLink: link,
  );
  bool validAt(LedgerSnapshot snapshot, DateTime through) {
    if (reviewedOn.isAfter(through)) return false;
    final entries = proposal.sources(snapshot);
    return entries != null &&
        entries.every(
          (e) => !e.date.isAfter(through) && !e.date.isAfter(reviewedOn),
        );
  }

  Map<String, Object> toJson() => {
    'key': proposal.key,
    'cadence': proposal.cadence.name,
    'sourceHash': proposal.sourceHash,
    'sourceIds': proposal.sourceIds,
    'decision': decision.name,
    'reviewedOn': calendarDate(reviewedOn),
    if (planLink != null) 'planLink': planLink!.toJson(),
  };
  factory SeriesReview.fromJson(Map<String, dynamic> json) {
    final key = json['key'] as String, hash = json['sourceHash'] as String;
    final ids = (json['sourceIds'] as List).cast<String>();
    if (!RegExp(r'^[0-9a-f]{64}$').hasMatch(key) ||
        !RegExp(r'^[0-9a-f]{64}$').hasMatch(hash) ||
        ids.length < 3 ||
        ids.length > 100 ||
        ids.toSet().length != ids.length ||
        ids.any((id) => id.isEmpty || id.length > 200)) {
      throw const FormatException('Некорректная серия');
    }
    return SeriesReview(
      proposal: SeriesProposal(
        key: key,
        cadence: SeriesCadence.values.byName(json['cadence'] as String),
        sourceHash: hash,
        sourceIds: ids,
      ),
      decision: SeriesDecision.values.byName(json['decision'] as String),
      reviewedOn: parseCalendarDate(json['reviewedOn'] as String),
      planLink: json['planLink'] == null
          ? null
          : SeriesPlanLink.fromJson(
              Map<String, dynamic>.from(json['planLink'] as Map),
            ),
    );
  }
}
