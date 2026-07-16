#!/usr/bin/env python3
"""Streamlit demo app for the Healthcare Radiology Edge Demo.

Doctor-centric workflow: select a patient X-ray, ask the system to analyze it,
get a readable finding. Under the hood, chains MCP tool calls through the
AI Gateway (Envoy + Broker + Router) to S3 and CV inference backends.

Usage:
    demo/.venv/bin/streamlit run demo/app.py
"""

import asyncio
import base64
import io
import json
import time

import streamlit as st
from mcp.client.streamable_http import streamable_http_client
from mcp.client.session import ClientSession
from PIL import Image

GATEWAY_URL = "http://localhost:8888/mcp"


async def mcp_call(tool_name: str, arguments: dict | None = None) -> tuple[dict, float]:
    """Call an MCP tool through the gateway. Returns (parsed_result, elapsed_ms)."""
    t0 = time.time()
    async with streamable_http_client(GATEWAY_URL) as (read, write, _):
        async with ClientSession(read, write) as session:
            await session.initialize()
            result = await session.call_tool(tool_name, arguments or {})
            elapsed = round((time.time() - t0) * 1000)
            if result.content and len(result.content) > 0:
                text = result.content[0].text
                try:
                    return json.loads(text), elapsed
                except json.JSONDecodeError:
                    return {"raw": text, "isError": result.isError}, elapsed
            return {"isError": result.isError}, elapsed


def call_tool(tool_name: str, arguments: dict | None = None) -> tuple[dict, float]:
    return asyncio.run(mcp_call(tool_name, arguments))


def check_gateway() -> bool:
    try:
        import httpx
        r = httpx.get("http://localhost:8888/", timeout=2)
        return r.status_code < 500
    except Exception:
        return False


st.set_page_config(
    page_title="RedHat AI Healthcare Radiology",
    page_icon="🏥",
    layout="wide",
)

# -- Header --
st.markdown(
    "<h2 style='margin-bottom:0'>RedHat AI Use Case: Healthcare Radiology</h2>"
    "<p style='color:gray;margin-top:0'>Edge deployment demo — all components running locally</p>",
    unsafe_allow_html=True,
)

if not check_gateway():
    st.error(
        "AI Gateway not reachable on localhost:8888. "
        "Run `bash start-demo.sh` to start all services."
    )
    st.stop()

# -- Sidebar: architecture + gateway info --
st.sidebar.markdown("### AI Gateway")
st.sidebar.success("Connected — localhost:8888")
st.sidebar.markdown(
    """
**Components running:**
- Envoy Proxy `:8888`
- MCP Broker `:8080`
- MCP Router `:50051`
- S3 MCP Server `:3001`
- CV MCP Server `:3002`
- MinIO `:9000`
"""
)
st.sidebar.divider()
st.sidebar.markdown("### Architecture")
st.sidebar.code(
    "Doctor (this app)\n"
    "  ↓\n"
    "AI Gateway (Envoy :8888)\n"
    "  ├→ S3 Server → MinIO\n"
    "  │   (fetch X-ray images)\n"
    "  └→ CV Server → YOLOv8\n"
    "      (classify: Normal/Pneumonia)",
    language=None,
)
st.sidebar.divider()
st.sidebar.markdown(
    "**Goal:** Evaluate RedHat AI Stack @ Edge  \n"
    "Agents · MaaS · MCP Server Tools · Token counting"
)

# ============================================================
# Step 1: List available X-ray images (cached to avoid re-fetching)
# ============================================================
st.markdown("---")
st.subheader("Patient X-Ray Images")

if "image_list" not in st.session_state:
    with st.spinner("Loading images from S3 storage..."):
        try:
            list_result, list_ms = call_tool("s3_list_objects")
            st.session_state.image_list = list_result.get("objects", [])
            st.session_state.list_ms = list_ms
        except Exception as e:
            st.error(f"Failed to connect to S3 storage: {e}")
            st.stop()

objects = st.session_state.image_list
list_ms = st.session_state.list_ms
image_keys = [obj["key"] for obj in objects]

col_select, col_preview = st.columns([1, 2])

with col_select:
    st.caption(f"{len(objects)} images in S3 bucket")
    selected = st.radio(
        "Select X-ray to analyze:",
        image_keys,
        format_func=lambda k: k.replace("_", " ").replace(".png", "").title(),
        label_visibility="collapsed",
    )

# ============================================================
# Step 2: Fetch and display the selected image (cached per key)
# ============================================================
with col_preview:
    if selected:
        cache_key = f"img_{selected}"
        if cache_key not in st.session_state:
            with st.spinner("Fetching image..."):
                try:
                    fetch_result, fetch_ms = call_tool("s3_get_object", {"key": selected})
                    st.session_state[cache_key] = (fetch_result, fetch_ms)
                except Exception as e:
                    st.error(f"Failed to fetch image: {e}")
                    st.stop()

        fetch_result, fetch_ms = st.session_state[cache_key]
        b64_data = fetch_result.get("data_base64", "")
        if b64_data:
            img_bytes = base64.b64decode(b64_data)
            img = Image.open(io.BytesIO(img_bytes))
            st.image(img, caption=selected, width="stretch")

# ============================================================
# Step 3: Analyze -- the doctor clicks this
# ============================================================
st.markdown("---")

if selected and st.button(
    "🔍  Analyze this X-ray",
    type="primary",
    use_container_width=True,
):
    with st.spinner("Sending to CV inference through AI Gateway..."):
        try:
            analyze_result, analyze_ms = call_tool("cv_analyze_image", {"key": selected})
        except Exception as e:
            st.error(f"Analysis failed: {e}")
            st.stop()

    classification = analyze_result.get("classification", "UNKNOWN")
    confidence = analyze_result.get("confidence", 0)
    finding = analyze_result.get("finding", "")
    token_count = analyze_result.get("token_count", 0)
    inference_count = analyze_result.get("inference_count", 0)
    latency_ms = analyze_result.get("latency_ms", 0)

    # ==========================================================
    # SECTION 1: Clinical View (what the doctor sees)
    # ==========================================================
    st.subheader("Radiology Finding")
    if classification == "PNEUMONIA":
        st.error(finding)
    else:
        st.success(finding)

    c1, c2 = st.columns(2)
    c1.metric("Classification", classification)
    c2.metric("Confidence", f"{confidence:.1%}")

    # ==========================================================
    # SECTION 2: Platform Metrics (what the demo audience sees)
    # ==========================================================
    st.markdown("---")
    st.subheader("AI Gateway Platform Metrics")
    st.caption("RedHat AI Stack @ Edge — inference metering, routing, and token accounting")

    gateway_overhead = max(0, round(analyze_ms - latency_ms))
    _, fetch_ms_for_trace = st.session_state.get(f"img_{selected}", ({}, 0))
    total_ms = list_ms + fetch_ms_for_trace + analyze_ms

    p1, p2, p3, p4 = st.columns(4)
    p1.metric("Model Latency", f"{latency_ms:.0f}ms")
    p2.metric("Gateway Overhead", f"+{gateway_overhead}ms")
    p3.metric("Tokens Consumed", token_count)
    p4.metric("Inference Volume", inference_count)

    # -- MCP Call Trace --
    st.markdown("#### MCP Gateway Call Trace")
    st.caption("Every call flows through the AI Gateway (Envoy :8888) to the correct backend via MCP routing")

    trace_md = (
        "| Step | MCP Tool | Route | Gateway Round-trip | Tokens |\n"
        "|------|----------|-------|--------------------|--------|\n"
        f"| 1 | `s3_list_objects` | Envoy → S3 Server → MinIO | {list_ms}ms | — |\n"
        f"| 2 | `s3_get_object` | Envoy → S3 Server → MinIO | {fetch_ms_for_trace}ms | — |\n"
        f"| 3 | `cv_analyze_image` | Envoy → CV Server → YOLOv8 | {analyze_ms}ms (model: {latency_ms:.0f}ms + gateway: {gateway_overhead}ms) | {token_count} |\n"
    )
    st.markdown(trace_md)

    st.markdown(
        f"**Total round-trips:** 3 · "
        f"**Total latency:** {total_ms}ms · "
        f"**Total tokens:** {token_count}"
    )

    with st.expander("Raw MCP response from cv_analyze_image"):
        st.json(analyze_result)

# -- Footer --
st.markdown("---")
st.caption(
    "RedHat AI Stack @ Edge — All components local: "
    "MinIO (S3 storage) · MCP Gateway (Envoy + Broker + Router) · "
    "S3 MCP Server · CV MCP Server (YOLOv8 chest X-ray classifier) · "
    "No cloud dependencies"
)
