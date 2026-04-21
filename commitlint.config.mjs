// Commit type convention for macf-actions — mirrors groundnuty/macf's
// 13-type enum for consistency. Release notes derivation + `git log
// --grep='^security\|^reliability'` are most useful when commit
// subjects follow the same vocabulary across the two repos.
//
// See groundnuty/macf#15 for the parity rationale.
//
//   feat         — new consumer-visible feature (new routing event,
//                  new v-tag entry point, etc.)
//   fix          — bug fix (no security implication)
//   security     — security fix (vulnerability, hardening)
//   reliability  — observability / robustness hardening
//   refactor     — behavior-preserving restructure
//   perf         — performance improvement
//   docs         — documentation only
//   test         — tests only
//   chore        — tooling, build, meta (non-consumer-facing)
//   ci           — CI changes (this repo's own CI, not the shipped workflow)
//   build        — build system changes
//   style        — formatting only
//   revert       — revert a prior commit

export default {
  extends: ['@commitlint/config-conventional'],
  rules: {
    'type-enum': [2, 'always', [
      'feat', 'fix', 'security', 'reliability',
      'refactor', 'perf', 'docs', 'test',
      'chore', 'ci', 'revert', 'build', 'style',
    ]],
  },
};
