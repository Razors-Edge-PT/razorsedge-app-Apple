'use strict';

// Input for the golden V2 snapshot (showcase_v2_sample.json), which the Dart
// suite (test/profile_showcase_v2_test.dart) parses as real server output.
// Regenerate the golden only deliberately; showcase_v2.test.js asserts it.

const w = (exerciseId, sets) => ({ exerciseId, name: 'x', sets });

const SAMPLE_WEIGH_INS = [['2026-01-01', 80]];

const SAMPLE_HISTORY = {
  // Before any weigh-in: recorded, but points unavailable.
  '2025-12-01': { exercises: [w('LGhFj8o0sG3X12296UAh', [{ weight: 140, reps: 8 }])] },
  '2026-01-05': {
    exercises: [
      w('AmfUWbF1DH3I7qPAdh5k', [{ weight: 100, reps: 1, id: 'b1' }]),
      w('kTs5fLSTKjUkUZL10iii', [{ weight: 50, reps: 1 }]),
      w('XM9026peNIu0R8qh7UqY', [{ weight: 20, reps: 1, setIndex: 0 }]),
      w('1XOIXxeLFhgmgjZS9Cyq', [{ weight: 90, reps: 1 }]),
    ],
  },
  '2026-01-12': {
    exercises: [
      w('RdsGazgdH0xgpjek0n3u', [{ weight: 30, reps: 1 }]),
      w('FtayDmR5BVnGS1FXlXLL', [{ weight: 0, reps: 1, setIndex: 0 }]),
      w('MsGl7e9yanDeEnYX0e4X', [{ weight: 200, reps: 1 }]),
      w('10pEctikt6PP8eAg9Eip', [{ weight: 200, reps: 1 }]),
      w('VUEvvjuo4cxBghNuux66', [{ weight: 100, reps: 3 }]),
    ],
  },
};

module.exports = { SAMPLE_HISTORY, SAMPLE_WEIGH_INS };
