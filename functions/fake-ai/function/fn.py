"""The fake-ai function: a stand-in for a misbehaving model, for the Q&A demo.

It returns whatever proposals its input holds, the way function-openai returns
the model's reply, so `./demo.sh fence` can show the real fence rejecting them:

    input:
      apiVersion: fakeai.demo.example.org/v1alpha1
      kind: Input
      proposals: [ ...objects... ]
"""

import grpc
from crossplane.function import logging, resource, response
from crossplane.function.proto.v1 import run_function_pb2 as fnv1
from crossplane.function.proto.v1 import run_function_pb2_grpc as grpcv1


class FunctionRunner(grpcv1.FunctionRunnerService):
    """A FunctionRunner handles gRPC RunFunctionRequests."""

    def __init__(self):
        """Create a new FunctionRunner."""
        self.log = logging.get_logger()

    async def RunFunction(self, req: fnv1.RunFunctionRequest, _: grpc.aio.ServicerContext) -> fnv1.RunFunctionResponse:
        """Run the function."""
        self.log.bind(tag=req.meta.tag).debug("Running function")
        rsp = response.to(req)
        for i, proposal in enumerate(resource.struct_to_dict(req.input).get("proposals", [])):
            resource.update(rsp.desired.resources[f"ai-{i}"], proposal)
        return rsp
