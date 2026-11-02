# Security

Report vulnerabilities privately through GitHub's "Report a vulnerability" (Security tab) instead of a public issue.
Kelp runs locally: `kelpd` listens on a Unix socket in `~/.kelp` and makes no network calls of its own besides the tools
you configure (`git`, `gh`, `glab`, agents), the trackers you sign in to (Linear, Jira, Bitbucket), update checks, and the
extension library when you open it (`curl`).
