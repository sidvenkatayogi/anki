# Copyright: Ankitects Pty Ltd and contributors
# License: GNU AGPL, version 3 or later; http://www.gnu.org/licenses/agpl.html
"""Pydantic request/response schemas for the mcat_tools API.

Shapes match `contracts/api.md` and `contracts/data-model.md` from the
2026-07-02-read-practice-tabs factory run exactly.
"""

from __future__ import annotations

from typing import List, Literal, Optional

from pydantic import BaseModel, Field

Category = Literal["bio_biochem", "chem_phys", "psych_soc", "cars"]
SourceName = Literal["wikipedia", "news", "gutenberg"]


class ErrorBody(BaseModel):
    code: str
    message: str


class ErrorResponse(BaseModel):
    error: ErrorBody


class QuizQuestion(BaseModel):
    id: str
    stem: str
    options: List[str]
    answer_index: int
    explanation: str


class ReadPassageResponse(BaseModel):
    passage_id: str
    source: SourceName
    title: str
    text: str
    url: str
    quiz: List[QuizQuestion]


class SeedQuestion(BaseModel):
    id: str
    category: Category
    stem: str
    options: List[str]
    answer_index: int
    explanation: str
    difficulty_b: float = 0.0


class PracticeQuestionsResponse(BaseModel):
    questions: List[SeedQuestion]


class PracticeHistoryItem(BaseModel):
    question_id: str
    category: Category
    correct: bool
    difficulty_b: float = 0.0


class FsrsCategorySummary(BaseModel):
    category: Category
    average_recall: float
    mastered_fraction: float
    enough_data: bool
    graded_reviews: int


class FsrsSummary(BaseModel):
    per_category: List[FsrsCategorySummary] = Field(default_factory=list)
    overall_mean_recall: float = 0.0


class MetricsComputeRequest(BaseModel):
    practice_history: List[PracticeHistoryItem] = Field(default_factory=list)
    fsrs: FsrsSummary


class PerformanceCategory(BaseModel):
    category: Category
    p: float
    enough_data: bool
    n: int


class PerformanceOverall(BaseModel):
    p: float
    enough_data: bool
    n: int


class Performance(BaseModel):
    overall: PerformanceOverall
    per_category: List[PerformanceCategory]


class Readiness(BaseModel):
    score_point: int
    score_low: int
    score_high: int
    confidence: Literal["high", "medium", "low"]
    note: str
    enough_data: bool


class MetricsComputeResponse(BaseModel):
    performance: Performance
    readiness: Readiness


class HealthResponse(BaseModel):
    status: str = "ok"


class VersionResponse(BaseModel):
    version: str
    build: str


# ---------------------------------------------------------------------------
# Palace desktop-sync (2026-07-02-palace-desktop-sync factory run).
#
# The server is a dumb pass-through blob store for these shapes -- field
# names are wire-exact camelCase (matching iOS Codable + desktop TS types
# in `contracts/data-model.md`), NOT the snake_case convention used above
# for the Read/Practice internal API.
# ---------------------------------------------------------------------------


class PalacePoint(BaseModel):
    x: float
    y: float


class Locus(BaseModel):
    id: str
    cardID: int
    label: str
    mnemonic: str
    transform: Optional[List[float]] = None
    anchorID: Optional[str] = None
    point: PalacePoint
    learned: bool


class Palace(BaseModel):
    id: str
    name: str
    createdAt: str
    updatedAt: str
    capacity: int
    loci: List[Locus] = Field(default_factory=list)
    hasPhoto: bool
    hasWorldMap: bool
    photoVersion: Optional[int] = None


class PalaceSummary(BaseModel):
    id: str
    name: str
    updatedAt: str
    lociCount: int
    hasPhoto: bool
    photoVersion: Optional[int] = None


class PalaceListResponse(BaseModel):
    palaces: List[PalaceSummary]


class PhotoVersionResponse(BaseModel):
    photoVersion: int
