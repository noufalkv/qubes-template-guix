# Qubes channel substitute-cache signing key

`signing-key.pub` is the public Ed25519 key for substitutes built and signed by
`.github/workflows/substitute-cache.yml`.  GitHub Actions builds, signs, and
distributes the cache: Pages serves the small v2 narinfo index and versioned,
asset-count-bounded Releases serve the immutable NAR payloads.

The v2 URL and key form a clean epoch.  Nothing from the retired cache produced
before the [July 2 substitute/pull advisory][advisory] is imported.  Template
consumption was enabled only after the first v2 publication was independently
verified.

[advisory]: https://guix.gnu.org/en/blog/2026/guix-substitute-pull-vulnerabilities/

It is stored as a **bare canonical s-expression with no comments** on purpose:
both `guix archive --authorize` and the template's `local-file` +
`authorized-keys` wiring read it directly, and `guix archive --authorize`
rejects a key file that contains comments ("Bad character in S-expression").

## Trust model

Clients authenticate cache contents with this key rather than GitHub's
transport identity.  GitHub Actions remains trusted to build the cache and
protect the private key.  The template authorizes the public key and adds the
Pages URL to `guix-daemon` (see
`%qubes-substitute-cache-url`, `%qubes-substitute-cache-key-file`, and the
`%qubes-substitute-cache-enabled?` flag in `(qubes services)`).  The current,
advisory-checked Guix daemon verifies the signed narinfo and NAR hash before
installing a substitute.

The workflow uses signed Guix 1.5 only to authenticate current Guix source,
builds a minimal native daemon from that source, and checks the security floor
before enabling official substitutes.  It then runs all four official advisory
checks around the unpinned pull.  Qubes/Guix evaluation completes before the
private cache key is restored; the later export phase only signs already
realized store paths.

## Refresh and retention

Actions resolves the current unpinned Guix and Qubes channel heads daily.  Each
new generation reuses existing content-addressed assets, splits new NARs across
bounded, content-identified Release shards, then publishes the retained narinfo
index atomically through Pages.

The [ci.guix.gnu.org configuration][guix-publisher] sets `guix publish`'s TTL
to 180 days, while [Bordeaux's cleanup][guix-bordeaux] protects new objects for
six months.  Guix does not guarantee availability for the full TTL: an
unaccessed publisher-cache entry can become removable after that period when
its store item is gone.  GitHub exposes neither access times nor store
references, so this cache uses a deterministic policy: retain generations for
180 days and always keep at least eight.  After an expired generation leaves
Pages, a marker made only after the deployment is verified starts a two-day
cleanup grace period for its metadata and NAR shards.  This exceeds Guix's
36-hour fallback TTL for cached positive narinfo lookups, so a client can still
download a NAR referenced by its cached metadata.  Dependencies omitted because
an official server already supplied them remain subject to that server's
retention policy.

GitHub may disable scheduled workflows after 60 days without repository
activity.  Keep the schedule monitored; if GitHub disables it, a maintainer
must re-enable it before `workflow_dispatch` can provide a manual refresh.

[guix-publisher]: https://codeberg.org/guix/maintenance/src/branch/master/hydra/modules/sysadmin/services.scm
[guix-bordeaux]: https://codeberg.org/guix/maintenance/src/branch/master/hydra/bayfront.scm
[guix-publish]: https://guix.gnu.org/manual/en/html_node/Invoking-guix-publish.html

## Private key

The matching private key is **not committed**. It must live in the
`github-pages` environment secret `GUIX_SIGNING_KEY_SEC` so only the
branch-restricted publication environment can expose it to the signing step.
Treat it as a long-lived cache key and rotate it only with the cache epoch as
described below.

## Rotation (breaking change)

Rotating the key invalidates every published narinfo signature and every
template that authorized the old key.  Start a new URL/metadata epoch, update
`GUIX_SIGNING_KEY_SEC` and `signing-key.pub` together, publish a clean cache,
then rebuild templates against the new key.

## Regenerate

Run on a machine with Guix (writes a bare `.pub` and `.sec`):

```sh
guix repl <<'EOF'
(use-modules (gcrypt pk-crypto))
(let ((pair (generate-key
             (sexp->canonical-sexp
              '(genkey (ecc (curve Ed25519) (flags rfc6979)))))))
  (call-with-output-file "signing-key.pub"
    (lambda (p)
      (display (canonical-sexp->string (find-sexp-token pair 'public-key)) p)))
  (call-with-output-file "signing-key.sec"
    (lambda (p)
      (display (canonical-sexp->string (find-sexp-token pair 'private-key)) p))))
EOF
```
