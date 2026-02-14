#!/usr/bin/env python3
"""
Pilot importer for ChatGPT GDPR conversations into Open WebUI.

Purpose:
- Select N random conversations from a GDPR `conversations.json` export
- Convert each conversation to Open WebUI chat format
- Import them through `/api/v1/chats/import`

Default mode is for a safe pilot:
- count: 3 random conversations
- include roles: user + assistant only
- flatten to current branch (current_node ancestry)
"""

from __future__ import annotations

import argparse
import getpass
import json
import os
import random
import sys
import time
from typing import Any
from urllib import error, request


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Import random ChatGPT GDPR conversations into Open WebUI."
    )
    parser.add_argument(
        "--source",
        required=True,
        help="Path to GDPR conversations.json",
    )
    parser.add_argument(
        "--count",
        type=int,
        default=3,
        help="Number of random conversations to import (default: 3)",
    )
    parser.add_argument(
        "--seed",
        type=int,
        default=None,
        help="Random seed for reproducibility",
    )
    parser.add_argument(
        "--base-url",
        default=os.environ.get("OPENWEBUI_BASE_URL", "http://127.0.0.1:8080/api/v1"),
        help="Open WebUI API base URL (default: %(default)s)",
    )
    parser.add_argument(
        "--token",
        default=os.environ.get("OPENWEBUI_TOKEN"),
        help="Bearer token. Can also be set via OPENWEBUI_TOKEN env var.",
    )
    parser.add_argument(
        "--email",
        default=os.environ.get("OPENWEBUI_EMAIL"),
        help="Open WebUI account email. Used to fetch a bearer token via /auths/signin.",
    )
    parser.add_argument(
        "--password",
        default=os.environ.get("OPENWEBUI_PASSWORD"),
        help="Open WebUI account password. If omitted with --email, prompted securely.",
    )
    parser.add_argument(
        "--dry-run",
        action="store_true",
        help="Convert and select random chats, but do not upload.",
    )
    parser.add_argument(
        "--output",
        default=None,
        help="Optional path to write the generated import payload JSON.",
    )
    parser.add_argument(
        "--include-system",
        action="store_true",
        help="Include system messages in conversion.",
    )
    parser.add_argument(
        "--include-tool",
        action="store_true",
        help="Include tool messages in conversion.",
    )
    parser.add_argument(
        "--keep-empty",
        action="store_true",
        help="Keep messages even when extracted content is empty.",
    )
    return parser.parse_args()


def as_int_timestamp(value: Any, fallback: int | None = None) -> int:
    if fallback is None:
        fallback = int(time.time())
    try:
        if value is None:
            return fallback
        return int(float(value))
    except Exception:
        return fallback


def best_effort_text(obj: Any) -> str:
    if isinstance(obj, str):
        return obj
    if not isinstance(obj, dict):
        return ""

    preferred_keys = [
        "text",
        "content",
        "summary",
        "title",
        "name",
        "user_instructions",
        "user_profile",
    ]

    pieces: list[str] = []
    for key in preferred_keys:
        value = obj.get(key)
        if isinstance(value, str) and value.strip():
            pieces.append(value.strip())
        elif isinstance(value, list):
            strings = [item.strip() for item in value if isinstance(item, str) and item.strip()]
            if strings:
                pieces.append("\n".join(strings))
        elif isinstance(value, dict):
            nested = best_effort_text(value)
            if nested:
                pieces.append(nested)

    if pieces:
        return "\n".join(pieces)
    return ""


def multimodal_parts_to_text(parts: Any) -> str:
    if not isinstance(parts, list):
        return "[multimodal_text]"

    out: list[str] = []
    for part in parts:
        if isinstance(part, str):
            text = part.strip()
            if text:
                out.append(text)
            continue

        if not isinstance(part, dict):
            continue

        content_type = part.get("content_type", "unknown")

        if content_type == "audio_transcription":
            text = part.get("text") or part.get("transcript")
            if isinstance(text, str) and text.strip():
                out.append(text.strip())
            continue

        if content_type in {
            "image_asset_pointer",
            "audio_asset_pointer",
            "real_time_user_audio_video_asset_pointer",
            "video_container_asset_pointer",
        }:
            pointer = part.get("asset_pointer")
            if isinstance(pointer, str) and pointer.strip():
                out.append(f"[{content_type}: {pointer.strip()}]")
            else:
                out.append(f"[{content_type}]")
            continue

        text = best_effort_text(part)
        if text:
            out.append(text)
        else:
            out.append(f"[{content_type}]")

    return "\n".join(out).strip() or "[multimodal_text]"


def extract_text(content: Any) -> str:
    if not isinstance(content, dict):
        return ""

    content_type = content.get("content_type", "unknown")

    if content_type == "text":
        parts = content.get("parts")
        if isinstance(parts, list):
            strings = [item for item in parts if isinstance(item, str) and item.strip()]
            if strings:
                return "\n".join(strings).strip()
        text = content.get("text")
        if isinstance(text, str):
            return text.strip()
        return ""

    if content_type == "code":
        text = content.get("text")
        language = content.get("language")
        if isinstance(text, str) and text.strip():
            if isinstance(language, str) and language.strip():
                return f"```{language.strip()}\n{text.strip()}\n```"
            return text.strip()
        return "[code]"

    if content_type == "multimodal_text":
        return multimodal_parts_to_text(content.get("parts"))

    if content_type == "reasoning_recap":
        text = best_effort_text(content)
        return text if text else "[reasoning_recap]"

    if content_type in {
        "execution_output",
        "system_error",
        "tether_quote",
        "tether_browsing_display",
        "thoughts",
        "app_pairing_content",
        "user_editable_context",
    }:
        text = best_effort_text(content)
        return text if text else f"[{content_type}]"

    text = best_effort_text(content)
    return text if text else f"[{content_type}]"


def extract_model_slug(message: dict[str, Any]) -> str:
    metadata = message.get("metadata")
    if not isinstance(metadata, dict):
        return "chatgpt-import"

    for key in ("model_slug", "default_model_slug", "resolved_model_slug"):
        value = metadata.get(key)
        if isinstance(value, str) and value.strip():
            return value.strip()
    return "chatgpt-import"


def allowed_role(role: str, include_system: bool, include_tool: bool) -> bool:
    if role in {"user", "assistant"}:
        return True
    if role == "system":
        return include_system
    if role == "tool":
        return include_tool
    return False


def build_chat_payload(
    convo: dict[str, Any],
    include_system: bool,
    include_tool: bool,
    keep_empty: bool,
) -> tuple[dict[str, Any] | None, dict[str, Any]]:
    mapping = convo.get("mapping")
    current_node = convo.get("current_node")

    stats = {
        "source_id": convo.get("id"),
        "source_title": convo.get("title"),
        "source_nodes": len(mapping) if isinstance(mapping, dict) else 0,
        "converted_messages": 0,
    }

    if not isinstance(mapping, dict) or not mapping:
        return None, stats

    # Follow the active branch only (current_node -> root).
    node_chain: list[dict[str, Any]] = []
    visited: set[str] = set()
    node_id = current_node

    if not isinstance(node_id, str) or node_id not in mapping:
        # Fallback: choose any node with no children as current.
        for candidate_id, candidate in mapping.items():
            children = candidate.get("children")
            if isinstance(children, list) and len(children) == 0:
                node_id = candidate_id
                break
        if not isinstance(node_id, str) or node_id not in mapping:
            return None, stats

    while isinstance(node_id, str) and node_id in mapping and node_id not in visited:
        visited.add(node_id)
        node = mapping[node_id]
        node_chain.append(node)
        parent_id = node.get("parent")
        if not isinstance(parent_id, str):
            break
        node_id = parent_id

    node_chain.reverse()

    messages_map: dict[str, dict[str, Any]] = {}
    ordered_ids: list[str] = []
    assistant_models: set[str] = set()
    last_id: str | None = None

    convo_ts = as_int_timestamp(convo.get("create_time"), as_int_timestamp(convo.get("update_time")))

    for node in node_chain:
        message = node.get("message")
        if not isinstance(message, dict):
            continue

        author = message.get("author")
        role = ""
        if isinstance(author, dict):
            role = str(author.get("role", "")).strip()
        if not allowed_role(role, include_system, include_tool):
            continue

        content = extract_text(message.get("content"))
        if not content and not keep_empty:
            continue

        model_slug = extract_model_slug(message)
        if role == "assistant":
            assistant_models.add(model_slug)

        message_id = message.get("id") or node.get("id") or f"msg-{len(ordered_ids) + 1}"
        message_id = str(message_id)
        if message_id in messages_map:
            message_id = f"{message_id}-{len(ordered_ids) + 1}"

        timestamp = as_int_timestamp(message.get("create_time"), convo_ts)

        converted = {
            "id": message_id,
            "parentId": last_id,
            "childrenIds": [],
            "role": role,
            "content": content,
            "model": model_slug,
            "timestamp": timestamp,
            "done": True,
            "context": None,
        }

        if last_id is not None and last_id in messages_map:
            messages_map[last_id]["childrenIds"].append(message_id)

        messages_map[message_id] = converted
        ordered_ids.append(message_id)
        last_id = message_id

    if not ordered_ids:
        return None, stats

    stats["converted_messages"] = len(ordered_ids)

    chat_obj = {
        "title": convo.get("title") or "ChatGPT import",
        "history": {
            "currentId": ordered_ids[-1],
            "messages": messages_map,
        },
        "models": sorted(assistant_models) if assistant_models else ["chatgpt-import"],
        "messages": [messages_map[msg_id] for msg_id in ordered_ids],
        "options": {},
        "timestamp": convo_ts,
    }

    return chat_obj, stats


def post_import(
    base_url: str, token: str | None, payload: dict[str, Any]
) -> list[dict[str, Any]]:
    endpoint = f"{base_url.rstrip('/')}/chats/import"
    body = json.dumps(payload).encode("utf-8")

    headers = {
        "Accept": "application/json",
        "Content-Type": "application/json",
    }
    if token and token.strip():
        headers["Authorization"] = f"Bearer {token.strip()}"

    req = request.Request(
        endpoint,
        data=body,
        method="POST",
        headers=headers,
    )

    with request.urlopen(req, timeout=120) as resp:
        data = resp.read().decode("utf-8")
        parsed = json.loads(data)
        if not isinstance(parsed, list):
            raise RuntimeError("Unexpected response shape from /chats/import")
        return parsed


def signin(base_url: str, email: str, password: str) -> str:
    endpoint = f"{base_url.rstrip('/')}/auths/signin"
    body = json.dumps({"email": email, "password": password}).encode("utf-8")

    req = request.Request(
        endpoint,
        data=body,
        method="POST",
        headers={
            "Accept": "application/json",
            "Content-Type": "application/json",
        },
    )

    with request.urlopen(req, timeout=60) as resp:
        data = resp.read().decode("utf-8")
        parsed = json.loads(data)
        if not isinstance(parsed, dict) or not isinstance(parsed.get("token"), str):
            raise RuntimeError("Unexpected response shape from /auths/signin")
        return parsed["token"].strip()


def resolve_token(args: argparse.Namespace) -> str | None:
    if args.token and args.token.strip():
        return args.token.strip()

    if args.email and args.email.strip():
        password = args.password or getpass.getpass(
            prompt=f"Open WebUI password for {args.email.strip()}: "
        )
        if not password:
            raise RuntimeError("Password is required when using --email.")
        return signin(args.base_url, args.email.strip(), password)

    return None


def main() -> int:
    args = parse_args()

    if args.count <= 0:
        print("ERROR: --count must be > 0", file=sys.stderr)
        return 2

    if not os.path.isfile(args.source):
        print(f"ERROR: source file not found: {args.source}", file=sys.stderr)
        return 2

    with open(args.source, "r", encoding="utf-8") as f:
        conversations = json.load(f)

    if not isinstance(conversations, list):
        print("ERROR: source JSON must be an array of conversations", file=sys.stderr)
        return 2

    rng = random.Random(args.seed)
    candidate_indices = list(range(len(conversations)))
    rng.shuffle(candidate_indices)

    selected_forms: list[dict[str, Any]] = []
    selected_stats: list[dict[str, Any]] = []

    for idx in candidate_indices:
        convo = conversations[idx]
        if not isinstance(convo, dict):
            continue

        chat_obj, stats = build_chat_payload(
            convo,
            include_system=args.include_system,
            include_tool=args.include_tool,
            keep_empty=args.keep_empty,
        )
        if chat_obj is None:
            continue

        created_at = as_int_timestamp(convo.get("create_time"))
        updated_at = as_int_timestamp(convo.get("update_time"), created_at)

        selected_forms.append(
            {
                "chat": chat_obj,
                "meta": {
                    "import_source": "chatgpt-gdpr",
                    "conversation_id": convo.get("id"),
                    "original_title": convo.get("title"),
                },
                "pinned": False,
                "folder_id": None,
                "created_at": created_at,
                "updated_at": updated_at,
            }
        )
        selected_stats.append(stats)

        if len(selected_forms) >= args.count:
            break

    if len(selected_forms) < args.count:
        print(
            f"ERROR: only found {len(selected_forms)} convertible conversations (requested {args.count})",
            file=sys.stderr,
        )
        return 1

    payload = {"chats": selected_forms}

    if args.output:
        with open(args.output, "w", encoding="utf-8") as f:
            json.dump(payload, f, ensure_ascii=False, indent=2)
        print(f"Wrote payload: {args.output}")

    print("Selection summary:")
    for i, stat in enumerate(selected_stats, start=1):
        print(
            f"  {i}. id={stat['source_id']} | title={stat['source_title']!r} | "
            f"nodes={stat['source_nodes']} | converted_messages={stat['converted_messages']}"
        )

    if args.dry_run:
        print("Dry run only. No import API call made.")
        return 0

    try:
        token = resolve_token(args)
    except error.HTTPError as exc:
        body = exc.read().decode("utf-8", errors="replace")
        print(f"HTTP ERROR {exc.code} during signin: {body}", file=sys.stderr)
        return 1
    except Exception as exc:
        print(f"ERROR during signin: {exc}", file=sys.stderr)
        return 1

    if not token:
        print(
            "ERROR: authentication required. Pass --token or --email (and --password or prompt).",
            file=sys.stderr,
        )
        return 2

    try:
        imported = post_import(args.base_url, token, payload)
    except error.HTTPError as exc:
        body = exc.read().decode("utf-8", errors="replace")
        print(f"HTTP ERROR {exc.code} during import: {body}", file=sys.stderr)
        return 1
    except Exception as exc:
        print(f"ERROR during import: {exc}", file=sys.stderr)
        return 1

    print(f"Imported {len(imported)} chats successfully.")
    for i, chat in enumerate(imported, start=1):
        chat_id = chat.get("id")
        title = chat.get("title")
        updated_at = chat.get("updated_at")
        print(f"  {i}. openwebui_id={chat_id} | title={title!r} | updated_at={updated_at}")

    return 0


if __name__ == "__main__":
    sys.exit(main())
