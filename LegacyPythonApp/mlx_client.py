#!/usr/bin/env python3
"""
MLX local model client for email summarization and chat.
Uses mlx-lm for local inference (no HTTP server required).
Supports both HuggingFace model IDs and local model directories.
"""
from __future__ import annotations

import inspect
import json
import os
import re
import threading
import time
from functools import lru_cache
from pathlib import Path
from typing import Any, Dict, Generator, List, Optional, Tuple

try:
    from mlx_lm import load, generate
    from mlx_lm.sample_utils import make_logits_processors, make_sampler
except Exception as exc:  # pragma: no cover - optional dependency
    load = None
    generate = None
    make_logits_processors = None
    make_sampler = None
    _MLX_IMPORT_ERROR = exc
else:
    _MLX_IMPORT_ERROR = None


DEFAULT_MLX_MODELS = [
    "mlx-community/gemma-3-1b-it-qat-4bit",
    "mlx-community/Meta-Llama-3.1-8B-Instruct-4bit",
]

# Files that indicate a valid MLX model directory
MLX_MODEL_INDICATORS = ["config.json", "weights.npz", "model.safetensors"]


class MLXClient:
    def __init__(self, model: Optional[str] = None):
        self.model = model or os.getenv("MLX_MODEL") or DEFAULT_MLX_MODELS[0]
        self.temperature = self._env_float("MLX_TEMPERATURE", 0.5)
        self.top_p = self._env_float("MLX_TOP_P", 0.9)
        self.top_k = self._env_int("MLX_TOP_K", 0)
        self.repetition_penalty = self._env_float("MLX_REPETITION_PENALTY", 1.2)
        self.repetition_context = self._env_int("MLX_REPETITION_CONTEXT", 64)
        self.max_tokens = self._env_int("MLX_MAX_TOKENS", 2048)
        self.chat_max_tokens = self._env_int("MLX_CHAT_MAX_TOKENS", 160)
        self._model_warmed_up = set()
        self._last_keepalive = None
        self._generate_lock = threading.Lock()
        self._models_file = os.getenv("MLX_MODELS_FILE", "mlx_models.json")
        self._local_models_dir = os.getenv("MLX_LOCAL_MODELS_DIR", "")

    def is_available(self) -> bool:
        """Check if mlx-lm is importable and a model is configured."""
        if _MLX_IMPORT_ERROR:
            return False
        return bool(self.model)

    def list_models(self, force_refresh: bool = False) -> List[str]:
        """Return configured MLX models (env + file + defaults)."""
        models: List[str] = []

        # Always include defaults first
        models.extend(DEFAULT_MLX_MODELS)

        # Add from environment
        env_list = os.getenv("MLX_MODEL_LIST")
        if env_list:
            models.extend([item.strip() for item in env_list.split(",") if item.strip()])

        env_model = os.getenv("MLX_MODEL")
        if env_model:
            models.append(env_model)

        # Add user-saved models from file
        file_models = self._load_models_file()
        models.extend(file_models)

        # Ensure current model is in list
        if self.model and self.model not in models:
            models.insert(0, self.model)

        return self._dedupe(models)

    def list_models_with_info(self) -> List[Dict[str, Any]]:
        """Return configured MLX models with type information."""
        models = self.list_models()
        return [self.get_model_info(m) for m in models]

    def add_model(self, model_id: str, make_default: bool = False) -> List[str]:
        model_id = (model_id or "").strip()
        if not model_id:
            raise ValueError("Model ID is required.")

        file_models = self._load_models_file()
        if model_id not in file_models:
            file_models.append(model_id)
            self._save_models_file(file_models)

        if make_default or not self.model:
            self.model = model_id

        return self.list_models(force_refresh=True)

    @staticmethod
    def is_local_path(model_id: str) -> bool:
        """Check if a model ID is a local filesystem path."""
        if not model_id:
            return False
        return model_id.startswith("/") or model_id.startswith("~") or model_id.startswith(".")

    @staticmethod
    def is_valid_mlx_model(path: str) -> bool:
        """Check if a directory contains a valid MLX model."""
        model_path = Path(path).expanduser()
        if not model_path.is_dir():
            return False
        for indicator in MLX_MODEL_INDICATORS:
            if (model_path / indicator).exists():
                return True
        return False

    def get_local_models_dir(self) -> str:
        """Get the current local models directory."""
        return self._local_models_dir

    def set_local_models_dir(self, directory: str) -> bool:
        """Set the local models directory."""
        expanded = Path(directory).expanduser()
        if directory and not expanded.is_dir():
            return False
        self._local_models_dir = str(expanded) if directory else ""
        return True

    def scan_local_models(self, directory: Optional[str] = None) -> List[Dict[str, Any]]:
        """Scan a directory for valid MLX models."""
        scan_dir = directory or self._local_models_dir
        if not scan_dir:
            return []

        base_path = Path(scan_dir).expanduser()
        if not base_path.is_dir():
            return []

        models = []

        # Check if the directory itself is a model
        if self.is_valid_mlx_model(str(base_path)):
            models.append({
                "path": str(base_path),
                "name": base_path.name,
                "type": "local"
            })
            return models

        # Scan subdirectories
        for entry in base_path.iterdir():
            if entry.is_dir() and self.is_valid_mlx_model(str(entry)):
                models.append({
                    "path": str(entry),
                    "name": entry.name,
                    "type": "local"
                })

        # Sort by name
        models.sort(key=lambda m: m["name"].lower())
        return models

    def add_local_model(self, path: str, make_default: bool = False) -> List[str]:
        """Add a local model path to the models list."""
        expanded = str(Path(path).expanduser())
        if not self.is_valid_mlx_model(expanded):
            raise ValueError(f"Not a valid MLX model directory: {path}")

        file_models = self._load_models_file()
        if expanded not in file_models:
            file_models.append(expanded)
            self._save_models_file(file_models)

        if make_default or not self.model:
            self.model = expanded

        return self.list_models(force_refresh=True)

    def get_model_info(self, model_id: str) -> Dict[str, Any]:
        """Get information about a model."""
        is_local = self.is_local_path(model_id)
        if is_local:
            path = Path(model_id).expanduser()
            return {
                "id": model_id,
                "name": path.name,
                "type": "local",
                "valid": self.is_valid_mlx_model(str(path)),
                "path": str(path)
            }
        else:
            return {
                "id": model_id,
                "name": model_id.split("/")[-1] if "/" in model_id else model_id,
                "type": "huggingface",
                "valid": True,  # Assume HF models are valid until load fails
                "path": None
            }

    def _calculate_max_tokens(self, content_length: int) -> int:
        """Calculate max tokens based on content length with a floor."""
        estimated_tokens = max(1, content_length // 4)
        response_tokens = max(128, estimated_tokens // 2)
        return min(self.max_tokens, response_tokens)

    async def warm_up_model(self, model: Optional[str] = None) -> bool:
        """Warm up the model with a tiny prompt to load weights."""
        model_id = model or self.model
        if not model_id:
            return False
        if model_id in self._model_warmed_up:
            return True
        try:
            self._generate(
                system_prompt="You are a helpful assistant.",
                user_prompt="Hi",
                model=model_id,
                max_tokens=8,
            )
            self._model_warmed_up.add(model_id)
            return True
        except Exception:
            return False

    def summarize_email(self, email_content: str, model: Optional[str] = None) -> Tuple[Optional[str], str]:
        """Summarize email content."""
        if not email_content:
            return None, "No content to summarize"

        model_id = model or self.model

        system_prompt = "You are a helpful assistant that summarizes emails concisely."
        user_prompt = (
            "Summarize this email concisely. Include key points, actions needed, and important details.\n\n"
            f"Email:\n{email_content}\n\nSummary:"
        )

        summary = self._generate(system_prompt, user_prompt, model_id)
        if summary:
            return summary, model_id

        for fallback_model in self._fallback_models(model_id):
            summary = self._generate(system_prompt, user_prompt, fallback_model)
            if summary:
                return summary, fallback_model

        return None, "All models failed"

    def summarize_text(
        self,
        system_prompt: str,
        user_prompt: str,
        model: Optional[str] = None,
    ) -> Tuple[Optional[str], str]:
        """Summarize generic text with custom prompts."""
        if not user_prompt:
            return None, "No content to summarize"

        model_id = model or self.model

        summary = self._generate(system_prompt, user_prompt, model_id)
        if summary:
            return summary, model_id

        for fallback_model in self._fallback_models(model_id):
            summary = self._generate(system_prompt, user_prompt, fallback_model)
            if summary:
                return summary, fallback_model

        return None, "All models failed"

    def summarize_text_stream(
        self,
        system_prompt: str,
        user_prompt: str,
        model: Optional[str] = None,
    ) -> Generator[Tuple[str, str], None, None]:
        """Summarize generic text with streaming chunks."""
        if not user_prompt:
            yield "error", "No content to summarize"
            return

        model_id = model or self.model

        for chunk in self._generate_stream(system_prompt, user_prompt, model_id):
            if chunk:
                yield "chunk", chunk
            else:
                for fallback_model in self._fallback_models(model_id):
                    success = False
                    for chunk in self._generate_stream(system_prompt, user_prompt, fallback_model):
                        if chunk:
                            yield "chunk", chunk
                            success = True
                    if success:
                        yield "model", fallback_model
                        return
                yield "error", "All models failed"
                return

        yield "model", model_id

    def summarize_email_stream(
        self,
        email_content: str,
        model: Optional[str] = None,
    ) -> Generator[Tuple[str, str], None, None]:
        """Summarize email content with streaming chunks."""
        if not email_content:
            yield "error", "No content to summarize"
            return

        model_id = model or self.model

        system_prompt = "You are a helpful assistant that summarizes emails concisely."
        user_prompt = (
            "Summarize this email concisely. Include key points, actions needed, and important details.\n\n"
            f"Email:\n{email_content}\n\nSummary:"
        )

        for chunk in self._generate_stream(system_prompt, user_prompt, model_id):
            if chunk:
                yield "chunk", chunk
            else:
                for fallback_model in self._fallback_models(model_id):
                    success = False
                    for chunk in self._generate_stream(system_prompt, user_prompt, fallback_model):
                        if chunk:
                            yield "chunk", chunk
                            success = True
                    if success:
                        yield "model", fallback_model
                        return
                yield "error", "All models failed"
                return

        yield "model", model_id

    def chat_about_email(self, context: str, question: str, model: Optional[str] = None) -> Optional[str]:
        """Chat about email with context."""
        model_id = model or self.model

        system_prompt = (
            "You are a helpful assistant answering questions about an email. "
            "Use the provided email content and summary to answer questions accurately and concisely. "
            "Do not repeat the question or include labels."
        )
        user_prompt = (
            f"Context:\n{context}\n\n"
            f"Question: {question}\n\n"
            "Respond with a concise answer."
        )

        response = self._generate(
            system_prompt,
            user_prompt,
            model_id,
            max_tokens=self.chat_max_tokens,
        )
        return self._clean_chat_response(response)

    def chat_about_context(self, context: str, question: str, model: Optional[str] = None) -> Optional[str]:
        """Chat about a generic context with a user question."""
        model_id = model or self.model

        system_prompt = (
            "You are a helpful assistant answering questions based on the provided context. "
            "Use the context accurately and respond concisely. "
            "Do not repeat the question or include labels."
        )
        user_prompt = (
            f"Context:\n{context}\n\n"
            f"Question: {question}\n\n"
            "Respond with a concise answer."
        )

        response = self._generate(
            system_prompt,
            user_prompt,
            model_id,
            max_tokens=self.chat_max_tokens,
        )
        return self._clean_chat_response(response)

    def chat_about_email_stream(
        self,
        context: str,
        question: str,
        model: Optional[str] = None,
    ) -> Generator[Optional[str], None, None]:
        """Chat about email with streaming response."""
        model_id = model or self.model

        system_prompt = (
            "You are a helpful assistant answering questions about an email. "
            "Use the provided email content and summary to answer questions accurately and concisely. "
            "Do not repeat the question or include labels."
        )
        user_prompt = (
            f"Context:\n{context}\n\n"
            f"Question: {question}\n\n"
            "Respond with a concise answer."
        )

        response = self._generate(
            system_prompt,
            user_prompt,
            model_id,
            max_tokens=self.chat_max_tokens,
        )
        response = self._clean_chat_response(response)
        if not response:
            yield None
            return
        for chunk in self._chunk_text(response, chunk_size=120):
            yield chunk

    def chat_about_context_stream(
        self,
        context: str,
        question: str,
        model: Optional[str] = None,
    ) -> Generator[Optional[str], None, None]:
        """Chat about a generic context with streaming response."""
        model_id = model or self.model

        system_prompt = (
            "You are a helpful assistant answering questions based on the provided context. "
            "Use the context accurately and respond concisely. "
            "Do not repeat the question or include labels."
        )
        user_prompt = (
            f"Context:\n{context}\n\n"
            f"Question: {question}\n\n"
            "Respond with a concise answer."
        )

        response = self._generate(
            system_prompt,
            user_prompt,
            model_id,
            max_tokens=self.chat_max_tokens,
        )
        response = self._clean_chat_response(response)
        if not response:
            yield None
            return
        for chunk in self._chunk_text(response, chunk_size=120):
            yield chunk

    def _fallback_models(self, primary_model: str) -> List[str]:
        return [model for model in self.list_models() if model != primary_model]

    def _load_models_file(self) -> List[str]:
        if not self._models_file:
            return []
        try:
            with open(self._models_file, "r", encoding="utf-8") as handle:
                data = json.load(handle)
            if isinstance(data, list):
                return [str(item).strip() for item in data if str(item).strip()]
        except FileNotFoundError:
            return []
        except Exception:
            return []
        return []

    def _save_models_file(self, models: List[str]) -> None:
        if not self._models_file:
            return
        try:
            with open(self._models_file, "w", encoding="utf-8") as handle:
                json.dump(self._dedupe(models), handle, indent=2)
        except Exception:
            return

    @staticmethod
    def _dedupe(models: List[str]) -> List[str]:
        seen = set()
        ordered = []
        for model in models:
            if model not in seen:
                ordered.append(model)
                seen.add(model)
        return ordered

    def _generate(
        self,
        system_prompt: str,
        user_prompt: str,
        model: str,
        max_tokens: Optional[int] = None,
    ) -> Optional[str]:
        """Generate response using mlx-lm."""
        if _MLX_IMPORT_ERROR:
            print("mlx-lm is not available. Install with: pip install mlx mlx-lm")
            return None

        prompt = self._format_prompt(system_prompt, user_prompt)
        self._last_keepalive = time.time()

        try:
            model_obj, tokenizer = self._load_model(model)
        except Exception as exc:
            print(f"Failed to load MLX model {model}: {exc}")
            return None

        token_budget = max_tokens or self._calculate_max_tokens(len(prompt))
        kwargs = self._build_generate_kwargs(token_budget)

        try:
            with self._generate_lock:
                output = generate(model_obj, tokenizer, prompt, **kwargs)
            return self._normalize_output(output)
        except Exception as exc:
            print(f"Error generating with {model}: {exc}")
            return None

    def _generate_stream(
        self,
        system_prompt: str,
        user_prompt: str,
        model: str,
    ) -> Generator[Optional[str], None, None]:
        """Generate response and yield text chunks (pseudo-streaming)."""
        text = self._generate(system_prompt, user_prompt, model)
        if not text:
            yield None
            return

        for chunk in self._chunk_text(text, chunk_size=120):
            yield chunk

    @staticmethod
    @lru_cache(maxsize=2)
    def _load_model(model_id: str):
        if load is None:
            raise RuntimeError("mlx-lm is not available.")
        return load(model_id)

    @staticmethod
    def _normalize_output(output) -> str:
        if isinstance(output, str):
            return MLXClient._clean_response(output)
        if isinstance(output, dict):
            return MLXClient._clean_response(output.get("text") or output.get("output") or "")
        if isinstance(output, (list, tuple)) and output:
            return MLXClient._clean_response(str(output[0]))
        return MLXClient._clean_response(str(output))

    @staticmethod
    def _format_prompt(system_prompt: str, user_prompt: str) -> str:
        return f"{system_prompt}\n\n{user_prompt}\n"

    @staticmethod
    def _clean_response(text: str) -> str:
        cleaned = text.strip()
        if not cleaned:
            return ""
        lines = cleaned.splitlines()
        while lines and MLXClient._is_trailing_fence(lines[-1]):
            lines.pop()
        return "\n".join(lines).strip()

    @staticmethod
    def _clean_chat_response(text: Optional[str]) -> Optional[str]:
        if not text:
            return text
        cleaned = MLXClient._clean_response(text)
        if not cleaned:
            return cleaned
        cleaned = cleaned.replace("```", " ").replace("`", "")
        cleaned = re.sub(
            r"(?i)\b(assistant|final answer|your response|response|answer)\s*:\s*",
            "",
            cleaned,
        )
        cleaned = re.sub(r"\s+", " ", cleaned).strip()
        if "User Question:" in cleaned:
            return cleaned.split("User Question:", 1)[0].rstrip()
        if "Question:" in cleaned and "Answer:" in cleaned:
            return cleaned.split("Question:", 1)[0].rstrip()
        sentences = [s.strip() for s in re.split(r"(?<=[.!?])\s+", cleaned) if s.strip()]
        if len(sentences) > 1:
            unique = []
            seen = set()
            for sentence in sentences:
                if sentence in seen:
                    continue
                unique.append(sentence)
                seen.add(sentence)
                if len(unique) >= 4:
                    break
            return " ".join(unique)
        return cleaned

    @staticmethod
    def _is_trailing_fence(line: str) -> bool:
        stripped = line.strip()
        if not stripped:
            return True
        if len(stripped) >= 3 and set(stripped) <= {"`"}:
            return True
        if len(stripped) >= 3 and set(stripped) <= {"-"}:
            return True
        if len(stripped) >= 3 and set(stripped) <= {"_"}:
            return True
        if len(stripped) >= 3 and set(stripped) <= {"~"}:
            return True
        return False

    @staticmethod
    def _chunk_text(text: str, chunk_size: int = 120) -> Generator[str, None, None]:
        for idx in range(0, len(text), chunk_size):
            yield text[idx:idx + chunk_size]

    def _build_generate_kwargs(self, max_tokens: int) -> dict:
        if generate is None:
            return {}
        kwargs = {}
        sig = inspect.signature(generate)
        if "max_tokens" in sig.parameters:
            kwargs["max_tokens"] = max_tokens
        elif "max_new_tokens" in sig.parameters:
            kwargs["max_new_tokens"] = max_tokens
        if make_sampler is not None:
            kwargs["sampler"] = make_sampler(
                temp=self.temperature,
                top_p=self.top_p,
                top_k=self.top_k,
            )
        if make_logits_processors is not None:
            logits_processors = make_logits_processors(
                repetition_penalty=self.repetition_penalty,
                repetition_context_size=self.repetition_context,
            )
            if logits_processors:
                kwargs["logits_processors"] = logits_processors
        if "temperature" in sig.parameters:
            kwargs["temperature"] = self.temperature
        elif "temp" in sig.parameters:
            kwargs["temp"] = self.temperature
        return kwargs

    @staticmethod
    def _env_float(var_name: str, default: float) -> float:
        value = os.getenv(var_name)
        if not value:
            return default
        try:
            return float(value)
        except ValueError:
            return default

    @staticmethod
    def _env_int(var_name: str, default: int) -> int:
        value = os.getenv(var_name)
        if not value:
            return default
        try:
            return max(1, int(value))
        except ValueError:
            return default


if __name__ == "__main__":
    client = MLXClient()
    if client.is_available():
        print("MLX is available!")
        print(f"Available models: {client.list_models()}")
    else:
        print("MLX is not available. Install mlx-lm and configure MLX_MODEL.")
