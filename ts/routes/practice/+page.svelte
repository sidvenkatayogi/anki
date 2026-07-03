<!--
Copyright: Ankitects Pty Ltd and contributors
License: GNU AGPL, version 3 or later; http://www.gnu.org/licenses/agpl.html
-->
<script lang="ts">
    import type { TagMasteryResponse } from "@generated/anki/stats_pb";
    import { answerCard, getSchedulingStates, tagMastery } from "@generated/backend";
    import { CardAnswer_Rating } from "@generated/anki/scheduler_pb";

    import TitledContainer from "$lib/components/TitledContainer.svelte";

    import type {
        Category,
        FsrsCategorySummary,
        FsrsSummary,
        Performance,
        PracticeHistoryItem,
        Readiness,
    } from "./mcatMetrics";
    import { CATEGORIES, computePerformance, computeReadiness } from "./mcatMetrics";

    interface SeedQuestion {
        id: string;
        category: Category;
        stem: string;
        options: string[];
        answer_index: number;
        explanation: string;
        difficulty_b: number;
        // The collection card whose review log records answers to this
        // question (a practice answer is a review of this card).
        card_id: number;
    }

    interface PracticeAnswer {
        client_answer_id: string;
        question_id: string;
        category: Category;
        correct: boolean;
        difficulty_b: number;
        answered_at: number;
    }

    // Same MileDown-taxonomy grouping as the Mastery page (depth-1 collapses
    // everything into one root tag, so we use depth-2 and map the resulting
    // "MileDown::<Section>" tags onto the 4 canonical categories below).
    // See domains/frontend/plan.md's "Category -> tag mapping deviation" note.
    const fsrsGroupDepth = 2;

    const categoryLabels: Record<Category, string> = {
        bio_biochem: "Bio/Biochem",
        chem_phys: "Chem/Phys",
        psych_soc: "Psych/Soc",
        cars: "CARS",
    };

    let questions: SeedQuestion[] | null = null;
    let history: PracticeAnswer[] | null = null;
    let loadError = false;

    let currentIndex = 0;
    let selectedIndex: number | null = null;
    let submitted = false;
    let submitting = false;
    let completedFullSet = false;

    let performance: Performance | null = null;
    let fsrsSummary: FsrsSummary | null = null;
    let readiness: Readiness | null = null;
    // Set when the current question's answer couldn't be persisted to the
    // local history store (after a best-effort retry) -- see submitAnswer().
    // Informational only: the reveal/Next flow is never blocked on this.
    let saveWarning = false;

    async function loadAll(): Promise<void> {
        loadError = false;
        try {
            const [seedResp, historyResp] = await Promise.all([
                fetch("/_anki/practiceQuestions"),
                fetch("/_anki/practiceHistory"),
            ]);
            if (!seedResp.ok || !historyResp.ok) {
                throw new Error("bad response");
            }
            questions = (await seedResp.json()) as SeedQuestion[];
            const historyJson = (await historyResp.json()) as {
                records: PracticeAnswer[];
            };
            history = historyJson.records ?? [];
            applyResumePosition();
            recomputePerformance();
        } catch (e) {
            loadError = true;
            questions = null;
            history = null;
        }
    }

    // Resume where the (synced) answers left off: jump to the first question
    // with no recorded answer. Only applied on initial load, so it doesn't
    // fight the user's own Next progression. Cross-device because the answers
    // sync via the review log even though the on-screen cursor doesn't.
    function applyResumePosition(): void {
        if (!questions || questions.length === 0) {
            return;
        }
        const answered = new Set((history ?? []).map((r) => r.question_id));
        const idx = questions.findIndex((q) => !answered.has(q.id));
        selectedIndex = null;
        submitted = false;
        if (idx === -1) {
            currentIndex = 0;
            completedFullSet = true;
        } else {
            currentIndex = idx;
        }
    }

    // Re-read the answer history from the collection's review log (called after
    // grading a question) and recompute Performance.
    async function loadHistory(): Promise<void> {
        try {
            const resp = await fetch("/_anki/practiceHistory");
            if (!resp.ok) {
                return;
            }
            const json = (await resp.json()) as { records: PracticeAnswer[] };
            history = json.records ?? [];
            recomputePerformance();
        } catch (e) {
            // Keep the prior history on a transient read failure.
        }
    }

    function recomputePerformance(): void {
        if (!history) {
            return;
        }
        const items: PracticeHistoryItem[] = history.map((r) => ({
            question_id: r.question_id,
            category: r.category,
            correct: r.correct,
            difficulty_b: r.difficulty_b,
        }));
        performance = computePerformance(items);
        recomputeReadiness();
    }

    function recomputeReadiness(): void {
        if (!performance || !fsrsSummary) {
            return;
        }
        readiness = computeReadiness(performance, fsrsSummary);
    }

    // Maps a MileDown::<Section> tag (or the "(untagged)" sentinel) to one of
    // the 4 canonical categories via case-insensitive substring match. Order
    // matters: bio_biochem is checked before chem_phys so "Biochemistry"
    // (which contains "chem") is not misrouted. Unmatched tags (including
    // "(untagged)") are skipped -- never folded into a real category.
    function tagToCategory(tag: string): Category | null {
        const t = tag.toLowerCase();
        if (t.includes("biochem") || t.includes("biology") || t.includes("bio")) {
            return "bio_biochem";
        }
        if (t.includes("chem") || t.includes("physics") || t.includes("phys")) {
            return "chem_phys";
        }
        if (
            t.includes("psych") ||
            t.includes("behavior") ||
            t.includes("social") ||
            t.includes("soc")
        ) {
            return "psych_soc";
        }
        if (t.includes("cars") || t.includes("critical") || t.includes("reading")) {
            return "cars";
        }
        return null;
    }

    function buildFsrsSummary(data: TagMasteryResponse): FsrsSummary {
        const per_category: FsrsCategorySummary[] = CATEGORIES.map((category) => {
            const matched = data.groups.filter(
                (g) => tagToCategory(g.tag) === category,
            );
            const cardsWithState = matched.reduce(
                (sum, g) => sum + g.cardsWithState,
                0,
            );
            if (cardsWithState === 0) {
                return {
                    category,
                    average_recall: 0,
                    mastered_fraction: 0,
                    enough_data: false,
                    graded_reviews: 0,
                };
            }
            const masteredCards = matched.reduce((sum, g) => sum + g.masteredCards, 0);
            const gradedReviews = matched.reduce((sum, g) => sum + g.gradedReviews, 0);
            const weightedRecall =
                matched.reduce(
                    (sum, g) => sum + g.averageRecall * g.cardsWithState,
                    0,
                ) / cardsWithState;
            return {
                category,
                average_recall: weightedRecall,
                mastered_fraction: masteredCards / cardsWithState,
                enough_data: cardsWithState >= 20,
                graded_reviews: gradedReviews,
            };
        });

        return {
            per_category,
            // Reusing the backend's own weighted overall figure rather than
            // recomputing (it already spans all groups, tagged or not).
            overall_mean_recall: data.overallMeanRecall,
        };
    }

    async function loadFsrsSummary(): Promise<void> {
        try {
            const data = await tagMastery({
                groupDepth: fsrsGroupDepth,
                masteredThreshold: 0,
                // Exclude the MCAT practice/palace cards so they never perturb
                // the Readiness figure (which reflects the study deck only).
                search: "-tag:mcat_practice -tag:mcat_palace",
            });
            fsrsSummary = buildFsrsSummary(data);
            recomputeReadiness();
        } catch (e) {
            // FSRS summary is an enhancement layer over the offline practice
            // metrics; if it fails, per-category readiness just treats every
            // category as fsrs-not-enough-data (still shows Performance).
            fsrsSummary = {
                per_category: CATEGORIES.map((category) => ({
                    category,
                    average_recall: 0,
                    mastered_fraction: 0,
                    enough_data: false,
                    graded_reviews: 0,
                })),
                overall_mean_recall: 0,
            };
            recomputeReadiness();
        }
    }

    loadAll();
    loadFsrsSummary();

    $: currentQuestion = questions ? questions[currentIndex] : null;

    function selectOption(i: number): void {
        if (submitted) {
            return;
        }
        selectedIndex = i;
    }

    // Record one answer as a review of the question's card (correct -> Good,
    // wrong -> Again) via the real scheduler, exactly as the memory-palace
    // page grades pinned cards. This writes a revlog entry that syncs with the
    // rest of the collection. Returns false on any failure.
    async function gradePracticeCard(
        cardId: number,
        correct: boolean,
    ): Promise<boolean> {
        const rating = correct ? CardAnswer_Rating.GOOD : CardAnswer_Rating.AGAIN;
        try {
            const states = await getSchedulingStates({ cid: BigInt(cardId) });
            const newState = correct ? states.good : states.again;
            if (!states.current || !newState) {
                return false;
            }
            await answerCard({
                cardId: BigInt(cardId),
                currentState: states.current,
                newState,
                rating,
                answeredAtMillis: BigInt(Date.now()),
                millisecondsTaken: 1000,
                // A practice card isn't the reviewer's queue head, so skip the
                // queue pop; the FSRS/revlog update still happens.
                skipQueue: true,
            });
            return true;
        } catch (e) {
            return false;
        }
    }

    async function submitAnswer(): Promise<void> {
        if (!currentQuestion || selectedIndex === null || submitting || submitted) {
            return;
        }
        submitting = true;
        submitted = true;
        saveWarning = false;

        const correct = selectedIndex === currentQuestion.answer_index;
        const graded = await gradePracticeCard(currentQuestion.card_id, correct);
        if (graded) {
            // Re-read history from the (updated) review log and recompute.
            await loadHistory();
        } else {
            // Never block the reveal/Next flow on this -- just make the
            // failure visible instead of silently dropping the answer.
            saveWarning = true;
        }
        submitting = false;
    }

    function nextQuestion(): void {
        if (!questions) {
            return;
        }
        selectedIndex = null;
        submitted = false;
        saveWarning = false;
        const nextIndex = currentIndex + 1;
        if (nextIndex >= questions.length) {
            currentIndex = 0;
            completedFullSet = true;
        } else {
            currentIndex = nextIndex;
        }
    }

    function pct(n: number): string {
        return `${Math.round(n * 100)}%`;
    }
</script>

<div class="practice-page">
    <TitledContainer title="Practice">
        {#if loadError}
            <div class="error-banner">
                <span>Couldn't load practice questions or history.</span>
                <button class="retry-button" on:click={loadAll}>Retry</button>
            </div>
        {:else if !questions || !currentQuestion}
            <div class="empty">Loading...</div>
        {:else}
            {#if completedFullSet}
                <div class="completed-note">
                    You've completed the full question set — keep going for more
                    practice!
                </div>
            {/if}
            <div class="question-meta">
                Question {currentIndex + 1} of {questions.length}
            </div>
            <div class="stem">{currentQuestion.stem}</div>
            <div class="options" role="radiogroup" aria-label="Answer options">
                {#each currentQuestion.options as option, i (i)}
                    <button
                        type="button"
                        role="radio"
                        aria-checked={selectedIndex === i}
                        class="option"
                        class:selected={selectedIndex === i}
                        class:correct={submitted && i === currentQuestion.answer_index}
                        class:incorrect={submitted &&
                            selectedIndex === i &&
                            i !== currentQuestion.answer_index}
                        disabled={submitted}
                        on:click={() => selectOption(i)}
                    >
                        {option}
                    </button>
                {/each}
            </div>

            {#if !submitted}
                <button
                    class="submit-button"
                    disabled={selectedIndex === null || submitting}
                    on:click={submitAnswer}
                >
                    Submit
                </button>
            {:else}
                <div class="reveal">
                    <div class="category-chip">
                        {categoryLabels[currentQuestion.category]}
                    </div>
                    <div class="result-label">
                        {selectedIndex === currentQuestion.answer_index
                            ? "Correct!"
                            : "Incorrect"}
                    </div>
                    <div class="explanation">{currentQuestion.explanation}</div>
                    {#if saveWarning}
                        <div class="save-warning" role="alert">
                            Couldn't save this answer — your progress may not be
                            recorded.
                        </div>
                    {/if}
                    <button class="next-button" on:click={nextQuestion}>Next</button>
                </div>
            {/if}
        {/if}
    </TitledContainer>

    {#if performance}
        <TitledContainer title="Performance">
            {#if !performance.overall.enough_data}
                <div class="not-enough-data">
                    Not enough data yet — answer at least 5 questions to see your
                    overall performance.
                </div>
            {:else}
                <div class="overall-performance">
                    <div class="point">{pct(performance.overall.p)}</div>
                    <div class="caption">
                        chance of getting a new question right (based on
                        {performance.overall.n} answers)
                    </div>
                </div>
            {/if}

            <div class="category-grid">
                {#each performance.per_category as cat (cat.category)}
                    <div class="category-card">
                        <div class="category-name">{categoryLabels[cat.category]}</div>
                        {#if cat.enough_data}
                            <div class="category-value">{pct(cat.p)}</div>
                            <div class="category-caption">{cat.n} answers</div>
                        {:else}
                            <div class="category-value dash">Not enough data</div>
                            <div class="category-caption">
                                {cat.n} answer{cat.n === 1 ? "" : "s"}
                            </div>
                        {/if}
                    </div>
                {/each}
            </div>
        </TitledContainer>
    {/if}

    {#if readiness}
        <TitledContainer title="Readiness">
            {#if !readiness.enough_data || readiness.confidence === "low"}
                <div class="not-enough-data">
                    {readiness.enough_data
                        ? "Keep answering questions and reviewing cards — there isn't enough confidence in a score estimate yet."
                        : readiness.note}
                </div>
            {:else}
                <div class="readiness-band">
                    <div class="score-point">{readiness.score_point}</div>
                    <div class="score-range">
                        Likely range: {readiness.score_low} – {readiness.score_high}
                    </div>
                    <div class="confidence confidence-{readiness.confidence}">
                        Confidence: {readiness.confidence}
                    </div>
                </div>
            {/if}
        </TitledContainer>
    {/if}
</div>

<style lang="scss">
    @use "../../../sass/mcat-tools.scss" as mcat;

    .practice-page {
        max-width: 46em;
        margin: 0 auto;
        padding: 1em;
        display: flex;
        flex-direction: column;
        gap: mcat.$mcat-space-lg;
        font-variant-numeric: tabular-nums;
    }

    .empty,
    .not-enough-data {
        color: var(--fg-subtle, #666);
        font-style: italic;
        padding: 0.75em 0;
        text-align: center;
    }

    .error-banner {
        display: flex;
        align-items: center;
        justify-content: space-between;
        gap: mcat.$mcat-space-md;
        padding: mcat.$mcat-space-md;
        border: 1px solid var(--border, #8884);
        border-radius: 8px;
        background: color-mix(in srgb, red 8%, transparent);
    }

    .retry-button {
        @include mcat.mcat-button-secondary;
    }

    // Non-blocking, informational -- a warmer/less alarming tone than
    // .error-banner (which blocks the whole page); this sits alongside a
    // still-usable reveal, so it should read as a heads-up, not a failure.
    .save-warning {
        margin-top: mcat.$mcat-space-sm;
        padding: mcat.$mcat-space-sm mcat.$mcat-space-md;
        border-radius: 8px;
        background: color-mix(in srgb, orange 12%, transparent);
        border: 1px solid color-mix(in srgb, orange 45%, transparent);
        font-weight: 600;
        text-align: center;
    }

    .completed-note {
        margin-bottom: mcat.$mcat-space-sm;
        padding: mcat.$mcat-space-sm mcat.$mcat-space-md;
        border-radius: 8px;
        background: mcat.$mcat-accent-soft;
        border: 1px solid mcat.$mcat-accent-border;
        font-weight: 600;
        text-align: center;
    }

    .question-meta {
        color: var(--fg-subtle, #666);
        font-size: 0.85em;
        margin-bottom: mcat.$mcat-space-xs;
    }

    .stem {
        font-size: 1.1em;
        font-weight: 600;
        margin-bottom: mcat.$mcat-space-md;
        line-height: 1.4;
        // CARS questions embed a multi-paragraph reading passage in the stem;
        // preserve its line breaks (science stems are single-line, so this is a no-op for them).
        white-space: pre-line;
    }

    .options {
        display: flex;
        flex-direction: column;
        gap: mcat.$mcat-space-sm;
        margin-bottom: mcat.$mcat-space-md;
    }

    .option {
        @include mcat.mcat-card;
        text-align: start;
        cursor: pointer;
        font: inherit;
        color: var(--fg, #000);
        transition:
            border-color 150ms ease-out,
            background 150ms ease-out;

        &:hover:not(:disabled) {
            border-color: mcat.$mcat-accent-border;
        }

        &.selected {
            border-color: mcat.$mcat-accent;
            background: mcat.$mcat-accent-soft;
        }

        &.correct {
            border-color: #2e8b57;
            background: color-mix(in srgb, #2e8b57 12%, transparent);
        }

        &.incorrect {
            border-color: #b23b3b;
            background: color-mix(in srgb, #b23b3b 12%, transparent);
        }

        &:disabled {
            cursor: default;
        }
    }

    .submit-button {
        @include mcat.mcat-button-primary;
    }

    .reveal {
        display: flex;
        flex-direction: column;
        align-items: flex-start;
        gap: mcat.$mcat-space-sm;
    }

    .category-chip {
        display: inline-block;
        padding: 0.25em 0.7em;
        border-radius: 999px;
        background: mcat.$mcat-accent-soft;
        border: 1px solid mcat.$mcat-accent-border;
        font-size: 0.8em;
        font-weight: 600;
    }

    .result-label {
        font-weight: 700;
        font-size: 1.05em;
    }

    .explanation {
        color: var(--fg-subtle, #444);
        line-height: 1.4;
    }

    .next-button {
        @include mcat.mcat-button-primary;
        margin-top: mcat.$mcat-space-xs;
    }

    .overall-performance {
        text-align: center;
        padding: 0.25em 0 mcat.$mcat-space-md;

        .point {
            font-size: 2.6em;
            font-weight: 700;
            line-height: 1.1;
            color: mcat.$mcat-accent;
        }

        .caption {
            color: var(--fg-subtle, #666);
            font-size: 0.9em;
        }
    }

    .category-grid {
        display: grid;
        grid-template-columns: repeat(auto-fit, minmax(9.5em, 1fr));
        gap: mcat.$mcat-space-sm;
    }

    .category-card {
        @include mcat.mcat-card;
        text-align: center;

        .category-name {
            font-weight: 600;
            font-size: 0.9em;
            margin-bottom: 0.3em;
        }

        .category-value {
            font-size: 1.4em;
            font-weight: 700;

            &.dash {
                font-size: 0.9em;
                font-weight: 500;
                font-style: italic;
                color: var(--fg-subtle, #999);
            }
        }

        .category-caption {
            font-size: 0.8em;
            color: var(--fg-subtle, #666);
        }
    }

    .readiness-band {
        text-align: center;
        padding: 0.25em 0 0.5em;

        .score-point {
            font-size: 2.6em;
            font-weight: 700;
            line-height: 1.1;
            color: mcat.$mcat-accent;
        }

        .score-range {
            color: var(--fg-subtle, #666);
            font-size: 0.95em;
        }

        .confidence {
            margin-top: mcat.$mcat-space-xs;
            font-size: 0.85em;
            font-weight: 600;
            text-transform: capitalize;
        }
    }
</style>
