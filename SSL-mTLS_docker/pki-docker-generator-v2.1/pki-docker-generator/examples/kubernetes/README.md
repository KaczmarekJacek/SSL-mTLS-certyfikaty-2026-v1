# Kubernetes - mTLS Deployment Guide

## Spis treści

- [Przygotowanie certyfikatów](#przygotowanie-certyfikatów)
- [Secrets](#secrets)
- [Deployment](#deployment)
- [Service](#service)
- [Ingress z TLS](#ingress-z-tls)
- [Network Policies](#network-policies)
- [Cert-Manager (produkcja)](#cert-manager-produkcja)

## Przygotowanie certyfikatów

Generator automatycznie tworzy manifesty Kubernetes w `certs/kubernetes/`:

```bash
# Wygeneruj certyfikaty
make all

# Zastosuj secrety
kubectl apply -f certs/kubernetes/tls-secrets.yaml
```

## Secrets

### Automatycznie generowane secrety

**tls-secrets.yaml** zawiera trzy secrety:

```yaml
# 1. TLS Secret (kubernetes.io/tls)
apiVersion: v1
kind: Secret
metadata:
  name: tls-certificates
type: kubernetes.io/tls
data:
  tls.crt: <base64-encoded-server-cert>
  tls.key: <base64-encoded-server-key>
  ca.crt: <base64-encoded-ca-chain>

---
# 2. Java Keystores Secret
apiVersion: v1
kind: Secret
metadata:
  name: java-keystores
type: Opaque
data:
  server-keystore.p12: <base64-encoded>
  client-keystore.p12: <base64-encoded>
  truststore.p12: <base64-encoded>
stringData:
  keystore-password: changeit

---
# 3. Client mTLS Secret
apiVersion: v1
kind: Secret
metadata:
  name: mtls-client
type: Opaque
data:
  client.crt: <base64-encoded>
  client.key: <base64-encoded>
  ca-chain.crt: <base64-encoded>
```

### Ręczne tworzenie secretów

```bash
# TLS Secret
kubectl create secret tls tls-certificates \
  --cert=certs/server/server.crt \
  --key=certs/server/server.key

# Java Keystores
kubectl create secret generic java-keystores \
  --from-file=server-keystore.p12=certs/java-keystores/server-keystore.p12 \
  --from-file=client-keystore.p12=certs/java-keystores/client-keystore.p12 \
  --from-file=truststore.p12=certs/java-keystores/truststore.p12 \
  --from-literal=keystore-password=changeit

# CA Chain jako ConfigMap (publiczny)
kubectl create configmap ca-certificates \
  --from-file=ca-chain.crt=certs/intermediate-ca/certs/ca-chain.crt
```

## Deployment

### deployment.yaml

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: secure-app
  labels:
    app: secure-app
    version: v1
spec:
  replicas: 3
  selector:
    matchLabels:
      app: secure-app
  template:
    metadata:
      labels:
        app: secure-app
        version: v1
      annotations:
        # Automatyczny restart przy zmianie certyfikatów
        checksum/tls: "${TLS_CHECKSUM}"
    spec:
      serviceAccountName: secure-app
      securityContext:
        runAsNonRoot: true
        runAsUser: 1000
        fsGroup: 1000
      
      containers:
        - name: app
          image: my-registry/secure-app:latest
          imagePullPolicy: Always
          
          ports:
            - name: https
              containerPort: 8443
              protocol: TCP
            - name: health
              containerPort: 8080
              protocol: TCP
          
          env:
            - name: SSL_KEYSTORE_PASSWORD
              valueFrom:
                secretKeyRef:
                  name: java-keystores
                  key: keystore-password
            - name: SSL_TRUSTSTORE_PASSWORD
              valueFrom:
                secretKeyRef:
                  name: java-keystores
                  key: keystore-password
            - name: JAVA_OPTS
              value: >-
                -Xms256m -Xmx512m
                -Dserver.ssl.key-store=file:/app/config/ssl/server-keystore.p12
                -Dserver.ssl.trust-store=file:/app/config/ssl/truststore.p12
          
          volumeMounts:
            - name: ssl-certs
              mountPath: /app/config/ssl
              readOnly: true
          
          resources:
            requests:
              memory: "256Mi"
              cpu: "100m"
            limits:
              memory: "512Mi"
              cpu: "500m"
          
          livenessProbe:
            httpGet:
              path: /health/live
              port: health
            initialDelaySeconds: 30
            periodSeconds: 10
          
          readinessProbe:
            httpGet:
              path: /health/ready
              port: health
            initialDelaySeconds: 5
            periodSeconds: 5
          
          securityContext:
            allowPrivilegeEscalation: false
            readOnlyRootFilesystem: true
            capabilities:
              drop:
                - ALL
      
      volumes:
        - name: ssl-certs
          secret:
            secretName: java-keystores
            defaultMode: 0400
            items:
              - key: server-keystore.p12
                path: server-keystore.p12
              - key: truststore.p12
                path: truststore.p12
      
      affinity:
        podAntiAffinity:
          preferredDuringSchedulingIgnoredDuringExecution:
            - weight: 100
              podAffinityTerm:
                labelSelector:
                  matchLabels:
                    app: secure-app
                topologyKey: kubernetes.io/hostname
```

## Service

### service.yaml

```yaml
apiVersion: v1
kind: Service
metadata:
  name: secure-app
  labels:
    app: secure-app
spec:
  type: ClusterIP
  ports:
    - name: https
      port: 443
      targetPort: https
      protocol: TCP
    - name: health
      port: 8080
      targetPort: health
      protocol: TCP
  selector:
    app: secure-app
```

### Headless Service (dla mTLS między Podami)

```yaml
apiVersion: v1
kind: Service
metadata:
  name: secure-app-headless
  labels:
    app: secure-app
spec:
  type: ClusterIP
  clusterIP: None
  ports:
    - name: https
      port: 8443
      targetPort: https
  selector:
    app: secure-app
```

## Ingress z TLS

### Nginx Ingress

```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: secure-app-ingress
  annotations:
    nginx.ingress.kubernetes.io/ssl-passthrough: "true"
    nginx.ingress.kubernetes.io/backend-protocol: "HTTPS"
    # Opcjonalnie: mTLS na poziomie Ingress
    nginx.ingress.kubernetes.io/auth-tls-verify-client: "on"
    nginx.ingress.kubernetes.io/auth-tls-secret: "default/mtls-client"
spec:
  ingressClassName: nginx
  tls:
    - hosts:
        - api.example.com
      secretName: tls-certificates
  rules:
    - host: api.example.com
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: secure-app
                port:
                  number: 443
```

### Traefik IngressRoute

```yaml
apiVersion: traefik.io/v1alpha1
kind: IngressRoute
metadata:
  name: secure-app-route
spec:
  entryPoints:
    - websecure
  routes:
    - match: Host(`api.example.com`)
      kind: Rule
      services:
        - name: secure-app
          port: 443
          scheme: https
          serversTransport: mtls-transport
  tls:
    secretName: tls-certificates
    options:
      name: mtls-options
      namespace: default

---
apiVersion: traefik.io/v1alpha1
kind: TLSOption
metadata:
  name: mtls-options
spec:
  minVersion: VersionTLS12
  clientAuth:
    secretNames:
      - mtls-client
    clientAuthType: RequireAndVerifyClientCert

---
apiVersion: traefik.io/v1alpha1
kind: ServersTransport
metadata:
  name: mtls-transport
spec:
  serverName: secure-app.default.svc.cluster.local
  rootCAsSecrets:
    - tls-certificates
  certificatesSecrets:
    - mtls-client
```

## Network Policies

### Ograniczenie ruchu do mTLS

```yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: secure-app-policy
spec:
  podSelector:
    matchLabels:
      app: secure-app
  policyTypes:
    - Ingress
    - Egress
  
  ingress:
    # Tylko z Ingress Controller
    - from:
        - namespaceSelector:
            matchLabels:
              name: ingress-nginx
          podSelector:
            matchLabels:
              app.kubernetes.io/name: ingress-nginx
      ports:
        - protocol: TCP
          port: 8443
    
    # Health checks z kubelet
    - from: []
      ports:
        - protocol: TCP
          port: 8080
  
  egress:
    # DNS
    - to:
        - namespaceSelector: {}
          podSelector:
            matchLabels:
              k8s-app: kube-dns
      ports:
        - protocol: UDP
          port: 53
    
    # Inne secure serwisy
    - to:
        - podSelector:
            matchLabels:
              mtls: enabled
      ports:
        - protocol: TCP
          port: 8443
```

## Cert-Manager (produkcja)

### Instalacja

```bash
kubectl apply -f https://github.com/cert-manager/cert-manager/releases/download/v1.14.0/cert-manager.yaml
```

### ClusterIssuer z własnym CA

```yaml
apiVersion: cert-manager.io/v1
kind: Secret
metadata:
  name: ca-key-pair
  namespace: cert-manager
type: Opaque
data:
  tls.crt: <base64-encoded-intermediate-ca-crt>
  tls.key: <base64-encoded-intermediate-ca-key>

---
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: internal-ca-issuer
spec:
  ca:
    secretName: ca-key-pair
```

### Certificate Resource

```yaml
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: secure-app-cert
  namespace: default
spec:
  secretName: secure-app-tls
  duration: 2160h  # 90 dni
  renewBefore: 360h  # 15 dni przed wygaśnięciem
  
  commonName: secure-app.default.svc.cluster.local
  dnsNames:
    - secure-app
    - secure-app.default
    - secure-app.default.svc
    - secure-app.default.svc.cluster.local
    - "*.secure-app.default.svc.cluster.local"
  
  ipAddresses:
    - 127.0.0.1
  
  privateKey:
    algorithm: RSA
    size: 4096
  
  usages:
    - server auth
    - client auth
  
  issuerRef:
    name: internal-ca-issuer
    kind: ClusterIssuer
```

### Certificate dla klienta mTLS

```yaml
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: mtls-client-cert
  namespace: default
spec:
  secretName: mtls-client-auto
  duration: 720h  # 30 dni
  renewBefore: 168h  # 7 dni
  
  commonName: client@example.com
  
  privateKey:
    algorithm: RSA
    size: 4096
  
  usages:
    - client auth
    - digital signature
    - key encipherment
  
  issuerRef:
    name: internal-ca-issuer
    kind: ClusterIssuer
```

## Monitoring

### ServiceMonitor dla Prometheus

```yaml
apiVersion: monitoring.coreos.com/v1
kind: ServiceMonitor
metadata:
  name: secure-app-monitor
spec:
  selector:
    matchLabels:
      app: secure-app
  endpoints:
    - port: health
      path: /actuator/prometheus
      interval: 30s
      scheme: http
```

## Troubleshooting

```bash
# Sprawdź certyfikaty w Secret
kubectl get secret java-keystores -o yaml

# Dekoduj certyfikat
kubectl get secret tls-certificates -o jsonpath='{.data.tls\.crt}' | base64 -d | openssl x509 -text -noout

# Sprawdź logi SSL
kubectl logs -l app=secure-app | grep -i ssl

# Test połączenia z wewnątrz klastra
kubectl run -it --rm debug --image=curlimages/curl -- \
  curl --cert /tmp/client.crt --key /tmp/client.key \
  --cacert /tmp/ca-chain.crt \
  https://secure-app:443/api/health

# Sprawdź NetworkPolicy
kubectl describe networkpolicy secure-app-policy
```
