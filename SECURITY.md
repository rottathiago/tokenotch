# Security reporting

Do not post vulnerabilities, credentials, private paths, transcripts or raw
telemetry in public issues. Ordinary bugs and feature ideas belong in Issues;
security reports and conduct complaints require separate private routes.

## Release preparation

There is no accepted public 1.0.0 release yet. A configured workflow, passing
tests or development build is not a security certification.

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

No stable version is currently declared supported. Before publishing 1.0.0, update
this policy to identify the accepted stable version and its actual maintenance
scope. Development builds are not supported production releases.
See [release readiness](TASKS.md) and [releasing](docs/releasing.md).
