#!/usr/bin/env python3
"""MinIO bootstrap script: create bucket and upload sample radiology images.

Run once before the first demo to populate MinIO with sample data.
Requires MinIO server running on localhost:9000.

Usage:
    cd servers/s3
    .venv/bin/python setup_minio.py
"""

import glob
import os

import boto3
from botocore.client import Config
from botocore.exceptions import ClientError
from dotenv import load_dotenv


def setup_minio() -> None:
    """Create radiology-images bucket and upload sample PNGs from data/samples/.

    Loads configuration from .env at repo root. Idempotent: safe to run
    multiple times without errors or duplicate objects.
    """
    # Load .env from repo root (two levels up from servers/s3/)
    script_dir = os.path.dirname(os.path.abspath(__file__))
    env_path = os.path.join(script_dir, "..", "..", ".env")
    load_dotenv(env_path)

    # Configuration with defaults
    endpoint = os.getenv("MINIO_ENDPOINT", "http://localhost:9000")
    access_key = os.getenv("MINIO_ACCESS_KEY", "minioadmin")
    secret_key = os.getenv("MINIO_SECRET_KEY", "minioadmin")
    bucket = os.getenv("MINIO_BUCKET", "radiology-images")

    print(f"Connecting to MinIO at {endpoint}")

    # Create boto3 S3 client (NOT resource -- resource API freezes with MinIO)
    s3 = boto3.client(
        "s3",
        endpoint_url=endpoint,
        aws_access_key_id=access_key,
        aws_secret_access_key=secret_key,
        config=Config(signature_version="s3v4"),
        region_name="us-east-1",
    )

    # Create bucket idempotently
    try:
        s3.head_bucket(Bucket=bucket)
        print(f"Bucket '{bucket}' already exists")
    except ClientError:
        s3.create_bucket(Bucket=bucket)
        print(f"Created bucket '{bucket}'")

    # Upload all PNGs from data/samples/
    samples_dir = os.path.join(script_dir, "..", "..", "data", "samples")
    samples_dir = os.path.abspath(samples_dir)
    png_files = sorted(glob.glob(os.path.join(samples_dir, "*.png")))

    if not png_files:
        print(f"WARNING: No PNG files found in {samples_dir}")
        print("Run 'python data/samples/generate_samples.py' first.")
        return

    uploaded_count = 0
    total_size = 0

    for filepath in png_files:
        key = os.path.basename(filepath)
        file_size = os.path.getsize(filepath)
        s3.upload_file(
            filepath,
            bucket,
            key,
            ExtraArgs={"ContentType": "image/png"},
        )
        uploaded_count += 1
        total_size += file_size
        print(f"  Uploaded: {key} ({file_size:,} bytes)")

    # Print summary
    response = s3.list_objects_v2(Bucket=bucket)
    object_count = response.get("KeyCount", 0)
    bucket_size = sum(obj["Size"] for obj in response.get("Contents", []))

    print(f"\nSummary:")
    print(f"  Bucket:       {bucket}")
    print(f"  Objects:      {object_count}")
    print(f"  Total size:   {bucket_size:,} bytes ({bucket_size / 1024:.1f} KB)")
    print(f"  Uploaded:     {uploaded_count} files in this run")


if __name__ == "__main__":
    print("MinIO Bootstrap Script")
    print("=" * 40)
    print("Make sure MinIO is running:")
    print("  minio server ~/minio-data --console-address :9001")
    print()
    setup_minio()
