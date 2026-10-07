# fence

The deterministic steps around the AI step in both WatchOperations (`gate → think → fence`). The **gate** decides whether the model needs to be asked at all; the **fence** throws away whatever the model proposed and rebuilds the change from an allowlist, or applies nothing. The logic is in `function/fence.py`; each pipeline step sets `step` and `operation` in its input.
