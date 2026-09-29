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

## What to include privately

Describe the affected Tokenotch/client/OS versions, impact and a minimal synthetic
reproduction. Review Tokenotch's diagnostic preview before sharing it. Include only
the information necessary to reproduce the issue, never real credentials,
private source, transcripts or unredacted account/configuration exports.

The maintainer will assess reports and coordinate any fixes and disclosure.
There is no guaranteed response time, bounty or external certification.

## Supported versions

The latest published regular release is the target for security fixes, whether
unsigned or Developer ID signed.
Older releases and development snapshots may require an update to receive fixes.
This is best-effort maintenance, not a security certification or response-time
guarantee.
See [release readiness](TASKS.md) and [releasing](docs/releasing.md).
