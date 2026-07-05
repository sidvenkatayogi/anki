<!--
Copyright: Ankitects Pty Ltd and contributors
License: GNU AGPL, version 3 or later; http://www.gnu.org/licenses/agpl.html
-->
<script lang="ts">
    import { answerCard, getSchedulingStates } from "@generated/backend";
    import { CardAnswer_Rating } from "@generated/anki/scheduler_pb";

    import type { Category } from "./mcatMetrics";

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
    // (Performance/Readiness now live on the Scores dashboard, which reads the
    // same review log — so grading here still feeds those scores.)
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

    loadAll();

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
    // rest of the collection (and feeds the Scores dashboard). Returns false
    // on any failure.
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
        if (!graded) {
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
</script>

<div class="con-root practice-page">
    <header class="masthead">
        <span class="unit">ANKINETIC</span>
        <span class="sep">/</span>
        <span class="screen">PRACTICE</span><span class="caret" aria-hidden="true"
        ></span>
    </header>

    <section class="panel">
        {#if loadError}
            <div class="error-banner" role="alert">
                <span>! Couldn't load practice questions or history.</span>
                <button class="retry-button" on:click={loadAll}>Retry</button>
            </div>
        {:else if !questions || !currentQuestion}
            <div class="empty">Loading…</div>
        {:else}
            <div class="quiz-head">
                <span class="category-chip">
                    {categoryLabels[currentQuestion.category]}
                </span>
                <span class="q-count">
                    Q<b>{String(currentIndex + 1).padStart(2, "0")}</b>
                    <span class="of">/ {String(questions.length).padStart(2, "0")}</span>
                </span>
            </div>
            <div
                class="q-progress"
                style="--v: {(currentIndex + 1) / questions.length}"
                aria-hidden="true"
            >
                <div class="fill"></div>
            </div>

            {#if completedFullSet}
                <div class="completed-note">
                    ✓ Full set complete — keep going for more practice.
                </div>
            {/if}

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
                        <span class="marker" aria-hidden="true">
                            {String.fromCharCode(65 + i)}
                        </span>
                        <span class="opt-text">{option}</span>
                        {#if submitted && i === currentQuestion.answer_index}
                            <span class="verdict" aria-hidden="true">✓</span>
                        {:else if submitted && selectedIndex === i}
                            <span class="verdict" aria-hidden="true">✕</span>
                        {/if}
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
                <div
                    class="reveal"
                    class:is-correct={selectedIndex === currentQuestion.answer_index}
                    class:is-incorrect={selectedIndex !== currentQuestion.answer_index}
                >
                    <div class="result-label">
                        {selectedIndex === currentQuestion.answer_index
                            ? "› Correct"
                            : "› Incorrect"}
                    </div>
                    <div class="explanation">{currentQuestion.explanation}</div>
                    {#if saveWarning}
                        <div class="save-warning" role="alert">
                            ! Couldn't save this answer — your progress may not be
                            recorded.
                        </div>
                    {/if}
                    <button class="next-button" on:click={nextQuestion}>
                        Next question
                    </button>
                </div>
            {/if}
        {/if}
    </section>

    <div class="scores-note">
        <b>Performance</b>
        and
        <b>Readiness</b>
        scores live on the Scores dashboard.
    </div>
</div>

<style lang="scss">
    @use "../../../sass/mcat-tools.scss" as mcat;

    .practice-page {
        @include mcat.con-root;
        max-width: 48em;
        margin: 0 auto;
        min-height: 100%;
        padding: clamp(0.9rem, 2.5vw, 1.6rem);
        display: flex;
        flex-direction: column;
        gap: mcat.$mcat-space-md;
    }

    .masthead {
        display: flex;
        align-items: baseline;
        gap: 0.55em;
        font-size: 0.78rem;
        letter-spacing: 0.14em;
        color: mcat.$con-ink-faint;

        .unit {
            color: mcat.$con-ink-dim;
        }
        .screen {
            color: mcat.$con-amber;
            font-weight: 700;
        }
        .caret {
            @include mcat.con-caret;
        }
    }

    .panel {
        @include mcat.con-panel;
        padding: clamp(1rem, 2.5vw, 1.5rem);
    }

    .empty {
        color: mcat.$con-ink-dim;
        text-align: center;
        padding: 1.5em 0;
    }

    .error-banner {
        display: flex;
        align-items: center;
        justify-content: space-between;
        gap: mcat.$mcat-space-md;
        padding: mcat.$mcat-space-md;
        border: 1px solid color-mix(in srgb, #{mcat.$con-incorrect} 55%, transparent);
        border-radius: mcat.$con-radius;
        background: mcat.$con-incorrect-dim;
        color: mcat.$con-incorrect;
        font-weight: 600;
    }

    .retry-button {
        @include mcat.con-button-secondary;
    }

    // Non-blocking heads-up (sits alongside a still-usable reveal) — amber, not
    // the alarming red of a blocking error.
    .save-warning {
        margin-top: mcat.$mcat-space-sm;
        padding: mcat.$mcat-space-sm mcat.$mcat-space-md;
        border-radius: mcat.$con-radius-sm;
        background: mcat.$con-amber-dim;
        border: 1px solid mcat.$con-amber-line;
        color: mcat.$con-amber;
        font-size: 0.85rem;
    }

    .completed-note {
        margin-bottom: mcat.$mcat-space-sm;
        padding: mcat.$mcat-space-sm mcat.$mcat-space-md;
        border-radius: mcat.$con-radius-sm;
        background: mcat.$con-correct-dim;
        border: 1px solid color-mix(in srgb, #{mcat.$con-correct} 40%, transparent);
        color: mcat.$con-correct;
        font-size: 0.85rem;
    }

    // ── Quiz header + progress ──────────────────────────────────────────
    .quiz-head {
        display: flex;
        align-items: center;
        justify-content: space-between;
        gap: mcat.$mcat-space-sm;
        margin-bottom: mcat.$mcat-space-sm;
    }

    .category-chip {
        @include mcat.con-chip(mcat.$con-amber);
    }

    .q-count {
        color: mcat.$con-ink-dim;
        font-size: 0.85rem;
        letter-spacing: 0.06em;

        b {
            color: mcat.$con-ink;
            font-weight: 700;
        }
        .of {
            color: mcat.$con-ink-faint;
        }
    }

    .q-progress {
        @include mcat.con-bar(6px);
        --bar-fill: #{mcat.$con-amber};
        margin-bottom: mcat.$mcat-space-md;
    }

    .stem {
        font-family: mcat.$con-sans;
        font-size: 1.05rem;
        font-weight: 500;
        color: mcat.$con-ink;
        margin-bottom: mcat.$mcat-space-md;
        line-height: 1.5;
        text-wrap: pretty;
        // CARS questions embed a multi-paragraph reading passage in the stem;
        // preserve its line breaks (science stems are single-line, a no-op there).
        white-space: pre-line;
    }

    // ── Options ─────────────────────────────────────────────────────────
    .options {
        display: flex;
        flex-direction: column;
        gap: mcat.$mcat-space-sm;
        margin-bottom: mcat.$mcat-space-md;
    }

    .option {
        @include mcat.con-panel-interactive;
        display: flex;
        align-items: center;
        gap: 0.75em;
        width: 100%;
        text-align: start;
        font-family: mcat.$con-sans;
        color: mcat.$con-ink;
        padding: 0.7em 0.85em;

        .marker {
            flex: none;
            display: grid;
            place-items: center;
            width: 1.9em;
            height: 1.9em;
            border-radius: mcat.$con-radius-sm;
            font-family: mcat.$con-mono;
            font-size: 0.85em;
            font-weight: 700;
            background: mcat.$con-well;
            border: 1px solid mcat.$con-line;
            color: mcat.$con-ink-dim;
            transition:
                background mcat.$mcat-dur mcat.$mcat-ease,
                color mcat.$mcat-dur mcat.$mcat-ease,
                border-color mcat.$mcat-dur mcat.$mcat-ease;
        }

        .opt-text {
            flex: 1;
            line-height: 1.4;
        }

        .verdict {
            flex: none;
            font-family: mcat.$con-mono;
            font-weight: 700;
        }

        &.selected {
            border-color: mcat.$con-amber;
            background: mcat.$con-amber-dim;

            .marker {
                background: mcat.$con-amber;
                border-color: mcat.$con-amber;
                color: mcat.$con-amber-ink;
            }
        }

        &.correct {
            border-color: mcat.$con-correct;
            background: mcat.$con-correct-dim;

            .marker {
                background: mcat.$con-correct;
                border-color: mcat.$con-correct;
                color: #06210d;
            }
            .verdict {
                color: mcat.$con-correct;
            }
        }

        &.incorrect {
            border-color: mcat.$con-incorrect;
            background: mcat.$con-incorrect-dim;

            .marker {
                background: mcat.$con-incorrect;
                border-color: mcat.$con-incorrect;
                color: #2a0705;
            }
            .verdict {
                color: mcat.$con-incorrect;
            }
        }

        &:disabled {
            cursor: default;
        }
    }

    .submit-button,
    .next-button {
        @include mcat.con-button-primary;
        width: 100%;
    }

    // ── Reveal / explanation ────────────────────────────────────────────
    // Full-border panel tinted by result — no side-stripe.
    .reveal {
        display: flex;
        flex-direction: column;
        align-items: stretch;
        gap: mcat.$mcat-space-sm;
        padding: mcat.$mcat-space-md;
        border-radius: mcat.$con-radius;
        border: 1px solid mcat.$con-line;

        &.is-correct {
            background: mcat.$con-correct-dim;
            border-color: color-mix(in srgb, #{mcat.$con-correct} 45%, transparent);
        }
        &.is-incorrect {
            background: mcat.$con-incorrect-dim;
            border-color: color-mix(in srgb, #{mcat.$con-incorrect} 45%, transparent);
        }
    }

    .result-label {
        font-weight: 700;
        font-size: 0.8rem;
        letter-spacing: 0.1em;
        text-transform: uppercase;

        .is-correct & {
            color: mcat.$con-correct;
        }
        .is-incorrect & {
            color: mcat.$con-incorrect;
        }
    }

    .explanation {
        font-family: mcat.$con-sans;
        color: mcat.$con-ink;
        line-height: 1.5;
        text-wrap: pretty;
    }

    .next-button {
        margin-top: mcat.$mcat-space-xs;
    }

    .scores-note {
        text-align: center;
        color: mcat.$con-ink-faint;
        font-size: 0.82rem;

        b {
            color: mcat.$con-ink-dim;
            font-weight: 600;
        }
    }

    @media (prefers-reduced-motion: reduce) {
        .q-progress .fill,
        .option {
            transition: none;
        }
    }
</style>
