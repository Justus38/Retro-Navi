import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;

import '../core/config/app_config.dart';
import '../core/models/place.dart';
import '../services/geocoding/geocoding_service.dart';
import '../services/geocoding/nominatim_geocoding_service.dart';
import '../services/geocoding/ors_geocoding_service.dart';
import 'gps_providers.dart';

final httpClientProvider = Provider<http.Client>((ref) {
  final client = http.Client();
  ref.onDispose(client.close);
  return client;
});

/// Mit ORS-Key -> ORS (mit Autocomplete), sonst Nominatim (nur Vollsuche).
final geocodingServiceProvider = Provider<GeocodingService>((ref) {
  final config = ref.watch(appConfigProvider);
  final client = ref.watch(httpClientProvider);
  return config.hasOrsKey
      ? OrsGeocodingService(client, config.orsApiKey)
      : NominatimGeocodingService(client, config.userAgent);
});

class DestinationSearchState {
  const DestinationSearchState({
    this.query = '',
    this.suggestions = const [],
    this.loading = false,
    this.error,
    this.destination,
  });

  final String query;
  final List<Place> suggestions;
  final bool loading;
  final String? error;
  final Place? destination;

  DestinationSearchState copyWith({
    String? query,
    List<Place>? suggestions,
    bool? loading,
    String? error,
    bool clearError = false,
  }) =>
      DestinationSearchState(
        query: query ?? this.query,
        suggestions: suggestions ?? this.suggestions,
        loading: loading ?? this.loading,
        error: clearError ? null : (error ?? this.error),
        destination: destination,
      );
}

class DestinationSearchController extends Notifier<DestinationSearchState> {
  static const _minChars = 3;
  static const _debounce = Duration(milliseconds: 400);

  Timer? _timer;
  int _requestId = 0;

  @override
  DestinationSearchState build() {
    ref.onDispose(() => _timer?.cancel());
    return const DestinationSearchState();
  }

  /// Aufruf bei jeder Texteingabe (mit Debounce).
  void onQueryChanged(String text) {
    _timer?.cancel();
    final q = text.trim();
    if (q.length < _minChars) {
      _requestId++; // laufende Antworten verwerfen
      state = state.copyWith(
          query: q, suggestions: const [], loading: false, clearError: true);
      return;
    }
    state = state.copyWith(query: q);
    _timer = Timer(_debounce, () => _run(q, autocomplete: true));
  }

  /// "Suchen" auf der Tastatur.
  Future<void> submit() async {
    _timer?.cancel();
    if (state.query.length < _minChars) return;
    await _run(state.query, autocomplete: false);
  }

  Future<void> _run(String q, {required bool autocomplete}) async {
    final id = ++_requestId;
    state = state.copyWith(loading: true, clearError: true);
    try {
      final service = ref.read(geocodingServiceProvider);
      final focus = ref.read(positionStreamProvider).valueOrNull?.latLng;
      final result = autocomplete
          ? await service.autocomplete(q, focus: focus)
          : await service.search(q, focus: focus);
      if (id != _requestId) return; // veraltete Antwort
      state = state.copyWith(suggestions: result, loading: false);
    } on GeocodingException catch (e) {
      if (id != _requestId) return;
      state = state.copyWith(
          suggestions: const [], loading: false, error: e.message);
    } catch (_) {
      if (id != _requestId) return;
      state = state.copyWith(
          suggestions: const [], loading: false, error: 'Suche fehlgeschlagen.');
    }
  }

  void select(Place place) {
    _timer?.cancel();
    _requestId++;
    state = DestinationSearchState(query: place.name, destination: place);
  }

  void clear() {
    _timer?.cancel();
    _requestId++;
    state = const DestinationSearchState();
  }
}

final destinationSearchProvider =
    NotifierProvider<DestinationSearchController, DestinationSearchState>(
  DestinationSearchController.new,
);
