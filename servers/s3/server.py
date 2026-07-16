#!/usr/bin/env python3
"""S3 Storage MCP Server -- exposes list_objects and get_object tools.

Connects to MinIO (S3-compatible storage) and serves tool calls over
Streamable HTTP on port 3001. Part of the Healthcare Radiology Edge Demo.

Usage:
    cd servers/s3
    .venv/bin/python server.py
    # Server starts at http://127.0.0.1:3001/mcp
"""

import base64
import mimetypes
import os
import time

import boto3
from botocore.client import Config
from dotenv import load_dotenv
from mcp.server.fastmcp import FastMCP
from mcp.server.transport_security import TransportSecuritySettings
from starlette.requests import Request
from starlette.responses import JSONResponse

# Load .env from repo root (two levels up from servers/s3/)
_script_dir = os.path.dirname(os.path.abspath(__file__))
_env_path = os.path.join(_script_dir, "..", "..", ".env")
load_dotenv(_env_path)

# Initialize FastMCP server on port 3001
mcp = FastMCP(
    "S3 Storage Server",
    host="127.0.0.1",
    port=3001,
    json_response=True,
    transport_security=TransportSecuritySettings(
        enable_dns_rebinding_protection=True,
        allowed_hosts=["127.0.0.1:*", "localhost:*", "[::1]:*", "s3.local", "s3.local:*"],
    ),
)

# Create module-level boto3 S3 client (NOT resource -- resource API freezes with MinIO)
s3 = boto3.client(
    "s3",
    endpoint_url=os.getenv("MINIO_ENDPOINT", "http://localhost:9000"),
    aws_access_key_id=os.getenv("MINIO_ACCESS_KEY", "minioadmin"),
    aws_secret_access_key=os.getenv("MINIO_SECRET_KEY", "minioadmin"),
    config=Config(signature_version="s3v4"),
    region_name="us-east-1",
)


def _guess_content_type(key: str) -> str:
    """Infer MIME type from file extension, defaulting to application/octet-stream."""
    content_type, _ = mimetypes.guess_type(key)
    return content_type or "application/octet-stream"


@mcp.tool()
def list_objects(bucket_name: str = "radiology-images") -> dict:
    """List all objects in the specified S3 bucket with metadata."""
    start = time.time()

    response = s3.list_objects_v2(Bucket=bucket_name)

    objects = [
        {
            "key": obj["Key"],
            "size_bytes": obj["Size"],
            "content_type": _guess_content_type(obj["Key"]),
        }
        for obj in response.get("Contents", [])
    ]

    latency_ms = round((time.time() - start) * 1000, 2)

    return {
        "objects": objects,
        "count": len(objects),
        "latency_ms": latency_ms,
    }


@mcp.tool()
def get_object(key: str, bucket_name: str = "radiology-images") -> dict:
    """Retrieve an object from S3 and return its base64-encoded content."""
    start = time.time()

    response = s3.get_object(Bucket=bucket_name, Key=key)
    data = response["Body"].read()
    b64_data = base64.b64encode(data).decode("utf-8")

    latency_ms = round((time.time() - start) * 1000, 2)

    return {
        "key": key,
        "bucket_name": bucket_name,
        "content_type": response.get("ContentType", "image/png"),
        "size_bytes": response["ContentLength"],
        "data_base64": b64_data,
        "latency_ms": latency_ms,
    }


@mcp.custom_route("/health", methods=["GET"])
async def health_check(request: Request) -> JSONResponse:
    """Simple liveness check -- S3 server is healthy if it can respond (D-09, OPS-01)."""
    return JSONResponse({"status": "healthy"})


if __name__ == "__main__":
    mcp.run(transport="streamable-http")
