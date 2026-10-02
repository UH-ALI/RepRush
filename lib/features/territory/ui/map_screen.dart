/// Territory map with server-provided H3 polygons over OpenStreetMap tiles —
/// the home screen, and the start of the loop: see your hex → train here →
/// come back and watch it change colour.
///
/// Location rules the map enforces in the UI (the server enforces them for
/// real — territory always resolves from the session's recorded start fix):
///
///   - the hex you are standing in pulses, and the bottom card offers to train
///     for it;
///   - every other hex shows how far away it is instead of a button that could
///     never pay out;
///   - the grid re-fetches around you once you walk out of the loaded area.
///
/// Ownership: C (ui).
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'package:reprush/app/mode_switch.dart';
import 'package:reprush/app/shell_providers.dart';
import 'package:reprush/app/theme/design_tokens.dart';
import 'package:reprush/core/api/stub/stub_repositories.dart' show DemoVenue;
import 'package:reprush/core/location/geo.dart';
import 'package:reprush/features/challenges/ui/duel_widgets.dart';
import 'package:reprush/features/presence/data/presence_providers.dart';
import 'package:reprush/features/presence/ui/presence_ui.dart';
import 'package:reprush/features/session/data/session_providers.dart';
import 'package:reprush/features/session/ui/training_flow.dart';
import 'package:reprush/features/spots/data/spots_providers.dart';
import 'package:reprush/features/territory/data/territory_providers.dart';
import 'package:reprush/features/territory/ui/basemap.dart';
import 'package:reprush/features/territory/ui/current_hex_line.dart';
import 'package:reprush/models/models.dart';
import 'package:reprush/shared/async_current.dart';
import 'package:reprush/shared/states/states.dart';
import 'package:reprush/shared/widgets/widgets.dart';

const double _defaultZoom = 14.2;
const double _focusZoom = 15.2;

class MapScreen extends ConsumerWidget {
  const MapScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final location = ref.watch(territoryLocationProvider);
    final hexes = ref.watch(hexesProvider);
    final spots = ref.watch(nearbySpotsProvider);
    return Scaffold(
      appBar: AppBar(
        title: const Text('Territory'),
        actions: const [DemoBadge()],
      ),
      // skipLoadingOnReload: re-anchoring after a long walk swaps the grid in
      // place rather than blanking the whole map behind a spinner.
      body: location.when(
        skipLoadingOnReload: true,
        loading: () => const LoadingView(),
        error: (error, _) => ErrorView(
          error: error,
          onRetry: () => ref.invalidate(territoryLocationProvider),
        ),
        data: (resolvedLocation) => hexes.when(
          skipLoadingOnReload: true,
          loading: () => const LoadingView(),
          error: (error, _) => ErrorView(
            error: error,
            onRetry: () => ref.invalidate(hexesProvider),
          ),
          data: (cells) => _MapView(
            cells: cells,
            spots: spots.value ?? const [],
            location: resolvedLocation,
          ),
        ),
      ),
    );
  }
}

class _MapView extends ConsumerStatefulWidget {
  const _MapView({
    required this.cells,
    required this.spots,
    required this.location,
  });

  final List<HexCell> cells;
  final List<SpotSummary> spots;

  /// The anchor the grid was fetched around — not necessarily where the
  /// athlete is now (that is [hereProvider]).
  final SessionLocation location;

  @override
  ConsumerState<_MapView> createState() => _MapViewState();
}

class _MapViewState extends ConsumerState<_MapView>
    with TickerProviderStateMixin {
  /// Drives the "you are here" marker and the current hex's outline.
  late final AnimationController _pulse = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1400),
  )..repeat(reverse: true);

  /// The one-shot flash on a hex the summary sent us to — the capture moment.
  late final AnimationController _flash = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1600),
  );
  String? _flashHex;
  String? _scheduledFocus;

  late final ValueNotifier<LayerHitResult<HexCell>?> _hitNotifier =
      ValueNotifier(null);
  final MapController _mapController = MapController();
  String? _selectedHex;
  bool _starting = false;

  /// Set while a re-anchor fetch is in flight, so a stream of fixes beyond
  /// [reanchorDistanceM] triggers one refetch rather than one per fix.
  bool _reanchoring = false;

  @override
  void didUpdateWidget(_MapView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.location != widget.location) _reanchoring = false;
  }

  @override
  void dispose() {
    _pulse.dispose();
    _flash.dispose();
    _hitNotifier.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    ref.listen<AsyncValue<SessionLocation>>(currentLocationProvider, (_, next) {
      final fix = next.value;
      if (fix == null || _reanchoring) return;
      final moved = distanceM(
        widget.location.lat,
        widget.location.lng,
        fix.lat,
        fix.lng,
      );
      if (moved > reanchorDistanceM) {
        _reanchoring = true;
        ref.invalidate(territoryLocationProvider);
      }
    });
    // Watched, not listened: a request made while this tab was hidden (the
    // summary sets it and switches tabs in one go) is still seen on return.
    final focusRequest = ref.watch(mapFocusProvider);
    if (focusRequest != null && focusRequest != _scheduledFocus) {
      _scheduledFocus = focusRequest;
      WidgetsBinding.instance.addPostFrameCallback(
        (_) => _focusHex(focusRequest),
      );
    }

    final here = ref.watch(hereProvider) ?? widget.location;
    final current = ref.watch(currentHexProvider);
    final visible = ref.watch(presenceVisibleProvider).value ?? false;
    final players = ref.watch(nearbyPlayersProvider).unlessFailed ?? const [];
    // One marker per hex: presence is hex-level, so athletes sharing a hex
    // share a spot on the map.
    final playersByHex = <String, List<NearbyPlayer>>{};
    for (final player in players) {
      (playersByHex[player.h3] ??= []).add(player);
    }
    final cells = widget.cells;
    final yours = cells.where((c) => c.yours).length;
    // Your territory beyond the loaded grid: only your own hexes, so a few
    // dozen polygons at most however far they are spread.
    // `current`: only this mode's territory — never the demo's hexes left
    // over on the live map while it reloads, or after its load fails.
    final mine = ref.watch(myHexesProvider).current ?? const <HexCell>[];
    final loaded = {for (final c in cells) c.h3};
    final far = [
      for (final c in mine)
        if (!loaded.contains(c.h3)) c,
    ];
    final rivals = cells.where((c) => !c.yours && c.ownerHandle != null).length;
    final open = cells.length - yours - rivals;

    // Highlighted cells draw last so their outline is not painted over by a
    // neighbour's border.
    int drawOrder(HexCell c) => c.h3 == _selectedHex || c.h3 == _flashHex
        ? 2
        : c.h3 == current?.h3
        ? 1
        : 0;
    final ordered = [...cells]
      ..sort((a, b) => drawOrder(a).compareTo(drawOrder(b)));

    return Stack(
      children: [
        FlutterMap(
          options: MapOptions(
            interactionOptions: const InteractionOptions(
              flags: InteractiveFlag.all & ~InteractiveFlag.rotate,
            ),
            initialCenter: LatLng(here.lat, here.lng),
            initialZoom: _defaultZoom,
            onTap: (_, _) => _onHexTap(),
          ),
          mapController: _mapController,
          children: [
            basemapLayer(context),
            AnimatedBuilder(
              animation: _flash,
              builder: (context, _) => PolygonLayer(
                polygons: [for (final cell in far) _farPolygon(cell)],
              ),
            ),
            AnimatedBuilder(
              animation: Listenable.merge([_pulse, _flash]),
              builder: (context, _) => PolygonLayer(
                polygons: [
                  for (final cell in ordered) _polygonFor(cell, current),
                ],
                hitNotifier: _hitNotifier,
              ),
            ),
            MarkerLayer(
              markers: [
                // A flag on each far-off hex, so your territory is findable
                // at any zoom, even where the hex itself is a speck.
                for (final cell in far) _flagMarker(cell),
                for (final spot in widget.spots) _spotMarker(spot),
                for (final group in playersByHex.values)
                  _playersMarker(group, here),
                Marker(
                  point: LatLng(here.lat, here.lng),
                  width: 52,
                  height: 52,
                  child: AnimatedBuilder(
                    animation: _pulse,
                    builder: (context, child) => Container(
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: RepRushTokens.brand.withValues(alpha: .16),
                        border: Border.all(
                          color: RepRushTokens.brand.withValues(
                            alpha: .45 + (_pulse.value * .4),
                          ),
                          width: 2 + (_pulse.value * 3),
                        ),
                      ),
                      child: const Icon(
                        Icons.my_location,
                        color: RepRushTokens.brand,
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ],
        ),
        Positioned(
          left: RepRushTokens.spaceMd,
          right: RepRushTokens.spaceMd,
          top: RepRushTokens.spaceMd,
          child: Row(
            children: [
              // Short and fixed-length: always shown in full. Opens your
              // territory everywhere — the map only loads the ground around
              // you.
              GestureDetector(
                onTap: () => _showTerritory(mine),
                child: _MapPill(
                  icon: Icons.hexagon,
                  text: '$yours OWNED',
                  color: Ownership.yours.color,
                  trailing: Icons.expand_more,
                ),
              ),
              const SizedBox(width: RepRushTokens.spaceSm),
              // The opt-in to nearby play: hidden by default, and while
              // visible it says how many others are around.
              _PresencePill(
                visible: visible,
                count: players.length,
                onTap: () => showVisibilitySheet(context),
              ),
              const SizedBox(width: RepRushTokens.spaceSm),
              // Takes the rest of the row and sits flush right, above the zoom
              // controls; it is the one that ellipsises if space runs out.
              Expanded(
                child: Align(
                  alignment: Alignment.centerRight,
                  child: _CurrentHexPill(
                    current: current,
                    onTap: current == null ? null : () => _openSheet(current),
                  ),
                ),
              ),
            ],
          ),
        ),
        Positioned(
          right: RepRushTokens.spaceMd,
          top: 68,
          child: _MapControls(
            onZoomIn: () => _mapController.move(
              _mapController.camera.center,
              _mapController.camera.zoom + .7,
            ),
            onZoomOut: () => _mapController.move(
              _mapController.camera.center,
              _mapController.camera.zoom - .7,
            ),
            onRecenter: () =>
                _mapController.move(LatLng(here.lat, here.lng), _defaultZoom),
          ),
        ),
        Positioned(
          left: RepRushTokens.spaceSm,
          right: RepRushTokens.spaceSm,
          bottom: RepRushTokens.spaceSm,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const MapDuelBanner(),
              Row(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Expanded(
                    child: Wrap(
                      spacing: 6,
                      runSpacing: 4,
                      children: [
                        _LegendChip(ownership: Ownership.yours, count: yours),
                        _LegendChip(ownership: Ownership.rival, count: rivals),
                        _LegendChip(
                          ownership: Ownership.unclaimed,
                          count: open,
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: RepRushTokens.spaceSm),
                  // Required attribution; wraps to two lines on narrow phones
                  // rather than pushing the legend off-screen.
                  Flexible(
                    child: Text(
                      basemapAttribution,
                      textAlign: TextAlign.end,
                      style: const TextStyle(
                        color: Colors.white70,
                        fontSize: 9,
                        height: 1.2,
                        shadows: [Shadow(blurRadius: 3)],
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: RepRushTokens.spaceSm),
              _TrainHereCard(
                current: current,
                starting: _starting,
                onTrain: current == null ? null : () => _train(current),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Polygon<HexCell> _polygonFor(HexCell cell, HexCell? current) {
    final unclaimed = cell.ownerHandle == null && !cell.yours;
    final isCurrent = cell.h3 == current?.h3;
    final isSelected = cell.h3 == _selectedHex;
    final ownerColor = Ownership.fromWire(
      ownerHandle: cell.ownerHandle,
      yours: cell.yours,
    ).color;
    // Tuned for the dark basemap: open hexes are a faint lattice, held hexes
    // glow in their owner's colour with a matching edge.
    final base = unclaimed
        ? Colors.white.withValues(alpha: .03)
        : ownerColor.withValues(alpha: .30);
    // The flash fades from bright white back to the hex's (new) colour.
    final flash = cell.h3 == _flashHex && _flash.isAnimating
        ? 1 - Curves.easeOut.transform(_flash.value)
        : 0.0;
    return Polygon<HexCell>(
      points: [for (final point in cell.polygon) LatLng(point.lat, point.lng)],
      color: Color.lerp(base, Colors.white.withValues(alpha: .85), flash)!,
      borderColor: isSelected
          ? Colors.white
          : isCurrent
          ? RepRushTokens.brand.withValues(alpha: .55 + _pulse.value * .45)
          : unclaimed
          ? Colors.white.withValues(alpha: .16)
          : ownerColor.withValues(alpha: .85),
      borderStrokeWidth: isSelected
          ? 4
          : isCurrent
          ? 2.5 + _pulse.value * 2
          : unclaimed
          ? 1
          : 1.6,
      hitValue: cell,
    );
  }

  Marker _spotMarker(SpotSummary spot) => Marker(
    // The stub's seeded rig sits exactly on the demo venue fix; nudge it so the
    // athlete marker does not hide it.
    point: LatLng(
      spot.lat == DemoVenue.lat && spot.lng == DemoVenue.lng
          ? spot.lat + .0008
          : spot.lat,
      spot.lng,
    ),
    width: 44,
    height: 44,
    child: GestureDetector(
      onTap: () => _showSpot(spot),
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: spot.verified
              ? RepRushTokens.electricViolet
              : RepRushTokens.surfaceRaised,
          shape: BoxShape.circle,
          border: Border.all(color: Colors.white, width: 2),
          boxShadow: RepRushTokens.cardShadow,
        ),
        child: Icon(_spotIcon(spot.type), size: 20, color: Colors.white),
      ),
    ),
  );

  /// Athletes in one hex: a location pin at its centre, captioned with who is
  /// there. Nudged off the "you are here" marker when they share your hex,
  /// so neither hides the other.
  Marker _playersMarker(List<NearbyPlayer> group, SessionLocation here) {
    final centre = group.first.centre;
    final onYou = distanceM(here.lat, here.lng, centre.lat, centre.lng) < 80;
    final label = group.length == 1
        ? group.first.handle
        : '${group.first.handle} +${group.length - 1}';
    return Marker(
      point: LatLng(onYou ? centre.lat - .0008 : centre.lat, centre.lng),
      width: 120,
      height: 64,
      // The pin's tip, at the bottom of the marker, sits on the point.
      alignment: Alignment.topCenter,
      child: GestureDetector(
        onTap: () => showPlayersSheet(context, group),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            DecoratedBox(
              decoration: BoxDecoration(
                color: RepRushTokens.chrome,
                borderRadius: BorderRadius.circular(99),
                border: Border.all(color: playerColor.withValues(alpha: .8)),
              ),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
                child: Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ),
            ),
            const Icon(
              Icons.location_on,
              size: 38,
              color: playerColor,
              shadows: [Shadow(blurRadius: 6, color: Colors.black87)],
            ),
          ],
        ),
      ),
    );
  }

  void _onHexTap() {
    final hit = _hitNotifier.value;
    if (hit == null || hit.hitValues.isEmpty || !mounted) return;
    final cell = hit.hitValues.first;
    _hitNotifier.value = null;
    _openSheet(cell);
  }

  void _openSheet(HexCell cell) {
    setState(() => _selectedHex = cell.h3);
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: RepRushTokens.surfaceDark,
      isScrollControlled: true,
      builder: (_) => _HexSheet(cell: cell, onTrain: () => _train(cell)),
    ).whenComplete(() {
      if (mounted) setState(() => _selectedHex = null);
    });
  }

  /// Exercise picker → session for [cell] → full-screen workout.
  Future<void> _train(HexCell cell) async {
    if (_starting) return;
    if (ref.read(activeSessionProvider) != null) {
      await startTraining(context, ref);
      return;
    }
    final ownership = Ownership.fromWire(
      ownerHandle: cell.ownerHandle,
      yours: cell.yours,
    );
    await showTrainSheet(
      context,
      title: switch (ownership) {
        Ownership.yours => 'Defend your hex',
        Ownership.rival => "Take ${cell.ownerHandle}'s hex",
        Ownership.unclaimed => 'Claim this hex',
      },
      subtitle: 'Pick an exercise. Every verified rep counts for this hex.',
      onStart: () async {
        if (!mounted) return;
        setState(() => _starting = true);
        try {
          await startTraining(context, ref, targetH3: cell.h3);
        } finally {
          if (mounted) setState(() => _starting = false);
        }
      },
    );
  }

  /// One of your hexes beyond the loaded grid, drawn on its own.
  Polygon<HexCell> _farPolygon(HexCell cell) {
    final flash = cell.h3 == _flashHex && _flash.isAnimating
        ? 1 - Curves.easeOut.transform(_flash.value)
        : 0.0;
    final colour = Ownership.yours.color;
    return Polygon<HexCell>(
      points: [for (final point in cell.polygon) LatLng(point.lat, point.lng)],
      color: Color.lerp(
        colour.withValues(alpha: .30),
        Colors.white.withValues(alpha: .85),
        flash,
      )!,
      borderColor: cell.h3 == _flashHex ? Colors.white : colour,
      borderStrokeWidth: 2,
    );
  }

  Marker _flagMarker(HexCell cell) {
    final centre = polygonCentre(cell.polygon);
    return Marker(
      point: LatLng(centre.lat, centre.lng),
      width: 30,
      height: 30,
      child: GestureDetector(
        onTap: () => _focusHex(cell.h3),
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: RepRushTokens.chrome,
            shape: BoxShape.circle,
            border: Border.all(color: Ownership.yours.color, width: 2),
            boxShadow: RepRushTokens.cardShadow,
          ),
          child: Icon(Icons.flag, size: 16, color: Ownership.yours.color),
        ),
      ),
    );
  }

  /// Every hex you hold, nearest first; picking one flies the map there.
  void _showTerritory(List<HexCell> mine) {
    final here = ref.read(hereProvider) ?? widget.location;
    final current = ref.read(currentHexProvider);
    final loaded = {for (final c in widget.cells) c.h3};
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: RepRushTokens.surfaceDark,
      isScrollControlled: true,
      builder: (_) => _TerritorySheet(
        mine: mine,
        here: here,
        currentH3: current?.h3,
        onMap: loaded,
        onPick: (h3) {
          Navigator.pop(context);
          _focusHex(h3);
        },
      ),
    );
  }

  void _focusHex(String h3) {
    _scheduledFocus = null;
    if (!mounted) return;
    ref.read(mapFocusProvider.notifier).clear();
    final cell =
        widget.cells.where((c) => c.h3 == h3).firstOrNull ??
        ref.read(myHexesProvider).current?.where((c) => c.h3 == h3).firstOrNull;
    if (cell == null) return;
    final centre = polygonCentre(cell.polygon);
    _mapController.move(LatLng(centre.lat, centre.lng), _focusZoom);
    setState(() => _flashHex = h3);
    _flash.forward(from: 0);
  }

  void _showSpot(SpotSummary spot) {
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: RepRushTokens.surfaceDark,
      builder: (_) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(RepRushTokens.spaceLg),
          child: ListTile(
            contentPadding: EdgeInsets.zero,
            leading: Icon(
              _spotIcon(spot.type),
              color: RepRushTokens.electricViolet,
            ),
            title: Text(spot.name),
            subtitle: Text(
              '${spot.verified ? 'Verified' : 'Unverified'} spot'
              '${spot.holderHandle == null ? '' : ' · held by ${spot.holderHandle}'}',
            ),
          ),
        ),
      ),
    );
  }

  IconData _spotIcon(SpotType type) => switch (type) {
    SpotType.calisthenicsPark => Icons.sports_gymnastics,
    SpotType.gym => Icons.sports_gymnastics,
    SpotType.pullUpBar => Icons.horizontal_rule,
    SpotType.playground => Icons.child_friendly,
    SpotType.custom => Icons.place,
  };
}

/// The bottom call to action: where you are, and the button that starts a
/// set for that hex.
class _TrainHereCard extends ConsumerWidget {
  const _TrainHereCard({
    required this.current,
    required this.starting,
    required this.onTrain,
  });

  final HexCell? current;
  final bool starting;
  final VoidCallback? onTrain;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final cell = current;
    final inProgress = ref.watch(activeSessionProvider) != null;
    final label = inProgress
        ? 'Return to your set'
        : cell == null
        ? 'Finding your hex…'
        : switch (Ownership.fromWire(
            ownerHandle: cell.ownerHandle,
            yours: cell.yours,
          )) {
            Ownership.yours => 'Defend this hex',
            Ownership.rival => 'Take this hex',
            Ownership.unclaimed => 'Claim this hex',
          };
    return DecoratedBox(
      decoration: BoxDecoration(
        color: RepRushTokens.chrome,
        borderRadius: BorderRadius.circular(RepRushTokens.cornerCard),
        border: Border.all(color: RepRushTokens.brand.withValues(alpha: .25)),
        boxShadow: RepRushTokens.cardShadow,
      ),
      child: Padding(
        padding: const EdgeInsets.all(RepRushTokens.spaceSm + 4),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            CurrentHexLine(cell: cell),
            const SizedBox(height: RepRushTokens.spaceSm + 4),
            BrandButton(
              label: label,
              icon: Icons.sports_gymnastics,
              loading: starting,
              onPressed: onTrain,
            ),
          ],
        ),
      ),
    );
  }
}

/// Top-right status: which kind of hex you are standing in. Tapping it opens
/// that hex's sheet.
class _CurrentHexPill extends StatelessWidget {
  const _CurrentHexPill({required this.current, required this.onTap});

  final HexCell? current;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final cell = current;
    if (cell == null) {
      return const _MapPill(
        icon: Icons.gps_not_fixed,
        text: 'LOCATING…',
        color: Colors.white,
      );
    }
    final ownership = Ownership.fromWire(
      ownerHandle: cell.ownerHandle,
      yours: cell.yours,
    );
    final text = switch (ownership) {
      Ownership.yours => 'IN YOUR HEX',
      Ownership.rival => 'IN RIVAL HEX',
      Ownership.unclaimed => 'IN OPEN HEX',
    };
    return GestureDetector(
      onTap: onTap,
      child: _MapPill(
        icon: Icons.my_location,
        text: text,
        color: ownership.color,
      ),
    );
  }
}

class _MapControls extends StatelessWidget {
  const _MapControls({
    required this.onZoomIn,
    required this.onZoomOut,
    required this.onRecenter,
  });

  final VoidCallback onZoomIn;
  final VoidCallback onZoomOut;
  final VoidCallback onRecenter;

  @override
  Widget build(BuildContext context) => DecoratedBox(
    decoration: BoxDecoration(
      color: RepRushTokens.chrome,
      borderRadius: BorderRadius.circular(14),
      border: Border.all(color: RepRushTokens.brand.withValues(alpha: .25)),
      boxShadow: RepRushTokens.cardShadow,
    ),
    child: Column(
      children: [
        IconButton(
          tooltip: 'Zoom in',
          onPressed: onZoomIn,
          icon: const Icon(Icons.add),
        ),
        IconButton(
          tooltip: 'Recenter on me',
          onPressed: onRecenter,
          color: RepRushTokens.brand,
          icon: const Icon(Icons.my_location),
        ),
        IconButton(
          tooltip: 'Zoom out',
          onPressed: onZoomOut,
          icon: const Icon(Icons.remove),
        ),
      ],
    ),
  );
}

/// The hex detail sheet. Only the hex the athlete is standing in can be
/// trained for; any other hex explains how far away it is instead.
class _HexSheet extends ConsumerWidget {
  const _HexSheet({required this.cell, required this.onTrain});

  final HexCell cell;
  final VoidCallback onTrain;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final current = ref.watch(currentHexProvider);
    final here = ref.watch(hereProvider);
    final sessionActive = ref.watch(activeSessionProvider) != null;
    final isHere = current?.h3 == cell.h3;
    final ownership = Ownership.fromWire(
      ownerHandle: cell.ownerHandle,
      yours: cell.yours,
    );
    final power = cell.power.round();

    final title = switch (ownership) {
      Ownership.yours => 'Your hex',
      Ownership.rival => 'Held by ${cell.ownerHandle}',
      Ownership.unclaimed => 'Unclaimed hex',
    };
    final body = switch (ownership) {
      Ownership.yours =>
        'You hold it with $power power. Power fades over 72 hours, so train '
            'here to keep it.',
      Ownership.rival => '$power power. Out-train them here to take it.',
      Ownership.unclaimed =>
        'Nobody holds this hex yet. One solid set here claims it.',
    };
    final actionLabel = sessionActive
        ? 'Return to your set'
        : switch (ownership) {
            Ownership.yours => 'Defend this hex',
            Ownership.rival => 'Take this hex',
            Ownership.unclaimed => 'Claim this hex',
          };

    String? distance;
    if (!isHere && here != null) {
      final centre = polygonCentre(cell.polygon);
      distance = formatDistance(
        distanceM(here.lat, here.lng, centre.lat, centre.lng),
      );
    }

    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.all(RepRushTokens.spaceLg),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(ownership.icon, color: ownership.color),
                const SizedBox(width: RepRushTokens.spaceSm),
                Flexible(
                  child: Text(
                    title,
                    style: RepRushTokens.sectionTitle,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                if (isHere) ...[
                  const SizedBox(width: RepRushTokens.spaceSm),
                  const _HereBadge(),
                ],
                const Spacer(),
                IconButton(
                  onPressed: () => Navigator.pop(context),
                  icon: const Icon(Icons.close),
                ),
              ],
            ),
            const SizedBox(height: RepRushTokens.spaceSm),
            Text(body, style: Theme.of(context).textTheme.bodyLarge),
            if (distance != null) ...[
              const SizedBox(height: RepRushTokens.spaceSm),
              Row(
                children: [
                  const Icon(Icons.near_me, size: 16, color: Colors.white70),
                  const SizedBox(width: 6),
                  Text('$distance away', style: RepRushTokens.bodyLabel),
                ],
              ),
            ],
            const SizedBox(height: RepRushTokens.spaceMd),
            _HexActivityList(h3: cell.h3),
            const SizedBox(height: RepRushTokens.spaceMd),
            if (isHere)
              BrandButton(
                label: actionLabel,
                icon: Icons.sports_gymnastics,
                onPressed: () {
                  Navigator.pop(context);
                  onTrain();
                },
              )
            else ...[
              const BrandButton(
                label: 'Go there to train',
                icon: Icons.directions_walk,
                onPressed: null,
              ),
              const SizedBox(height: RepRushTokens.spaceSm),
              Text(
                "You can only train for the hex you're standing in.",
                style: RepRushTokens.bodyLabel,
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _HereBadge extends StatelessWidget {
  const _HereBadge();

  @override
  Widget build(BuildContext context) => DecoratedBox(
    decoration: BoxDecoration(
      color: RepRushTokens.brand.withValues(alpha: .16),
      borderRadius: BorderRadius.circular(99),
      border: Border.all(color: RepRushTokens.brand.withValues(alpha: .6)),
    ),
    child: const Padding(
      padding: EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      child: Text(
        "YOU'RE HERE",
        style: TextStyle(
          color: RepRushTokens.brand,
          fontSize: 10,
          fontWeight: FontWeight.w800,
        ),
      ),
    ),
  );
}

class _MapPill extends StatelessWidget {
  const _MapPill({
    required this.icon,
    required this.text,
    required this.color,
    this.trailing,
  });
  final IconData icon;
  final String text;
  final Color color;

  /// A hint that the pill opens something.
  final IconData? trailing;

  @override
  Widget build(BuildContext context) => DecoratedBox(
    decoration: BoxDecoration(
      color: RepRushTokens.chrome,
      borderRadius: BorderRadius.circular(99),
      border: Border.all(color: color.withValues(alpha: .55)),
      boxShadow: RepRushTokens.cardShadow,
    ),
    child: Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 16, color: color),
          const SizedBox(width: 6),
          Flexible(
            child: Text(
              text,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontFamily: RepRushTokens.displayFont,
                color: color,
                fontSize: 14,
                fontWeight: FontWeight.w700,
                letterSpacing: .6,
              ),
            ),
          ),
          if (trailing != null) ...[
            const SizedBox(width: 2),
            Icon(trailing, size: 16, color: color),
          ],
        ],
      ),
    ),
  );
}

/// The nearby-play switch in the map's top row: an eye when hidden, the
/// number of athletes around you when visible. Icon-sized so the owned count
/// and hex status still fit on a narrow phone.
class _PresencePill extends StatelessWidget {
  const _PresencePill({
    required this.visible,
    required this.count,
    required this.onTap,
  });

  final bool visible;
  final int count;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final color = visible ? playerColor : Colors.white70;
    return Semantics(
      button: true,
      label: visible
          ? 'Visible to nearby players, $count around you'
          : 'Hidden from nearby players',
      child: GestureDetector(
        onTap: onTap,
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: RepRushTokens.chrome,
            borderRadius: BorderRadius.circular(99),
            border: Border.all(color: color.withValues(alpha: .55)),
            boxShadow: RepRushTokens.cardShadow,
          ),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  visible ? Icons.people_alt : Icons.visibility_off,
                  size: 16,
                  color: color,
                ),
                if (visible) ...[
                  const SizedBox(width: 4),
                  Text(
                    '$count',
                    style: TextStyle(
                      fontFamily: RepRushTokens.displayFont,
                      color: color,
                      fontSize: 14,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// A compact legend entry — icon + label + count (N9: never colour alone).
class _LegendChip extends StatelessWidget {
  const _LegendChip({required this.ownership, required this.count});
  final Ownership ownership;
  final int count;

  @override
  Widget build(BuildContext context) => DecoratedBox(
    decoration: BoxDecoration(
      color: RepRushTokens.chrome,
      borderRadius: BorderRadius.circular(99),
    ),
    child: Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(ownership.icon, color: ownership.color, size: 12),
          const SizedBox(width: 4),
          Text(
            '${ownership.label} $count',
            style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w700),
          ),
        ],
      ),
    ),
  );
}

/// Your territory, everywhere: every hex you hold, nearest first, each one
/// tappable to fly the map there.
class _TerritorySheet extends StatelessWidget {
  const _TerritorySheet({
    required this.mine,
    required this.here,
    required this.currentH3,
    required this.onMap,
    required this.onPick,
  });

  final List<HexCell> mine;
  final SessionLocation here;
  final String? currentH3;
  final Set<String> onMap;
  final void Function(String h3) onPick;

  double _away(HexCell cell) {
    final centre = polygonCentre(cell.polygon);
    return distanceM(here.lat, here.lng, centre.lat, centre.lng);
  }

  @override
  Widget build(BuildContext context) {
    final sorted = [...mine]..sort((a, b) => _away(a).compareTo(_away(b)));
    final nearby = sorted.where((c) => onMap.contains(c.h3)).length;
    final area = (sorted.length * LeaderboardRow.hexAreaKm2).toStringAsFixed(1);
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.all(RepRushTokens.spaceLg),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Icon(Icons.flag, color: Ownership.yours.color),
                const SizedBox(width: RepRushTokens.spaceSm),
                Expanded(
                  child: Text(
                    'Your territory',
                    style: RepRushTokens.sectionTitle,
                  ),
                ),
                IconButton(
                  onPressed: () => Navigator.pop(context),
                  icon: const Icon(Icons.close),
                ),
              ],
            ),
            Text(
              sorted.isEmpty
                  ? "You don't hold any hexes yet. Train in the hex you're "
                        'standing in to claim your first.'
                  : '${sorted.length} '
                        '${sorted.length == 1 ? 'hex' : 'hexes'} · '
                        '$area km² · $nearby on your map',
              style: RepRushTokens.bodyLabel,
            ),
            const SizedBox(height: RepRushTokens.spaceSm),
            ConstrainedBox(
              constraints: BoxConstraints(
                maxHeight: MediaQuery.sizeOf(context).height * .5,
              ),
              child: ListView(
                shrinkWrap: true,
                children: [
                  for (final cell in sorted)
                    ListTile(
                      contentPadding: EdgeInsets.zero,
                      leading: Icon(
                        Icons.hexagon,
                        color: Ownership.yours.color,
                      ),
                      title: Text(
                        cell.h3 == currentH3
                            ? "You're here"
                            : '${formatDistance(_away(cell))} away',
                        style: const TextStyle(fontWeight: FontWeight.w700),
                      ),
                      subtitle: Text(
                        '${cell.power.round()} power'
                        '${onMap.contains(cell.h3) ? ' · on your map' : ''}',
                        style: RepRushTokens.bodyLabel,
                      ),
                      trailing: const Icon(Icons.chevron_right),
                      onTap: () => onPick(cell.h3),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// The hex's recent sets: who trained here, at what, and what it took.
class _HexActivityList extends ConsumerWidget {
  const _HexActivityList({required this.h3});

  final String h3;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final history = ref.watch(hexHistoryProvider(h3));
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          'Recent activity',
          style: RepRushTokens.sectionTitle.copyWith(fontSize: 18),
        ),
        const SizedBox(height: RepRushTokens.spaceXs),
        switch (history) {
          AsyncData(:final value) when value.isEmpty => Text(
            'No sets here yet. Be the first to train here.',
            style: RepRushTokens.bodyLabel,
          ),
          AsyncData(:final value) => ConstrainedBox(
            constraints: const BoxConstraints(maxHeight: 200),
            child: ListView(
              shrinkWrap: true,
              padding: EdgeInsets.zero,
              children: [for (final set in value) _ActivityRow(set: set)],
            ),
          ),
          AsyncError() => Text(
            "Couldn't load this hex's history.",
            style: RepRushTokens.bodyLabel,
          ),
          _ => const Padding(
            padding: EdgeInsets.all(RepRushTokens.spaceSm),
            child: Center(
              child: SizedBox.square(
                dimension: 18,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
            ),
          ),
        },
      ],
    );
  }
}

class _ActivityRow extends StatelessWidget {
  const _ActivityRow({required this.set});

  final HexActivity set;

  @override
  Widget build(BuildContext context) {
    final what = set.holdSeconds != null
        ? '${set.holdSeconds} s ${movementDisplayName(set.movementId).toLowerCase()}'
        : '${set.reps} ${movementDisplayName(set.movementId).toLowerCase()}'
              '${set.reps == 1 ? '' : 's'}';
    final colour = set.yours ? Ownership.yours.color : Colors.white70;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: Row(
        children: [
          Icon(Icons.fitness_center, size: 16, color: colour),
          const SizedBox(width: RepRushTokens.spaceSm),
          Expanded(
            child: Text.rich(
              TextSpan(
                children: [
                  TextSpan(
                    text: set.yours ? 'You' : set.handle,
                    style: TextStyle(
                      fontWeight: FontWeight.w800,
                      color: set.yours ? colour : null,
                    ),
                  ),
                  TextSpan(text: ' · $what'),
                ],
              ),
              overflow: TextOverflow.ellipsis,
            ),
          ),
          const SizedBox(width: RepRushTokens.spaceSm),
          Text(
            [
              if (set.power != null) '+${set.power!.round()}',
              _ago(set.atMs),
            ].join(' · '),
            style: RepRushTokens.bodyLabel.copyWith(fontSize: 12),
          ),
        ],
      ),
    );
  }

  /// "just now", "12 min ago", "5 h ago", "2 d ago" — coarse on purpose.
  static String _ago(int atMs) {
    final age = DateTime.now().difference(
      DateTime.fromMillisecondsSinceEpoch(atMs),
    );
    if (age.inMinutes < 1) return 'just now';
    if (age.inHours < 1) return '${age.inMinutes} min ago';
    if (age.inDays < 1) return '${age.inHours} h ago';
    return '${age.inDays} d ago';
  }
}
