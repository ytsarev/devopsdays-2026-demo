# compose-cache

Composition logic for `Cache`: look the cost center up in the CostCenter registry. Found: compose a ConfigMap, a Valkey Deployment and a Service. Not found: compose nothing, keep the Cache not Ready, and say why with a condition and an event. The logic is in `function/compose.py`.
