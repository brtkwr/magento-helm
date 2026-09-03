{{/*
Expand the name of the chart.
*/}}
{{- define "magento.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Create a default fully qualified app name.
*/}}
{{- define "magento.fullname" -}}
{{- if .Values.fullnameOverride }}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- $name := default .Chart.Name .Values.nameOverride }}
{{- if contains $name .Release.Name }}
{{- .Release.Name | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- printf "%s-%s" .Release.Name $name | trunc 63 | trimSuffix "-" }}
{{- end }}
{{- end }}
{{- end }}

{{/*
Create chart name and version as used by the chart label.
*/}}
{{- define "magento.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Common labels
*/}}
{{- define "magento.labels" -}}
helm.sh/chart: {{ include "magento.chart" . }}
{{ include "magento.selectorLabels" . }}
{{- if .Chart.AppVersion }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
{{- end }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

{{/*
Selector labels
*/}}
{{- define "magento.selectorLabels" -}}
app.kubernetes.io/name: {{ include "magento.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{/*
Secret name - uses existingSecret if provided, otherwise uses fullname
*/}}
{{- define "magento.secretName" -}}
{{- if .Values.existingSecret }}
{{- .Values.existingSecret }}
{{- else }}
{{- include "magento.fullname" . }}
{{- end }}
{{- end }}

{{/*
ServiceAccount name — the provided name, else the fullname when created,
else "default". Lets a pod run under a Workload-Identity-bound SA.
*/}}
{{- define "magento.serviceAccountName" -}}
{{- if .Values.serviceAccount.create }}
{{- default (include "magento.fullname" .) .Values.serviceAccount.name }}
{{- else }}
{{- default "default" .Values.serviceAccount.name }}
{{- end }}
{{- end }}

{{/*
git-sync auth env — GitHub App private key (preferred) or static token.
git-sync mints AND refreshes the App installation token itself, so a
short-lived App token works for the continuously-running sync sidecar.
Rendered into both the init and sidecar git-sync containers.
*/}}
{{- define "magento.gitSyncAuthEnv" -}}
{{- if .Values.gitSync.credentials.githubApp.installationId }}
- name: GITSYNC_GITHUB_APP_PRIVATE_KEY
  valueFrom:
    secretKeyRef:
      name: {{ .Values.gitSync.credentials.githubApp.privateKey.existingSecret }}
      key: {{ .Values.gitSync.credentials.githubApp.privateKey.key | default "private-key" }}
{{- else if or .Values.gitSync.credentials.token .Values.gitSync.credentials.existingSecret }}
- name: GITSYNC_USERNAME
  value: x-access-token
- name: GITSYNC_PASSWORD
  valueFrom:
    secretKeyRef:
      {{- if .Values.gitSync.credentials.existingSecret }}
      name: {{ .Values.gitSync.credentials.existingSecret }}
      key: {{ .Values.gitSync.credentials.existingSecretKey | default "token" }}
      {{- else }}
      name: {{ include "magento.fullname" . }}
      key: git-token
      {{- end }}
{{- end }}
{{- end }}

{{/*
Shell helpers for atomic static-content deploys (A/B slot flip). Rendered
into both init-setup.sh and setup.sh so the two scripts share one
implementation. Requires the `mage` wrapper to be defined by the caller.
*/}}
{{- define "magento.staticSlotsShell" -}}
# --- atomic static-content deploy (A/B slot flip) --------------------------
#
# pub/static is a SYMLINK to one of two real slot directories, pub/static-a
# and pub/static-b. A deploy builds into the IDLE slot and goes live with a
# single rename(2) of the symlink, so no request ever observes a missing or
# half-populated pub/static.
#
# Why: setup:static-content:deploy empties pub/static and only rewrites it
# ~2 minutes later, and it bumps deployed_version.txt at the START of that
# window. Under MAGE_MODE=production every /static/ URL 404s for the
# duration and the storefront 500s with "Unable to retrieve deployment
# version of static files from the file system". With git-sync rotations
# firing every few minutes that is a near-permanent outage on a busy branch.
#
# Magento is pointed at the idle slot with the CLI bootstrap override
# --bootstrap=MAGE_DIRS[static][path]=<abs path>. Framework\Console\Cli
# parses --bootstrap out of argv (ComplexParameter) and merges it into the
# init params that build DirectoryList, which accepts absolute paths. The
# override is probed with --refresh-content-version-only before any real
# build depends on it; if this image does not honour it the caller falls
# back to the historical in-place deploy, so the worst case is today's
# behaviour rather than a broken one.
SC_PUB=/var/www/html/pub
SC_LINK="$SC_PUB/static"
SC_SNAP=/var/www/html/var/.pub-static-prev
SC_MODE=inplace          # set to "slot" by sc_deploy once a flip has happened
SC_PREV_SLOT=""          # slot that was live before the last flip
SC_HAVE_PREV=false

# Name of the slot pub/static currently points at ("" if not converted).
sc_slot_live() {
  case "$(basename "$(readlink "$SC_LINK" 2>/dev/null || true)")" in
    static-a) echo static-a ;;
    static-b) echo static-b ;;
    *) echo "" ;;
  esac
}

# The other slot — the one a build may write to. Two slots only: the old
# live slot is reused as the next build target, so nothing accumulates.
sc_slot_idle() {
  if [ "$(sc_slot_live)" = "static-a" ]; then echo static-b; else echo static-a; fi
}

# Repoint pub/static at slot $1 with a single rename(2) (mv -T over a
# symlink), which is atomic: readers see either the old or the new target.
sc_flip() {
  local slot="$1" tmp="$SC_PUB/.static-next.$$"
  rm -f "$tmp"
  ln -s "$SC_PUB/$slot" "$tmp" || return 1
  mv -Tf "$tmp" "$SC_LINK" || { rm -f "$tmp"; return 1; }
}

# Convert pub/static to the slot layout, idempotently, and recover from a
# half-converted state left behind by a crash. Safe to re-run on every boot.
sc_slots_init() {
  mkdir -p "$SC_PUB/static-a" "$SC_PUB/static-b" || return 1

  # Recovery: pub/static gone entirely (crash between the two renames below).
  if [ ! -e "$SC_LINK" ] && [ ! -L "$SC_LINK" ]; then
    if [ -d "$SC_PUB/.static-preslot" ]; then
      echo "sc: pub/static missing — restoring pre-conversion directory"
      mv -T "$SC_PUB/.static-preslot" "$SC_LINK" || return 1
    else
      echo "sc: pub/static missing — pointing it at static-a"
      sc_flip static-a || return 1
      return 0
    fi
  fi

  if [ -L "$SC_LINK" ]; then
    # Already converted; repair a dangling or foreign target.
    if [ -z "$(sc_slot_live)" ] || [ ! -d "$SC_LINK" ]; then
      echo "sc: pub/static symlink dangling or foreign — pointing it at static-a"
      sc_flip static-a || return 1
    fi
    return 0
  fi

  if [ ! -d "$SC_LINK" ]; then
    echo "sc: pub/static is neither a directory nor a symlink — refusing to convert"
    return 1
  fi

  # First conversion on this pod: pub/static is a real directory. Hardlink it
  # into slot a — same filesystem, so no data is copied and no extra disk is
  # used — then swap the directory for the symlink. This runs in the init
  # container before Apache accepts traffic; the only non-atomic moment is
  # the rename pair below, and it is undone on failure.
  echo "sc: converting pub/static to the A/B slot layout"
  rm -rf "$SC_PUB/static-a" && mkdir -p "$SC_PUB/static-a" || return 1
  cp -al "$SC_LINK/." "$SC_PUB/static-a/" 2>/dev/null \
    || cp -a "$SC_LINK/." "$SC_PUB/static-a/" || return 1
  rm -rf "$SC_PUB/.static-preslot"
  mv -T "$SC_LINK" "$SC_PUB/.static-preslot" || return 1
  sc_flip static-a || {
    echo "sc: flip failed during conversion — restoring the original directory"
    mv -T "$SC_PUB/.static-preslot" "$SC_LINK"
    return 1
  }
  rm -rf "$SC_PUB/.static-preslot"
  chown -R www-data:www-data "$SC_PUB/static-a" "$SC_PUB/static-b" 2>/dev/null || true
  echo "sc: pub/static -> static-a"
}

# Cheap check that this image honours the static-path override before a real
# build relies on it. --refresh-content-version-only only writes
# deployed_version.txt, so it costs a second or two. If the override is
# ignored the file lands in the live slot instead, which is just a content
# version bump (harmless — pub/static/.htaccess strips version<N>/ from
# asset URLs) and the caller falls back to the in-place deploy.
sc_probe_override() {
  local slot="$1"
  rm -f "$SC_PUB/$slot/deployed_version.txt"
  mage setup:static-content:deploy -f --refresh-content-version-only \
    "--bootstrap=MAGE_DIRS[static][path]=$SC_PUB/$slot" >/dev/null 2>&1 || return 1
  [ -s "$SC_PUB/$slot/deployed_version.txt" ]
}

# Build into the idle slot and flip. Returns:
#   0  flipped; SC_PREV_SLOT holds the slot to roll back to
#   1  build failed; the live slot was never touched, nothing flipped
#   2  layout or override unavailable; caller should fall back in place
sc_deploy_slot() {
  sc_slots_init || return 2
  local live idle
  live="$(sc_slot_live)"
  idle="$(sc_slot_idle)"
  [ -n "$live" ] || return 2

  # Seed the idle slot from the live one: the build then only writes what
  # actually changed, and anything the image ships (pub/static/.htaccess,
  # which carries the version<N>/ rewrite) is present regardless of what the
  # deploy chooses to touch.
  rsync -a --delete "$SC_PUB/$live/" "$SC_PUB/$idle/" || return 2

  sc_probe_override "$idle" || {
    echo "sc: image does not honour --bootstrap=MAGE_DIRS[static][path] — falling back to in-place deploy"
    return 2
  }

  local sc_failed=false
  {{- range $.Values.staticContentDeploy.areas }}
  echo "sc: deploying area={{ . }} locales: {{ join " " $.Values.staticContentDeploy.locales }} into $idle"
  if ! mage setup:static-content:deploy -f --area={{ . }} {{ join " " $.Values.staticContentDeploy.locales }} \
       "--bootstrap=MAGE_DIRS[static][path]=$SC_PUB/$idle"; then
    echo "ERROR: static-content:deploy failed for area={{ . }}"
    sc_failed=true
  fi
  {{- end }}
  if $sc_failed; then
    echo "ALERT: build into $idle failed — pub/static still points at $live, nothing flipped"
    return 1
  fi

  # deployed_version.txt is the file whose absence 500s the storefront and
  # trips the liveness probe. It must be in the target BEFORE the flip.
  if [ ! -s "$SC_PUB/$idle/deployed_version.txt" ]; then
    echo "ALERT: $idle/deployed_version.txt missing after deploy — refusing to flip"
    return 1
  fi
  if [ ! -f "$SC_PUB/$idle/.htaccess" ] && [ -f "$SC_PUB/$live/.htaccess" ]; then
    cp -a "$SC_PUB/$live/.htaccess" "$SC_PUB/$idle/.htaccess" || true
  fi
  chown -R www-data:www-data "$SC_PUB/$idle" 2>/dev/null || true

  sc_flip "$idle" || { echo "ALERT: flip to $idle failed — still serving $live"; return 1; }
  SC_MODE=slot
  SC_PREV_SLOT="$live"
  echo "sc: static content live from $idle (previous: $live, kept for rollback)"
  # The in-place rollback snapshot is redundant once we are flipping, and it
  # costs ~500M of writes into the var PVC on every rotation.
  rm -rf "$SC_SNAP"
}

# Historical behaviour: snapshot, purge-and-rebuild in place, restore the
# snapshot if the build fails. Retained as the fallback path.
sc_deploy_inplace() {
  SC_MODE=inplace
  SC_HAVE_PREV=false
  # .htaccess is the only thing the chart ships, so treat "only .htaccess
  # present" as effectively empty.
  if [ -d "$SC_LINK" ] \
     && [ -n "$(ls -A "$SC_LINK" 2>/dev/null | grep -v '^\.htaccess$' || true)" ]; then
    rsync -a --delete "$SC_LINK/" "$SC_SNAP/" && SC_HAVE_PREV=true
  fi
  local sc_failed=false
  {{- range $.Values.staticContentDeploy.areas }}
  echo "sc: deploying area={{ . }} locales: {{ join " " $.Values.staticContentDeploy.locales }} in place"
  if ! mage setup:static-content:deploy -f --area={{ . }} {{ join " " $.Values.staticContentDeploy.locales }}; then
    echo "ERROR: static-content:deploy failed for area={{ . }}"
    sc_failed=true
  fi
  {{- end }}
  if $sc_failed; then
    sc_rollback
    return 1
  fi
}

# Deploy static content the safest way available.
sc_deploy() {
  # ABN-423: a root-mode `bin/magento` call outside the mage() wrapper (e.g.
  # a manual `kubectl exec` fix) leaves root-owned entries under
  # var/view_preprocessed/. The next www-data-scoped deploy then aborts
  # partway through with "<path> is not writable", silently truncating
  # pub/static/ to whichever themes/locales it reached before the fault.
  chown -R www-data:www-data var/ generated/ pub/static/ 2>/dev/null || true
  {{- if $.Values.staticContentDeploy.atomicSwap }}
  local rc=0
  sc_deploy_slot || rc=$?
  case "$rc" in
    0) return 0 ;;
    2) sc_deploy_inplace ;;
    *) return 1 ;;
  esac
  {{- else }}
  sc_deploy_inplace
  {{- end }}
}

# Undo the most recent sc_deploy. In slot mode this is a flip back to the
# previously live slot: instant, complete, and it cannot itself fail
# half-way, unlike the rsync restore it replaces.
sc_rollback() {
  if [ "$SC_MODE" = slot ] && [ -n "$SC_PREV_SLOT" ]; then
    echo "sc: rolling back to $SC_PREV_SLOT"
    sc_flip "$SC_PREV_SLOT" || return 1
    return 0
  fi
  if $SC_HAVE_PREV && [ -d "$SC_SNAP" ]; then
    echo "sc: rolling pub/static/ back to the previous snapshot"
    rsync -a --delete "$SC_SNAP/" "$SC_LINK/" || true
  else
    echo "sc: no rollback target available"
  fi
}
# --- end atomic static-content deploy -------------------------------------
{{- end }}

{{/*
Shell helpers guarding the full-rebuild path (rm -rf generated/ +
setup:di:compile). Rendered into both init-setup.sh (startup self-heal) and
setup.sh (rotation-rebuild) so both share one implementation. Requires the
`mage` wrapper. An OOMKilled compile leaves generated/ wiped
but not rebuilt, which is a live fatal, not a clean restart-time error.
*/}}
{{- define "magento.diCompileGuardShell" -}}
# --- di:compile guard (floor check + class-instantiation smoke test) ------
DC_GENERATED=/var/www/html/generated
DC_LASTGOOD=/var/www/html/var/.generated-lastgood
DC_FLOOR={{ .Values.gitSync.reload.diCompileGuard.generatedCodeFloor }}

dc_entry_count() {
  find "$DC_GENERATED/code" -mindepth 1 -maxdepth 1 2>/dev/null | wc -l
}

# Instantiate a handful of known DI-heavy classes via the object manager.
# setup:di:compile has no static check for "does this class's compiled
# constructor-arg map still match its current __construct signature" — that
# only surfaces as a TypeError the first time something resolves the class,
# which for a payment method's Config\Backend classes is the admin config
# page. Catch it here instead of in the admin's browser tab.
dc_smoke_test() {
  {{- $classes := .Values.gitSync.reload.diCompileGuard.smokeTestClasses }}
  {{- if not $classes }}
  return 0
  {{- else }}
  runuser -u www-data -- php -r "
    require 'app/bootstrap.php';
    \$b = Magento\Framework\App\Bootstrap::create(BP, \$_SERVER);
    \$om = \$b->getObjectManager();
    \$classes = [
      {{- range $classes }}
      '{{ . | replace "\\" "\\\\" }}',
      {{- end }}
    ];
    \$failed = [];
    foreach (\$classes as \$c) {
      if (!class_exists(\$c)) { continue; }
      try { \$om->create(\$c); } catch (\Throwable \$e) { \$failed[] = \"\$c: \" . \$e->getMessage(); }
    }
    if (\$failed) { fwrite(STDERR, implode(\"\n\", \$failed) . \"\n\"); exit(1); }
  " 2>&1
  {{- end }}
}

# Snapshot a verified-good generated/ onto the PVC (var/ subPath, survives
# pod restarts) so a future interrupted compile has something to fall back
# to. Only ever called after dc_recompile's own floor+smoke checks pass.
dc_snapshot_lastgood() {
  mkdir -p "$DC_LASTGOOD/code" "$DC_LASTGOOD/metadata"
  rsync -a --delete "$DC_GENERATED/code/" "$DC_LASTGOOD/code/" 2>/dev/null || true
  rsync -a --delete "$DC_GENERATED/metadata/" "$DC_LASTGOOD/metadata/" 2>/dev/null || true
}

# Restore generated/ from the last verified-good snapshot. Used at pod
# startup when generated/ is below the floor and no rebuild is in flight —
# the case an in-container ERR/EXIT trap can never handle, because an
# OOMKill is a SIGKILL to the whole container, not just the compile step.
dc_restore_lastgood() {
  [ -d "$DC_LASTGOOD/code" ] && [ -n "$(ls -A "$DC_LASTGOOD/code" 2>/dev/null)" ] || return 1
  rm -rf "$DC_GENERATED/code" "$DC_GENERATED/metadata"
  mkdir -p "$DC_GENERATED/code" "$DC_GENERATED/metadata"
  rsync -a "$DC_LASTGOOD/code/" "$DC_GENERATED/code/"
  rsync -a "$DC_LASTGOOD/metadata/" "$DC_GENERATED/metadata/"
}

{{- if .Values.gitSync.reload.diCompileGuard.alertOnFailure }}
# Kubernetes Event, in addition to the log line — `kubectl get events` and
# any Warning-event watcher (many on-call setups pipe these to Slack) see
# it; a log line inside the pod does not. Uses the pod's own mounted
# ServiceAccount token; the namespace's Role must grant `create` on
# `events` for that ServiceAccount (not part of this chart).
dc_emit_event() {
  local msg="$1" sa=/var/run/secrets/kubernetes.io/serviceaccount
  [ -r "$sa/token" ] || return 0
  local ns; ns=$(cat "$sa/namespace" 2>/dev/null) || return 0
  local now; now=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  local body
  body=$(printf '{"apiVersion":"v1","kind":"Event","metadata":{"generateName":"di-compile-guard-"},"involvedObject":{"kind":"Pod","namespace":"%s","name":"%s"},"reason":"DiCompileGuardFailed","message":%s,"type":"Warning","firstTimestamp":"%s","lastTimestamp":"%s","count":1,"source":{"component":"di-compile-guard"}}' \
    "$ns" "$(hostname)" "$(printf '%s' "$msg" | python3 -c 'import json,sys;print(json.dumps(sys.stdin.read()))' 2>/dev/null || echo '"'"$msg"'"')" "$now" "$now")
  curl -sS -o /dev/null --cacert "$sa/ca.crt" -H "Authorization: Bearer $(cat "$sa/token")" \
    -H 'Content-Type: application/json' -X POST \
    "https://kubernetes.default.svc/api/v1/namespaces/$ns/events" -d "$body" || true
}
{{- else }}
dc_emit_event() { :; }
{{- end }}

dc_alert() {
  echo "ALERT: $1"
  dc_emit_event "$1"
}

# Full rebuild + verify. Returns 0 only once di:compile has succeeded AND
# passed both the entry-count floor and the smoke test — at which point
# generated/ is snapshotted as the new last-known-good. Returns 1 on any
# failure; generated/ is left as-is (wiped, possibly mid-compile) and it is
# the caller's job to decide whether to restore from the last snapshot.
dc_recompile() {
  mage setup:upgrade || { dc_alert "setup:upgrade failed ahead of di:compile"; return 1; }
  rm -rf "$DC_GENERATED"/code/* "$DC_GENERATED/metadata" 2>/dev/null || true
  if ! mage setup:di:compile; then
    dc_alert "setup:di:compile failed"
    return 1
  fi
  local n; n=$(dc_entry_count)
  if [ "$n" -lt "$DC_FLOOR" ]; then
    dc_alert "generated/code has only $n entries after di:compile (floor: $DC_FLOOR) -- treating the compile as failed"
    return 1
  fi
  local smoke_out
  if ! smoke_out=$(dc_smoke_test); then
    dc_alert "post-compile smoke test failed: $smoke_out"
    return 1
  fi
  dc_snapshot_lastgood
}
# --- end di:compile guard ---------------------------------------------------
{{- end }}
