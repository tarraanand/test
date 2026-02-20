Subject: Addressing OOM Kills - Resource Configuration Best Practices

Hi Team,

I've noticed we're experiencing frequent OOM (Out of Memory) kills and receiving requests to increase memory limits. I found that requests and limits are not equal in most of our resource configurations.

I'd like to share some best practices to help prevent these issues:

1. Set Memory Requests = Limits
When requests ≠ limits, pods get Burstable QoS class and are first to be evicted under node memory pressure. Setting them equal gives Guaranteed QoS class which is stable and predictable.

# ❌ Current: requests ≠ limits (Burstable QoS - prone to OOM/eviction)
resources:
  requests:
    memory: "256Mi"
  limits:
    memory: "1Gi"

# ✅ Recommended: requests = limits (Guaranteed QoS - stable and predictable)
resources:
  requests:
    memory: "512Mi"
  limits:
    memory: "512Mi"
2. Use VPA in "Off" Mode for Right-Sizing
Instead of guessing memory values, use VPA (Vertical Pod Autoscaler) in "Off" mode. VPA in Auto mode restarts pods which can cause downtime. Off mode gives recommendations without disruption.

apiVersion: autoscaling.k8s.io/v1
kind: VerticalPodAutoscaler
metadata:
  name: my-app-vpa
spec:
  targetRef:
    apiVersion: apps/v1
    kind: Deployment
    name: my-app
  updatePolicy:
    updateMode: "Off"  # Recommendations only, no restarts

3. Use HPA + Karpenter for Scaling
Many teams avoid VPA Auto mode and instead use HPA + Karpenter:

HPA → Scale pods horizontally (more replicas)
Karpenter → Scale nodes efficiently

apiVersion: autoscaling/v2
kind: HorizontalPodAutoscaler
metadata:
  name: my-app-hpa
spec:
  scaleTargetRef:
    apiVersion: apps/v1
    kind: Deployment
    name: my-app
  minReplicas: 2
  maxReplicas: 10
  metrics:
    - type: Resource
      resource:
        name: memory
        target:
          type: Utilization
          averageUtilization: 80

4. CPU: Set Requests Only, No Limits
For CPU, the best practice in large-scale Kubernetes is to set requests only, no limits. This prevents unnecessary CPU throttling while allowing apps to burst when needed.

# ✅ Complete recommended configuration
Resource	Best Practice	Reason
Memory	requests = limits	Prevents OOM kills, Guaranteed QoS
CPU	requests only, no limits	Prevents throttling, allows bursting
This approach will significantly reduce OOM kills and improve application stability.

Let me know if you have any questions!

For CPU, the best practice in large-scale Kubernetes is to set requests only, no limits. This prevents unnecessary CPU throttling while allowing apps to burst when needed.