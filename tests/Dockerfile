# Test runner for the Python functions. Same Python and SDK as function-python v0.6.0.
FROM python:3.13-slim
RUN pip install --no-cache-dir crossplane-function-sdk-python==0.15.1 pytest==8.*
WORKDIR /src
ENTRYPOINT ["python", "-m", "pytest", "-q", "tests/fence"]
