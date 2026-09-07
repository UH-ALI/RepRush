/// Repository → provider flow tests against the documented stubs.
///
/// Covers the daily-challenge claim flow end to end (G3: explicit claim;
/// `NOT_COMPLETE` before the target, capped XP on success) and the contract
/// shapes of the territory/session stubs.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reprush/core/api/api_providers.dart';
import 'package:reprush/core/api/backend_config.dart';
import 'package:reprush/core/api/stub/stub_repositories.dart';
import 'package:reprush/features/challenges/data/challenges_providers.dart';
import 'package:reprush/features/session/data/session_providers.dart';
import 'package:reprush/features/territory/data/territory_providers.dart';
import 'package:reprush/models/models.dart';

void main() {
  group('territory location', () {
    test('viewport is centered on the supplied coordinates', () {
      final viewport = viewportAround(40.7128, -74.0060);

      expect(viewport.swLat, closeTo(40.6928, 1e-10));
      expect(viewport.swLng, closeTo(-74.0260, 1e-10));
      expect(viewport.neLat, closeTo(40.7328, 1e-10));
      expect(viewport.neLng, closeTo(-73.9860, 1e-10));
    });

    test('stub mode resolves the demo venue without requesting GPS', () async {
      final container = ProviderContainer(
        overrides: [
          backendConfigProvider.overrideWithValue(
            BackendConfig.parse(api: 'stub'),
          ),
        ],
      );
      addTearDown(container.dispose);

      final location = await container.read(territoryLocationProvider.future);

      expect(location.lat, DemoVenue.lat);
      expect(location.lng, DemoVenue.lng);
      expect(location.accuracyM, 0);
    });
  });

  group('daily challenge claim flow', () {
    test(
      'claim fails with NOT_COMPLETE before the target, succeeds after',
      () async {
        final stub = StubChallengesRepository();
        final container = ProviderContainer(
          overrides: [challengesRepositoryProvider.overrideWithValue(stub)],
        );
        addTearDown(container.dispose);

        // Seeded state: "50 squat reps today", 20/50.
        final challenge = await container.read(dailyChallengeProvider.future);
        expect(challenge.description, '50 squat reps today');
        expect(challenge.progress, 20);
        expect(challenge.target, 50);
        expect(challenge.claimed, isFalse);

        // Claiming before completion propagates the contract error code.
        await expectLater(
          container.read(dailyChallengeProvider.notifier).claim(),
          throwsA(
            isA<ApiException>().having(
              (e) => e.code,
              'code',
              ApiErrorCode.notComplete,
            ),
          ),
        );

        // Verified, server-scored progress completes the challenge.
        stub.progress = 50;
        final claim = await container
            .read(dailyChallengeProvider.notifier)
            .claim();
        expect(claim.claimed, isTrue);
        expect(claim.xpAwarded, greaterThan(0)); // capped XP only

        // The provider reflects the claimed state after refresh.
        final updated = await container.read(dailyChallengeProvider.future);
        expect(updated.claimed, isTrue);

        // A second claim is rejected with ALREADY_CLAIMED.
        await expectLater(
          container.read(dailyChallengeProvider.notifier).claim(),
          throwsA(
            isA<ApiException>().having(
              (e) => e.code,
              'code',
              ApiErrorCode.alreadyClaimed,
            ),
          ),
        );
      },
    );
  });

  group('territory stubs match the documented fakes', () {
    test('leaderboard returns a populated 10-row board', () async {
      final container = ProviderContainer();
      addTearDown(container.dispose);

      final rows = await container.read(leaderboardProvider.future);
      expect(rows, hasLength(10));
      expect(rows.first.rank, 1);
      expect(rows.map((r) => r.handle), contains('demo_athlete'));
    });

    test(
      'hexes return mixed ownership with plain-coordinate polygons',
      () async {
        final container = ProviderContainer();
        addTearDown(container.dispose);

        final cells = await container.read(hexesProvider.future);
        expect(cells.length, greaterThanOrEqualTo(90));
        expect(cells.where((c) => c.yours), isNotEmpty);
        expect(cells.where((c) => c.ownerHandle == null), isNotEmpty);
        for (final cell in cells) {
          expect(cell.polygon, hasLength(6));
          expect(cell.polygon.first.lat, isNonNegative);
        }
      },
    );
  });

  group('session lifecycle', () {
    test('start fixes the session context; mocked GPS is rejected', () async {
      final container = ProviderContainer();
      addTearDown(container.dispose);

      expect(container.read(activeSessionProvider), isNull);

      final started = await container
          .read(activeSessionProvider.notifier)
          .start(
            location: const SessionLocation(
              lat: 51.5074,
              lng: -0.1278,
              accuracyM: 12,
            ),
          );
      expect(started.movementConfigVersion, DemoVenue.movementConfigVersion);
      expect(started.hexH3, DemoVenue.demoHexH3);
      expect(
        container.read(activeSessionProvider)?.sessionId,
        started.sessionId,
      );

      // Mocked GPS never opens a session for production accounts (I7).
      await expectLater(
        const StubSessionRepository().start(
          location: const SessionLocation(
            lat: DemoVenue.lat,
            lng: DemoVenue.lng,
            accuracyM: 12,
            isMocked: true,
          ),
        ),
        throwsA(
          isA<ApiException>().having(
            (e) => e.code,
            'code',
            ApiErrorCode.mockedLocationRejected,
          ),
        ),
      );
    });

    test('submit consumes the one-shot session (I2)', () async {
      final container = ProviderContainer();
      addTearDown(container.dispose);

      await container
          .read(activeSessionProvider.notifier)
          .start(
            location: const SessionLocation(
              lat: 51.5074,
              lng: -0.1278,
              accuracyM: 12,
            ),
          );
      final result = await container
          .read(activeSessionProvider.notifier)
          .submit(const {'sessionId': DemoVenue.sessionId});
      expect(result.hexResult?.captured, isTrue);
      expect(result.prs, hasLength(1));
      expect(container.read(activeSessionProvider), isNull);
    });
  });
}
