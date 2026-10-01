/// The dark basemap under the territory hexes.
///
/// TWO SOURCES, CHOSEN AT BUILD TIME:
///
///   - Stadia "Alidade Smooth Dark" when `--dart-define=REPRUSH_STADIA_KEY=…`
///     is set (free tier; sign up at stadiamaps.com). Served at @2x, so streets
///     and labels are sharp on a 3× phone screen, from a CDN, as ONE layer.
///     This is the demo build.
///   - Esri "Dark Gray Canvas" otherwise — keyless, but 256 px JPEG tiles, so
///     softer on high-density screens. One layer only (its base already carries
///     street names), which halves the requests a flaky venue network has to
///     survive.
///
/// Both are tinted toward the app's navy with ONE ColorFiltered around the
/// whole layer — not one per tile, which costs a compositing layer per tile
/// and shows up as jank while panning.
///
/// Rejected: CARTO Dark Matter answers keyless requests with an "API KEY
/// REQUIRED" image under HTTP 200 (fails silently); vector tiles
/// (`vector_map_tiles`) only resolve to a beta for flutter_map 8.
///
/// Ownership: C (ui).
library;

import 'package:flutter/widgets.dart';
import 'package:flutter_map/flutter_map.dart';

const _stadiaKey = String.fromEnvironment('REPRUSH_STADIA_KEY');

/// True when the sharp Stadia basemap is compiled in.
bool get hasStadiaBasemap => _stadiaKey.isNotEmpty;

/// The attribution each source's terms require, shown on the map.
String get basemapAttribution => hasStadiaBasemap
    ? '© Stadia Maps © OpenMapTiles\n© OpenStreetMap'
    : 'Powered by Esri\n© OpenStreetMap';

/// Pulls a neutral dark-grey basemap toward the app's navy (surfaceDark)
/// while keeping road/label contrast: each channel is a scaled copy of the
/// tile's luminance plus a blue-leaning offset.
const _navyTint = ColorFilter.matrix(<double>[
  0.55, 0, 0, 0, 0, //
  0, 0.60, 0, 0, 2, //
  0, 0, 0.75, 0, 14, //
  0, 0, 0, 1, 0, //
]);

/// The basemap as a single flutter_map layer.
Widget basemapLayer(BuildContext context) {
  final layer = hasStadiaBasemap
      ? TileLayer(
          urlTemplate:
              'https://tiles.stadiamaps.com/tiles/alidade_smooth_dark/'
              '{z}/{x}/{y}{r}.png?api_key=$_stadiaKey',
          // `{r}` → "@2x" on high-density screens: real 512 px tiles.
          retinaMode: RetinaMode.isHighDensity(context),
          maxNativeZoom: 20,
          userAgentPackageName: 'com.example.reprush',
          evictErrorTileStrategy:
              EvictErrorTileStrategy.notVisibleRespectMargin,
        )
      : TileLayer(
          urlTemplate:
              'https://services.arcgisonline.com/ArcGIS/rest/services/Canvas/'
              'World_Dark_Gray_Base/MapServer/tile/{z}/{y}/{x}',
          // Published to z16; deeper zooms upscale rather than 404.
          maxNativeZoom: 16,
          userAgentPackageName: 'com.example.reprush',
          // A tile that failed on a flaky network is dropped once it leaves
          // the screen, so panning back re-requests it instead of keeping a
          // permanent hole.
          evictErrorTileStrategy:
              EvictErrorTileStrategy.notVisibleRespectMargin,
        );
  return ColorFiltered(colorFilter: _navyTint, child: layer);
}
