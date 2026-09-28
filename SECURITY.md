# Security reporting

Do not post vulnerabilities, credentials, private paths, transcripts or raw
telemetry in public issues. Ordinary bugs and feature ideas belong in Issues;
security reports and conduct complaints require separate private routes.

## Release preparation

There is no accepted public 1.0.0 release yet. A configured workflow, passing
tests or development build is not a security certification.

The intended security channel is
[GitHub private vulnerability reporting](https://github.com/rottathiago/tokenotch/security/advisories/new).
It must not be treated as available until the maintainer enables and verifies it.
GitHub offers this feature for public repositories: enable it at public cutover,
verify the report form and maintainer notifications, and complete that check
before announcing the repository or publishing installers.

If the route is unavailable, do not post sensitive details publicly. The
maintainer must establish a verified interim private security route if needed;
publication remains blocked while no actionable private route exists.
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
