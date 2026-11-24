# AGENTS.md

This repo is a public, general-purpose Helm chart and image set for Magento 2.
Anyone must be able to use it without knowing anything about Two or its
partners. Read this before changing anything under `charts/`, `docker/` or the
README, and before reviewing a PR that does.

## No Two-specific logic, ever

Nothing that only makes sense for Two, a Two partner or a Two shop is committed
here. That covers:

- Business logic, payment-plugin config, partner or customer names, and
  anything that names a specific plugin's admin tabs, config paths or tables.
- Hostnames, store names, environment names (staging, beta and so on), cluster
  names, namespaces and internal URLs.
- People's names and email addresses, issue-tracker ticket ids (`ABC-123`),
  Slack channels and links to private repos.
- Credentials of any kind, real or example.
- Private registries in install instructions. The README must work for someone
  outside Two.

What to do instead:

- **Shop-specific behaviour** goes behind a generic values flag, off by
  default, named for what it does (`cron.enabled`, not `shop.recovery`). The
  deployer switches it on in values kept in its own repository, never here.
- **A workaround for one plugin's bug** belongs in that plugin. If the chart
  must carry it, make it a generic, documented hook (for example "flush caches
  after `di:compile`"), not code that names the plugin.
- **Comments** explain why in generic terms. No ticket ids: link the upstream
  Magento or Helm issue when there is one.
- **Examples** use `example.com`, `admin@example.com` and placeholder values.

There are two exceptions. `.github/workflows/` is where this repo is built and
published, so it can use two-inc's CI plumbing: registries, Workload Identity,
org variables and two-inc actions. And this file names Two, because the rule
can't be stated without doing so. Keep the plumbing out of everything that
ships in the chart or an image.

## Reviewing

Any Two-specific string or behaviour outside `.github/` and this file is a blocking finding.
Say what to generalise it into, using the rules above.
