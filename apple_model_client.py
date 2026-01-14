#!/usr/bin/env python3
from __future__ import annotations

import json
import os
import subprocess
from typing import Optional, Tuple


DEFAULT_BRIDGE_PATH = os.getenv("APPLE_FM_BRIDGE_PATH", "bin/apple_foundation_bridge")
DEFAULT_TIMEOUT = float(os.getenv("APPLE_FM_TIMEOUT", "30"))


class AppleFoundationClient:
    def __init__(self, bridge_path: Optional[str] = None):
        self.bridge_path = bridge_path or DEFAULT_BRIDGE_PATH

    def is_available(self) -> bool:
        status = self._status()
        return bool(status and status.get("success"))

    def get_availability(self) -> Optional[str]:
        status = self._status()
        if not status:
            return None
        return status.get("availability")

    def generate(
        self,
        system_prompt: str,
        user_prompt: str,
        max_tokens: Optional[int] = None,
        temperature: Optional[float] = None,
        top_p: Optional[float] = None,
        top_k: Optional[int] = None,
    ) -> Tuple[Optional[str], str]:
        if not user_prompt:
            return None, "No content to summarize"
        payload = {
            "system": system_prompt,
            "prompt": user_prompt,
            "maxTokens": max_tokens,
            "temperature": temperature,
            "topP": top_p,
            "topK": top_k,
        }
        response = self._call_bridge(payload)
        if not response:
            return None, "Bridge not available"
        if not response.get("success"):
            return None, response.get("error") or "Bridge error"
        return response.get("text"), "apple:foundation"

    def _status(self) -> Optional[dict]:
        if not os.path.exists(self.bridge_path):
            return None
        try:
            result = subprocess.run(
                [self.bridge_path, "--status"],
                capture_output=True,
                text=True,
                timeout=DEFAULT_TIMEOUT,
            )
        except Exception:
            return None
        if not result.stdout:
            return None
        try:
            return json.loads(result.stdout)
        except json.JSONDecodeError:
            return None

    def _call_bridge(self, payload: dict) -> Optional[dict]:
        if not os.path.exists(self.bridge_path):
            return None
        try:
            result = subprocess.run(
                [self.bridge_path],
                input=json.dumps(payload),
                capture_output=True,
                text=True,
                timeout=DEFAULT_TIMEOUT,
            )
        except Exception:
            return None
        if not result.stdout:
            return None
        try:
            return json.loads(result.stdout)
        except json.JSONDecodeError:
            return None
