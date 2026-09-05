{{/* Chart name, overridable. */}}
{{- define "app.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{/* Fully qualified app name. */}}
{{- define "app.fullname" -}}
{{- if .Values.fullnameOverride -}}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" -}}
{{- else -}}
{{- $name := default .Chart.Name .Values.nameOverride -}}
{{- if contains $name .Release.Name -}}
{{- .Release.Name | trunc 63 | trimSuffix "-" -}}
{{- else -}}
{{- printf "%s-%s" .Release.Name $name | trunc 63 | trimSuffix "-" -}}
{{- end -}}
{{- end -}}
{{- end -}}

{{- define "app.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "app.labels" -}}
helm.sh/chart: {{ include "app.chart" . }}
{{ include "app.selectorLabels" . }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end -}}

{{- define "app.selectorLabels" -}}
app.kubernetes.io/name: {{ include "app.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end -}}

{{- define "app.serviceAccountName" -}}
{{- if .Values.serviceAccount.create -}}
{{- default (include "app.fullname" .) .Values.serviceAccount.name -}}
{{- else -}}
{{- default "default" .Values.serviceAccount.name -}}
{{- end -}}
{{- end -}}

{{/*
Guard: blueGreen and canary are mutually exclusive progressive-delivery
strategies. Rendering both would produce two controllers owning the same pods.
Every workload template calls this first so a bad values file fails at render
time (in CI / Argo CD diff) rather than in the cluster.
*/}}
{{- define "app.validateStrategy" -}}
{{- if and .Values.blueGreen.enabled .Values.canary.enabled -}}
{{- fail "blueGreen.enabled and canary.enabled are mutually exclusive - enable at most one" -}}
{{- end -}}
{{- end -}}

{{/*
The full image reference. Both halves arrive as Argo CD Helm parameters, so an
empty value means the configure stage did not patch the Application - fail loudly
instead of rendering a chart that pulls ":".
*/}}
{{- define "app.image" -}}
{{- if not .Values.image.repository -}}
{{- fail "image.repository is empty - it must be supplied as an Argo CD Helm parameter" -}}
{{- end -}}
{{- if not .Values.image.tag -}}
{{- fail "image.tag is empty - it must be supplied as an Argo CD Helm parameter (never committed to values.yaml)" -}}
{{- end -}}
{{- printf "%s:%s" .Values.image.repository .Values.image.tag -}}
{{- end -}}
