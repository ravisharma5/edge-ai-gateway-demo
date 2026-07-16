#!/usr/bin/env python3
"""CV Inference MCP Server -- exposes analyze_image tool.

Wraps a YOLOv8 chest X-ray classification model behind a single MCP tool.
Fetches images from MinIO (S3-compatible storage), runs inference on CPU,
and returns a NORMAL/PNEUMONIA classification with confidence scores and
synthetic token metering. Serves tool calls over Streamable HTTP on port 3002.
Part of the Healthcare Radiology Edge Demo.

Usage:
    cd servers/cv
    .venv/bin/python server.py
    # Server starts at http://127.0.0.1:3002/mcp
"""

import io
import json
import os
import time

import boto3
import numpy as np
from botocore.client import Config
from botocore.exceptions import ClientError
from dotenv import load_dotenv
from mcp.server.fastmcp import FastMCP
from mcp.server.transport_security import TransportSecuritySettings
from PIL import Image
from starlette.requests import Request
from starlette.responses import JSONResponse
import torch
from ultralytics import YOLO

# The HuggingFace chest-xray model was saved with an older PyTorch version.
# PyTorch 2.13+ defaults to weights_only=True which rejects it.
_torch_load = torch.load
torch.load = lambda *a, **kw: _torch_load(*a, **{**kw, "weights_only": False})

_script_dir = os.path.dirname(os.path.abspath(__file__))
_env_path = os.path.join(_script_dir, "..", "..", ".env")
load_dotenv(_env_path)

mcp = FastMCP(
    "CV Inference Server",
    host="127.0.0.1",
    port=3002,
    json_response=True,
    transport_security=TransportSecuritySettings(
        enable_dns_rebinding_protection=True,
        allowed_hosts=["127.0.0.1:*", "localhost:*", "[::1]:*", "cv.local", "cv.local:*"],
    ),
)

s3 = boto3.client(
    "s3",
    endpoint_url=os.getenv("MINIO_ENDPOINT", "http://localhost:9000"),
    aws_access_key_id=os.getenv("MINIO_ACCESS_KEY", "minioadmin"),
    aws_secret_access_key=os.getenv("MINIO_SECRET_KEY", "minioadmin"),
    config=Config(signature_version="s3v4"),
    region_name="us-east-1",
)

_model_path = os.path.join(_script_dir, "chest-xray-cls.pt")
model = YOLO(_model_path)

_warmup = np.zeros((224, 224, 3), dtype=np.uint8)
model.predict(source=_warmup, device="cpu", verbose=False)

inference_count = 0


@mcp.tool()
def analyze_image(key: str, bucket_name: str = "radiology-images") -> dict:
    """Classify a chest X-ray image as NORMAL or PNEUMONIA using a fine-tuned YOLOv8 model."""
    global inference_count
    start = time.time()

    try:
        response = s3.get_object(Bucket=bucket_name, Key=key)
    except ClientError as e:
        error_code = e.response.get("Error", {}).get("Code", "Unknown")
        if error_code == "NoSuchKey":
            raise ValueError(f"Image not found: {key} in bucket {bucket_name}")
        elif error_code == "NoSuchBucket":
            raise ValueError(f"Bucket not found: {bucket_name}")
        raise RuntimeError(f"MinIO error ({error_code}): {e}")

    try:
        image_bytes = response["Body"].read()
        image = Image.open(io.BytesIO(image_bytes))
    except Exception as e:
        raise ValueError(f"Failed to decode image {key}: {e}")

    try:
        results = model.predict(source=image, device="cpu", save=False, verbose=False)
    except Exception as e:
        raise RuntimeError(f"Inference failed: {e}")

    all_classes = []
    classification = "UNKNOWN"
    confidence = 0.0

    if results and len(results) > 0:
        result = results[0]
        if result.probs is not None:
            top1_idx = int(result.probs.top1)
            top1_conf = float(result.probs.top1conf)
            classification = model.names.get(top1_idx, f"class_{top1_idx}")
            confidence = round(top1_conf, 4)

            probs_data = result.probs.data.cpu().numpy()
            for idx, prob in enumerate(probs_data):
                all_classes.append({
                    "class_name": model.names.get(idx, f"class_{idx}"),
                    "confidence": round(float(prob), 4),
                })
            all_classes.sort(key=lambda x: x["confidence"], reverse=True)

    inference_count += 1
    latency_ms = round((time.time() - start) * 1000, 2)

    if classification == "PNEUMONIA":
        finding = (
            f"Chest X-ray analysis indicates findings consistent with pneumonia "
            f"(confidence: {confidence:.1%}). Patchy opacities observed. "
            f"Clinical correlation recommended."
        )
    elif classification == "NORMAL":
        finding = (
            f"Chest X-ray analysis within normal limits "
            f"(confidence: {confidence:.1%}). No acute cardiopulmonary abnormality detected."
        )
    else:
        finding = f"Classification inconclusive: {classification} ({confidence:.1%})."

    response = {
        "classification": classification,
        "confidence": confidence,
        "finding": finding,
        "all_classes": all_classes,
        "inference_count": inference_count,
        "latency_ms": latency_ms,
    }
    token_count = len(json.dumps(response)) // 4
    response["token_count"] = token_count

    return response


@mcp.custom_route("/health", methods=["GET"])
async def health_check(request: Request) -> JSONResponse:
    if model is None:
        return JSONResponse(
            {"status": "unhealthy", "reason": "model not loaded"}, status_code=503
        )
    return JSONResponse({"status": "healthy"})


if __name__ == "__main__":
    mcp.run(transport="streamable-http")
