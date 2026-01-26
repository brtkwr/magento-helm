# Magento Helm — AI Agent Context

## Project Overview

Helm chart for deploying Magento applications to Kubernetes, including all necessary infrastructure components.

- **Chart Type**: Helm 3 chart
- **Purpose**: Deploy Magento with PHP-FPM, Nginx, Redis, Elasticsearch, etc.
- **Platform**: Kubernetes (GKE)

## Directory Structure

```
templates/          # Kubernetes resource templates
values.yaml         # Default values
Chart.yaml          # Chart metadata
```

## Development Notes

- Helm 3 chart following standard conventions
- Supports multiple environments via values overrides
- Includes init containers for setup tasks
- Configures Magento-specific components (PHP-FPM, cron, message consumers)
- Integrates with external services (database, cache, search)

## Testing

```bash
helm template . -f values.yaml              # Render templates
helm lint .                                 # Lint chart
helm install magento . -f values.yaml --dry-run --debug  # Dry run
```

## Common Patterns

- Use `.Values` for all configurable settings
- Include resource limits and requests
- Use init containers for database migrations and setup
- ConfigMaps for Magento configuration
- Secrets for sensitive data (database passwords, API keys)
