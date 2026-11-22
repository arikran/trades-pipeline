{{- define "pipeline.labels" -}}
app.kubernetes.io/name: {{ .name }}
app.kubernetes.io/part-of: pipeline
{{- end }}

{{/* Pod spec shared by producer and consumer. Call with dict "name" "env" "root", optional "grace" and "onePerNode". */}}
{{- define "pipeline.podTemplate" -}}
metadata:
  labels:
    {{- include "pipeline.labels" . | nindent 4 }}
spec:
  serviceAccountName: {{ .name }}
  {{- with .grace }}
  terminationGracePeriodSeconds: {{ . }}
  {{- end }}
  securityContext:
    runAsNonRoot: true
    runAsUser: 10001
    seccompProfile:
      type: RuntimeDefault
  topologySpreadConstraints:
    - maxSkew: 1
      topologyKey: topology.kubernetes.io/zone
      whenUnsatisfiable: ScheduleAnyway
      labelSelector:
        matchLabels:
          app.kubernetes.io/name: {{ .name }}
  {{- if .onePerNode }}
  # Never two of these pods on one node: a dead node would stop both producers, and a new
  # producer cannot backfill what it never saw. With no free node the pod stays Pending.
  # matchLabelKeys: only pods of the same revision count, so during a rollout an old pod does
  # not block a new one, and the surge pod has somewhere to go.
  affinity:
    podAntiAffinity:
      requiredDuringSchedulingIgnoredDuringExecution:
        - topologyKey: kubernetes.io/hostname
          labelSelector:
            matchLabels:
              app.kubernetes.io/name: {{ .name }}
          matchLabelKeys:
            - pod-template-hash
  {{- end }}
  containers:
    - name: {{ .name }}
      image: "{{ index .root.Values.images .name }}:{{ .root.Values.imageTag }}"
      imagePullPolicy: IfNotPresent
      env:
        - name: AWS_REGION
          value: {{ .root.Values.region | quote }}
        - name: AWS_DEFAULT_REGION  # botocore reads only this one
          value: {{ .root.Values.region | quote }}
        - name: KAFKA_BOOTSTRAP
          value: {{ .root.Values.kafka.bootstrap | quote }}
        - name: KAFKA_AUTH
          value: {{ .root.Values.kafka.auth | quote }}
        - name: KAFKA_TOPIC
          value: {{ .root.Values.kafka.topic | quote }}
        - name: HEARTBEAT_FILE
          value: /tmp/heartbeat
        {{- toYaml .env | nindent 8 }}
      securityContext:
        allowPrivilegeEscalation: false
        readOnlyRootFilesystem: true
        capabilities:
          drop: ["ALL"]
      resources:
        {{- toYaml .root.Values.resources | nindent 8 }}
      # Heartbeat file younger than 30s (app/*/healthcheck.py). There is no readiness probe, so the
      # startup probe is what keeps a new pod not Ready until the process has written its first heartbeat.
      startupProbe:
        exec:
          command: ["python", "healthcheck.py"]
        periodSeconds: 10
        failureThreshold: 12
        timeoutSeconds: 5
      livenessProbe:
        exec:
          command: ["python", "healthcheck.py"]
        periodSeconds: 10
        failureThreshold: 3
        timeoutSeconds: 5
      volumeMounts:
        - name: tmp
          mountPath: /tmp
  volumes:
    - name: tmp
      emptyDir: {}
{{- end }}
