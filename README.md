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
  --set adminUsers[0].password=YourSecurePassword123 \
  --set database.password=YourDBPassword123

# Or clone locally
git clone https://github.com/brtkwr/magento-helm.git
cd magento-helm
helm install magento ./charts/magento \
  --set magento.host=magento.example.com \
  --set adminUsers[0].password=YourSecurePassword123 \
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
| `magento.currency` | Store currency | `GBP` |
| `magento.language` | Store language | `en_GB` |
| `existingSecret` | Name of existing secret for passwords | `""` |
| `extraEnv` | Extra environment variables for containers | `[]` |
| `adminUsers` | Array of admin users | (see below) |
| `database.password` | MariaDB password (ignored if existingSecret set) | (generated) |
| `gitSync.plugins` | Array of git repos to sync | `[]` |

### Admin Users

The first user in the array is the primary admin (used for `setup:install`). All users are synced on every pod restart.

```yaml
adminUsers:
  - username: admin
    email: admin@example.com
    firstname: Admin
    lastname: User
    password: securepassword123
  - username: developer
    email: dev@example.com
    firstname: Dev
    lastname: User
    password: anotherpassword456
```

**Note:** Roles must be assigned via the Magento admin panel - the CLI doesn't support role assignment.

### Using Existing Secrets

Instead of passing passwords via `--set` or values files, you can reference a pre-existing Kubernetes secret:

```yaml
existingSecret: my-magento-secrets
```

When `existingSecret` is set, the chart will **not** create its own secret and will reference the existing one instead.

**Required secret keys:**

| Key | Description |
|-----|-------------|
| `database-password` | MariaDB root and user password |
| `<passwordKey>` | Password for each admin user (key name specified in values) |

**Creating the secret:**

```bash
kubectl create secret generic my-magento-secrets \
  --namespace magento \
  --from-literal=database-password=MyDBPassword123 \
  --from-literal=admin-password-admin=AdminPass123 \
  --from-literal=admin-password-developer=DevPass456
```

**Example values file with existingSecret:**

```yaml
existingSecret: my-magento-secrets

adminUsers:
  - username: admin
    email: admin@example.com
    firstname: Admin
    lastname: User
    passwordKey: admin-password-admin  # References key in secret
  - username: developer
    email: dev@example.com
    firstname: Dev
    lastname: User
    passwordKey: admin-password-developer

database:
  name: magento
  user: magento
  # password not needed - read from secret
```

### Extra Environment Variables

You can inject additional environment variables into the Magento containers using `extraEnv`. This is useful for API keys or other secrets needed in lifecycle hooks.

```yaml
extraEnv:
  - name: TWO_API_KEY
    valueFrom:
      secretKeyRef:
        name: my-magento-secrets
        key: api-key
  - name: SOME_OTHER_VAR
    value: "static-value"
```

These variables are available in both the `init-setup` container and the main `magento` container, so you can reference them in your `hooks.postSetup` scripts:

```yaml
hooks:
  postSetup: |
    php -r "
      \$key = getenv('TWO_API_KEY');
      // use the key...
    "
```

### Production Example

```yaml
# values-production.yaml
magento:
  host: shop.example.com
  currency: USD
  timezone: America/New_York

adminUsers:
  - username: admin
    email: admin@example.com
    firstname: Admin
    lastname: User
    password: ""  # Set via --set

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
  --set adminUsers[0].password=$ADMIN_PASSWORD \
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

### How it works

1. **Init container** clones the repo with `--one-time` to ensure code exists before setup
2. **Sidecar container** continuously syncs with `--period=60s`
3. **`--link=code`** creates a stable symlink that git-sync maintains (handles worktree hash changes automatically)
4. **Setup scripts** create symlinks from `app/code/Vendor/Module` → `git-sync/plugin/code`

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

### Private Repos

For private repositories, provide credentials:

```yaml
gitSync:
  credentials:
    existingSecret: git-credentials  # Secret with 'token' key containing PAT
  plugins:
    - name: my-plugin
      repo: https://github.com/your-org/private-plugin.git
      branch: main
      path: app/code/YourVendor/Module
```

### Disabling Git-Sync

For production, disable git-sync and bake plugins into your image:

```yaml
gitSync:
  plugins: []
```

### Cache Flush After Sync

Currently, you must manually flush Magento's cache after code changes:

```bash
kubectl exec deploy/magento -c magento -- bin/magento cache:flush
```

**Future enhancement:** The chart may add `--exechook` support to automatically flush cache on every sync.

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

Default admin credentials are set via `adminUsers[0].username` and `adminUsers[0].password`.

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
   - **If missing**: Runs full `setup:install` + copies sample data media + runs `catalog:images:resize`

3. **Lifecycle hooks** - Custom commands run at various stages (configure stores, rebuild CSS, etc.)

This ensures pod restarts are **idempotent** - they complete without manual intervention.

### Lifecycle Hooks

The chart provides hooks to inject custom scripts at different stages:

| Hook | When it runs |
|------|-------------|
| `hooks.preSetup` | Before any setup (both upgrade and install paths) |
| `hooks.postUpgrade` | After `setup:upgrade` on existing installs only |
| `hooks.postInstall` | After `setup:install` on fresh installs only |
| `hooks.postSetup` | After all setup completes (both paths) |

**Lifecycle flow:**

```
Fresh install:          Existing install:
─────────────           ─────────────────
preSetup                preSetup
    ↓                       ↓
setup:install           setup:upgrade
    ↓                       ↓
postInstall             postUpgrade
    ↓                       ↓
postSetup               postSetup
```

**Example:**

```yaml
hooks:
  postSetup: |
    # Create store views
    bin/magento store:create 'Hyva Checkout' hyva || true

    # Configure payment gateway
    bin/magento config:set payment/my_method/active 1 || true

    # Rebuild CSS
    npm --prefix vendor/hyva-themes/magento2-default-theme/web/tailwind/ run build-prod

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

### PVC full / OpenSearch "No space left on device"

**Symptom**: Pod stuck in `Init:CrashLoopBackOff`. OpenSearch init container logs show `java.io.IOException: No space left on device`. The magento init-setup container hangs on "Waiting for OpenSearch..." until it times out.

**Root cause**: Magento's file-based full-page cache (`var/page_cache`) grows unbounded. Crawler bots — especially `meta-webindexer` from Facebook — crawl all layered navigation filter combinations, creating a unique cache entry per combination. With multiple store views and combinatorial filter params, the cache can grow to 8 GB+ with 70k+ files and fill even a generously-sized PVC.

**Diagnosis**: the pod is pending so you can't `kubectl exec` into it. Launch a one-shot debug pod mounted on the same PVC instead:

```bash
kubectl run -n <namespace> pvc-debug --restart=Never --image=busybox \
  --overrides='{"spec":{"containers":[{"name":"pvc-debug","image":"busybox","command":["sh","-c","du -sh /data/* /data/magento/* /data/magento/var/* 2>/dev/null | sort -hr"],"volumeMounts":[{"name":"data","mountPath":"/data"}]}],"volumes":[{"name":"data","persistentVolumeClaim":{"claimName":"<release-name>"}}]}}' \
  && sleep 5 \
  && kubectl logs -n <namespace> pvc-debug \
  && kubectl delete pod -n <namespace> pvc-debug --wait=false
```

**Fix** (clear page cache):

```bash
kubectl run -n <namespace> pvc-clear --restart=Never --image=busybox \
  --overrides='{"spec":{"containers":[{"name":"pvc-clear","image":"busybox","command":["sh","-c","rm -rf /data/magento/var/page_cache/* && echo CLEARED"],"volumeMounts":[{"name":"data","mountPath":"/data"}]}],"volumes":[{"name":"data","persistentVolumeClaim":{"claimName":"<release-name>"}}]}}' \
  && sleep 5 \
  && kubectl logs -n <namespace> pvc-clear \
  && kubectl delete pod -n <namespace> pvc-clear --wait=false \
  && kubectl rollout restart deployment/<release-name> -n <namespace>
```

**Prevention**: block crawlers at your ingress. `robots.txt` is advisory only — `meta-webindexer` ignores it. Example nginx-ingress annotation:

```yaml
ingress:
  annotations:
    nginx.ingress.kubernetes.io/server-snippet: |
      if ($http_user_agent ~* (bot|crawler|spider|meta-webindexer|googlebot|bingbot|facebookexternalhit)) {
        return 403;
      }
```

Longer-term: switch Magento's cache backend to Redis (`cache.frontend.default.backend`) so page cache no longer lives on the PVC, and/or schedule a `bin/magento cache:clean full_page` cron.

### Missing sample-data media / CMS styling broken

**Symptom**: Luma homepage renders as a flat stack of text/images instead of the styled hero banner + promo grid. Broken `<img>` placeholders for `/media/wysiwyg/home/*.jpg` and/or console errors like:

```
Refused to apply style from '.../media/styles.css' because its MIME type
('text/html') is not a supported stylesheet MIME type
```

**Root cause**: Magento's sample data lives in two separate vendor packages and populates the PVC in different places:

| Package | Populates | Chart-level restore on upgrade |
|---|---|---|
| `vendor/magento/sample-data-media` | `pub/media/catalog/product/**`, `pub/media/wysiwyg/**` | Yes (chart ≥ 0.11.1, copied via `cp -rn` in init-setup) |
| `vendor/magento/module-cms-sample-data/fixtures/styles.css` | `pub/media/styles.css` — the actual stylesheet that styles `.block-promo.home-main`, `.block-promo-wrapper`, etc. | **No** — fresh install only, via fixture loader |

The `design/head/includes` core_config_data row injects `<link rel="stylesheet" href="{{MEDIA_URL}}styles.css">` into every page. When the PVC loses `pub/media/styles.css` (e.g. reprovisioned or restored from a backup that didn't include media), the link resolves to a 404 HTML page, browsers reject it for wrong MIME type, and the Luma CMS grid renders unstyled.

**Diagnosis**:

```bash
# Does the page reference the stylesheet?
curl -s https://your-host/ | grep '/media/styles.css'

# Does the stylesheet actually serve as CSS?
curl -sI https://your-host/media/styles.css
# Expect: 200 + content-type: text/css. If 404 or text/html → broken.

# Is the file on disk?
kubectl exec deploy/magento -c magento -- ls -la /var/www/html/pub/media/styles.css

# Is the head-includes config present?
kubectl exec deploy/magento -c magento -- bash -c \
  "mysql -h 127.0.0.1 -u magento -p\"\$MYSQL_PASSWORD\" magento --skip-ssl -e \
   'SELECT path, value FROM core_config_data WHERE path=\"design/head/includes\"'"
```

**Fix**:

```bash
POD=$(kubectl get pod -l app.kubernetes.io/name=magento -o name | head -1)

# 1. Restore the stylesheet from the vendor fixture
kubectl exec -c magento $POD -- bash -c \
  "cp /var/www/html/vendor/magento/module-cms-sample-data/fixtures/styles.css \
      /var/www/html/pub/media/styles.css && \
   chown www-data:www-data /var/www/html/pub/media/styles.css"

# 2. Restore the head-include config if missing
kubectl exec -c magento $POD -- bash -c \
  "mysql -h 127.0.0.1 -u magento -p\"\$MYSQL_PASSWORD\" magento --skip-ssl -e \
   'INSERT INTO core_config_data (scope, scope_id, path, value)
    VALUES (\"default\", 0, \"design/head/includes\",
            \"<link rel=\\\"stylesheet\\\" type=\\\"text/css\\\" media=\\\"all\\\" href=\\\"{{MEDIA_URL}}styles.css\\\" />\")
    ON DUPLICATE KEY UPDATE value=VALUES(value)'"

# 3. Flush config + page cache
kubectl exec -c magento $POD -- \
  runuser -u www-data -- bin/magento cache:clean config full_page
```

Hard reload the page (Cmd/Ctrl+Shift+R) to bypass the browser's cached broken-MIME response.

**For the same PVC also missing `wysiwyg/` or `catalog/product/` contents** (product thumbnails broken, not just the CMS grid): chart ≥ 0.11.1 handles this automatically via idempotent `cp -rn` of `sample-data-media` on init-setup. On older chart versions, restore manually:

```bash
kubectl exec -c magento $POD -- bash -c \
  "cp -rn /var/www/html/vendor/magento/sample-data-media/* /var/www/html/pub/media/ && \
   chown -R www-data:www-data /var/www/html/pub/media && \
   runuser -u www-data -- bin/magento catalog:images:resize"
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
