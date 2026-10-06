"""The fence function: gRPC runner that plays the gate or the fence.

Each pipeline step picks the role in its input:

    input:
      apiVersion: fence.demo.example.org/v1alpha1
      kind: Input
      step: gate            # gate (before the AI step) or fence (after it)
      operation: diagnose   # diagnose or remediate
"""

import grpc
from crossplane.function import logging, resource, response
from crossplane.function.proto.v1 import run_function_pb2 as fnv1
from crossplane.function.proto.v1 import run_function_pb2_grpc as grpcv1

from function.fence import ALLOWED, fence, gate


class FunctionRunner(grpcv1.FunctionRunnerService):
    """A FunctionRunner handles gRPC RunFunctionRequests."""

    def __init__(self):
        """Create a new FunctionRunner."""
        self.log = logging.get_logger()

    async def RunFunction(self, req: fnv1.RunFunctionRequest, _: grpc.aio.ServicerContext) -> fnv1.RunFunctionResponse:
        """Run the function."""
        rsp = response.to(req)
        given = resource.struct_to_dict(req.input)
        step, operation = given.get("step"), given.get("operation")
        self.log.bind(tag=req.meta.tag, step=step, operation=operation).debug("Running function")
        if operation not in ALLOWED:
            response.fatal(rsp, f"input.operation must be one of {sorted(ALLOWED)}, got {operation!r}")
        elif step == "gate":
            gate(operation, req, rsp)
        elif step == "fence":
            fence(operation, req, rsp)
        else:
            response.fatal(rsp, f"input.step must be gate or fence, got {step!r}")
        return rsp
