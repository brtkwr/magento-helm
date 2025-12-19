# Magento Helm Chart

Deploy Magento 2.4.8 on Kubernetes with git-sync support for live plugin development.

## Features

- Magento 2.4.8 Community Edition with sample data (2000+ products)
- Single-pod deployment with MariaDB and OpenSearch sidecars
- Git-sync sidecars for live code updates during development
- Configurable via Helm values

## Quick Start

```bash
# Using OCI registry
helm install magento oci://ghcr.io/brtkwr/charts/magento \
  --set magento.host=magento.example.com \
  --set magento.adminPassword=YourSecurePassword123 \
  --set database.password=YourDBPassword123

# Or clone locally
git clone https://github.com/brtkwr/magento-helm.git
cd magento-helm
helm install magento ./charts/magento \
  --set magento.host=magento.example.com \
  --set magento.adminPassword=YourSecurePassword123 \
  --set database.password=YourDBPassword123
```

## Prerequisites

- Kubernetes 1.24+
- Helm 3.x
- PersistentVolume provisioner
- Ingress controller (nginx, traefik, etc.)

## Configuration

See [values.yaml](charts/magento/values.yaml) for all options.

### Common Settings

| Parameter | Description | Default |
|-----------|-------------|---------|
| `magento.host` | Store URL hostname | `magento.example.com` |
| `magento.adminUser` | Admin username | `admin` |
| `magento.adminPassword` | Admin password | (generated) |
| `magento.currency` | Store currency | `GBP` |
| `magento.language` | Store language | `en_GB` |
| `database.password` | MariaDB password | (generated) |
| `gitSync.plugins` | Array of git repos to sync | `[]` |

### Production Example

```yaml
# values-production.yaml
magento:
  host: shop.example.com
  adminEmail: admin@example.com
  currency: USD
  timezone: America/New_York

ingress:
  enabled: true
  className: nginx
  annotations:
    cert-manager.io/cluster-issuer: letsencrypt-prod
  tls:
    enabled: true

resources:
  magento:
    requests:
      memory: "2Gi"
      cpu: "1000m"
    limits:
      memory: "4Gi"
      cpu: "4000m"
```

```bash
helm install magento oci://ghcr.io/brtkwr/charts/magento \
  -f values-production.yaml \
  --set magento.adminPassword=$ADMIN_PASSWORD \
  --set database.password=$DB_PASSWORD
```

## Architecture

```
┌─────────────────────────────────────────────────────────┐
│ Pod: magento                                            │
├─────────────────────────────────────────────────────────┤
│ ┌─────────────┐ ┌─────────────┐ ┌─────────────────────┐ │
│ │  Magento    │ │  MariaDB    │ │    OpenSearch       │ │
│ │  PHP+Apache │ │    10.6     │ │       2.19          │ │
│ └─────────────┘ └─────────────┘ └─────────────────────┘ │
│ ┌─────────────────────────────────────────────────────┐ │
│ │              git-sync (optional)                    │ │
│ └─────────────────────────────────────────────────────┘ │
└─────────────────────────────────────────────────────────┘
         │                │                │
         ▼                ▼                ▼
┌─────────────────────────────────────────────────────────┐
│              PersistentVolumeClaim                      │
│  /data/mysql  │  /data/opensearch  │  /data/magento    │
└─────────────────────────────────────────────────────────┘
```

## Git-Sync for Live Development

The chart supports git-sync sidecars for live plugin development. Changes pushed to your repo are reflected within 60 seconds.

### Configuration

```yaml
gitSync:
  plugins:
    - name: my-plugin
      repo: https://github.com/your-org/your-magento-plugin.git
      branch: main
      path: app/code/YourVendor/Module
```

### Multiple Plugins

```yaml
gitSync:
  plugins:
    - name: custom-shipping
      repo: https://github.com/your-org/magento-shipping.git
      branch: main
      path: app/code/YourVendor/Shipping
    - name: custom-payment
      repo: https://github.com/your-org/magento-payment.git
      branch: develop
      path: app/code/YourVendor/Payment
```

### Disabling Git-Sync

For production, disable git-sync and bake plugins into your image:

```yaml
gitSync:
  plugins: []
```

## Docker Images

Public images are available at:

| Image | Description |
|-------|-------------|
| `ghcr.io/brtkwr/magento-base:php8.2` | PHP 8.2 + Apache + extensions |
| `ghcr.io/brtkwr/magento:2.4.8` | Magento + sample data |

### Building Custom Images

To add custom modules or themes:

```bash
cd docker/

# Create auth.json with repo.magento.com credentials
cat > auth.json << 'EOF'
{
  "http-basic": {
    "repo.magento.com": {
      "username": "YOUR_PUBLIC_KEY",
      "password": "YOUR_PRIVATE_KEY"
    }
  }
}
EOF

# Build base image
docker buildx build -f Dockerfile.base \
  -t your-registry/magento-base:php8.2 --push .

# Build Magento image
docker buildx build \
  --secret id=composer_auth,src=auth.json \
  -t your-registry/magento:2.4.8 --push .
```

Then update your Helm values:

```yaml
image:
  repository: your-registry/magento
  tag: "2.4.8"
```

## Accessing the Store

After deployment:

| URL | Description |
|-----|-------------|
| `https://your-host/` | Storefront |
| `https://your-host/admin` | Admin Panel |
| `https://your-host/health_check.php` | Health Check |

Default admin credentials are set via `magento.adminUser` and `magento.adminPassword`.

## Persistence & Restarts

The chart persists data across pod restarts using a PVC with the following mounts:

| Mount Path | PVC Subpath | Purpose |
|------------|-------------|---------|
| `/var/www/html/var` | `magento/var` | Logs, cache, sessions |
| `/var/www/html/pub/media` | `magento/media` | Uploaded media files |
| `/var/www/html/app/etc` | `magento/etc` | `env.php`, `config.php` |

### How Restarts Work

1. **`init-etc` container** - On first boot, copies default `app/etc` from the Docker image to the PVC. On subsequent boots, preserves existing files (including `env.php`).

2. **Setup script** - Detects if Magento is already installed by checking for `app/etc/env.php`:
   - **If exists**: Runs `setup:upgrade` + `di:compile` (fast upgrade path)
   - **If missing**: Runs full `setup:install` (initial installation)

3. **postScript** - Custom commands run after setup (configure stores, rebuild CSS, etc.)

This ensures pod restarts are **idempotent** - they complete without manual intervention.

### Custom Post-Setup Commands

Use `postScript` for commands that should run after every restart:

```yaml
postScript: |
  bin/magento config:set payment/my_method/active 1 || true
  bin/magento cache:flush
```

Use `|| true` for commands that may fail during initial setup (e.g., config paths that don't exist yet).

## Troubleshooting

### Check setup logs

```bash
kubectl exec deploy/magento -c magento -- tail -f /var/www/html/var/log/setup.log
```

### Fix permissions

```bash
kubectl exec deploy/magento -c magento -- \
  chown -R www-data:www-data /var/www/html/var /var/www/html/generated
```

### Flush cache

```bash
kubectl exec deploy/magento -c magento -- bin/magento cache:flush
```

### Reindex

```bash
kubectl exec deploy/magento -c magento -- bin/magento indexer:reindex
```

### Check module status

```bash
kubectl exec deploy/magento -c magento -- bin/magento module:status
```

## Contributing

1. Fork the repository
2. Create a feature branch
3. Make your changes
4. Submit a pull request

## License

MIT License - see [LICENSE](LICENSE) for details.

## Links

- [Magento Documentation](https://experienceleague.adobe.com/docs/commerce.html)
- [Helm Documentation](https://helm.sh/docs/)
- [git-sync](https://github.com/kubernetes/git-sync)
