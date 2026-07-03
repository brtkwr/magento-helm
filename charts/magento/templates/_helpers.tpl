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
