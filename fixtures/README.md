# Release fixtures — not part of any release

Packages here are deliberately OUT of the build set: `build.sh` scans
`metadata/<name>/specs/*.yaml`, so nothing under `fixtures/` is ever built,
published, or installed.

## libnss-resolve

Removed from the release on 2026-08-14. It was never a Globular runtime
prerequisite — systemd-resolved's stub already serves cluster names over
ordinary DNS once our `resolved.conf.d` route exists, and Go services bypass NSS
entirely. Proven on a pinned Ubuntu Noble release-20260518 image
(systemd 255.4-1ubuntu8.15) with the module genuinely absent.

The tracked `debs/libnss-resolve_255.4-1ubuntu8.16_amd64.deb` is kept **on
purpose**, as a permanent regression fixture. Deleting a dependency must not
delete the knowledge of why it was dangerous:

    libnss-resolve 8.16  Depends: systemd-resolved (= 255.4-1ubuntu8.16)
    baseline 8.15        provides: systemd-resolved   255.4-1ubuntu8.15
    => UNSATISFIABLE, assembly must refuse

That deb broke Day-1 joins twice (2026-08-10, 2026-08-14). The defect was never
the version — it was pinning a base-image package by exact equality while that
package is deliberately never bundled. Any re-added pinned version fails the
same way; see
`services/golang/globularcli/pkgpack/debprovenance_test.go:TestRegression_LibnssResolve816AgainstBaseline815`.
