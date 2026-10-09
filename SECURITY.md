# Security reporting

Do not post vulnerabilities, credentials, private paths, transcripts or raw
telemetry in public issues. Ordinary bugs and feature ideas belong in Issues;
security reports and conduct complaints require separate private routes.

## Release security

A configured workflow, passing tests or published release is not a security
certification.
Public unsigned releases are allowed and are covered by this reporting process.
Signing and notarization are optional and do not replace security review.

Use
[GitHub private vulnerability reporting](https://github.com/rottathiago/tokenotch/security/advisories/new).
It is enabled for this public repository. Sign in to GitHub to submit a private
report; it is shared with the repository maintainer rather than posted as a
public issue.

If the route is unavailable, do not post sensitive details publicly. The
maintainer must restore private reporting or establish a verified interim
private security route before further release announcements.
Conduct reporting is not handled through security advisories.

## Automated monitoring

Dependabot alerts and security updates monitor the repository's dependency graph.
Secret scanning and push protection help detect supported credential patterns.
CodeQL default setup uses the extended query suite for GitHub Actions,
JavaScript/TypeScript, Python, Rust and Swift. The Dependency review workflow
checks pull requests for dependencies with known vulnerabilities.

Review findings privately where appropriate; do not copy secrets into logs,
issues or pull requests. These checks do not cover every vulnerability, replace
manual review or certify a release as secure.

## What to include privately

Describe the affected Tokenotch/client/OS versions, impact and a minimal synthetic
reproduction. Review Tokenotch's diagnostic preview before sharing it. Include only
the information necessary to reproduce the issue, never real credentials,
private source, transcripts or unredacted account/configuration exports.

The maintainer will assess reports and coordinate any fixes and disclosure.
There is no guaranteed response time, bounty or external certification.

## Supported versions

The latest published regular release **for each platform** is the target for
security fixes, whether unsigned or signed. Windows releases use separate
`v<version>-windows` tags; GitHub's overall "latest" release remains the macOS
release so existing macOS download and update links keep working.
Older releases and development snapshots may require an update to receive fixes.
This is best-effort maintenance, not a security certification or response-time
guarantee.
See [release readiness](TASKS.md) and [releasing](docs/releasing.md).
