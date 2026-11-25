{{/*
ODG Infra helper templates.
*/}}

{{/* BTP account provider config name (fixed; referenced by all BTP resources). */}}
{{- define "odg-infra.providerConfigName" -}}
account-provider-config
{{- end -}}

{{/* Subaccount resource name (used for subaccountRef across BTP resources). */}}
{{- define "odg-infra.subaccountRef" -}}
{{ .Values.subaccount.name }}
{{- end -}}
