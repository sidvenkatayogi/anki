# Copyright: Ankitects Pty Ltd and contributors
# License: GNU AGPL, version 3 or later; http://www.gnu.org/licenses/agpl.html
"""OpenAI call + strict JSON validation for passage-quiz generation.

Model choice: `gpt-4o-mini` -- cheap, fast, supports JSON-mode
(`response_format={"type": "json_object"}`), more than sufficient for
generating 3-5 short MCQs from a 300-600 word passage.
"""

from __future__ import annotations

import json
import os
import uuid
from typing import Optional

MODEL = "gpt-4o-mini"

_SYSTEM_PROMPT = (
    "You are an MCAT test-prep question writer. Given a passage, write 3 to 5 "
    "multiple-choice questions (MCQs) that test comprehension/reasoning about "
    "the passage. Respond with STRICT JSON ONLY, no prose, matching exactly "
    "this schema:\n"
    '{"questions": [{"stem": "string", "options": ["a","b","c","d"], '
    '"answer_index": 0, "explanation": "string"}]}\n'
    "Rules: 3-5 questions total. Each question has EXACTLY 4 options. "
    "answer_index is an integer 0-3 indicating the correct option. "
    "explanation is a non-empty string explaining the correct answer."
)


class LlmError(Exception):
    """Raised when the LLM call fails or output cannot be validated after
    one retry."""


class LlmConfigError(LlmError):
    """Raised when required LLM configuration (API key) is missing."""


def _validate_quiz(payload: dict) -> list[dict]:
    """Strictly validate the parsed JSON payload. Raises ValueError on any
    schema violation. Returns a list of question dicts with generated ids."""
    if not isinstance(payload, dict):
        raise ValueError("top-level payload is not an object")

    questions = payload.get("questions")
    if not isinstance(questions, list):
        raise ValueError("'questions' is not a list")
    if not (3 <= len(questions) <= 5):
        raise ValueError(f"expected 3-5 questions, got {len(questions)}")

    validated: list[dict] = []
    for i, q in enumerate(questions):
        if not isinstance(q, dict):
            raise ValueError(f"question {i} is not an object")

        stem = q.get("stem")
        if not isinstance(stem, str) or not stem.strip():
            raise ValueError(f"question {i} missing non-empty 'stem'")

        options = q.get("options")
        if not isinstance(options, list) or len(options) != 4:
            raise ValueError(f"question {i} must have exactly 4 options")
        if not all(isinstance(o, str) and o.strip() for o in options):
            raise ValueError(f"question {i} has an empty/non-string option")

        answer_index = q.get("answer_index")
        if not isinstance(answer_index, int) or isinstance(answer_index, bool):
            raise ValueError(f"question {i} 'answer_index' is not an int")
        if not (0 <= answer_index <= 3):
            raise ValueError(f"question {i} 'answer_index' out of range [0,3]")

        explanation = q.get("explanation")
        if not isinstance(explanation, str) or not explanation.strip():
            raise ValueError(f"question {i} missing non-empty 'explanation'")

        validated.append(
            {
                "id": str(uuid.uuid4()),
                "stem": stem,
                "options": options,
                "answer_index": answer_index,
                "explanation": explanation,
            }
        )

    return validated


def _call_openai_raw(passage_text: str, passage_title: str) -> str:
    """Makes the actual OpenAI chat completion call, returns raw response
    content string. Raises LlmConfigError if no API key, LlmError on
    request failure. Isolated for easy mocking in tests."""
    api_key = os.environ.get("OPENAI_API_KEY")
    if not api_key:
        raise LlmConfigError("OPENAI_API_KEY not configured")

    try:
        from openai import OpenAI
    except ImportError as exc:  # pragma: no cover
        raise LlmError(f"openai package not installed ({exc})") from exc

    client = OpenAI(api_key=api_key)
    try:
        response = client.chat.completions.create(
            model=MODEL,
            response_format={"type": "json_object"},
            messages=[
                {"role": "system", "content": _SYSTEM_PROMPT},
                {
                    "role": "user",
                    "content": f"Passage title: {passage_title}\n\nPassage:\n{passage_text}",
                },
            ],
            temperature=0.4,
        )
    except Exception as exc:  # noqa: BLE001 - surface any SDK error uniformly
        raise LlmError(f"openai request failed: {exc}") from exc

    content = response.choices[0].message.content
    if not content:
        raise LlmError("openai response had empty content")
    return content


def generate_quiz(passage_text: str, passage_title: str) -> list[dict]:
    """Generates and strictly validates 3-5 MCQs for the given passage.
    Retries the LLM call ONCE on malformed output. Raises LlmError (with a
    short diagnostic, never raw LLM text) if still malformed after retry, or
    LlmConfigError if the API key is missing."""
    last_error: Optional[str] = None
    for attempt in range(2):
        raw = _call_openai_raw(passage_text, passage_title)
        try:
            payload = json.loads(raw)
            return _validate_quiz(payload)
        except (json.JSONDecodeError, ValueError) as exc:
            last_error = str(exc)
            continue

    raise LlmError(f"llm output failed validation after retry: {last_error}")
