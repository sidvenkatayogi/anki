<!--
Copyright: Ankitects Pty Ltd and contributors
License: GNU AGPL, version 3 or later; http://www.gnu.org/licenses/agpl.html
-->
<script lang="ts">
    import { onMount } from "svelte";

    // Plain hardcoded English strings are used throughout this page rather
    // than tr.*() Fluent calls - a deliberate, documented deviation for this
    // round (see domains/frontend/plan.md's "i18n decision"), to avoid a full
    // `just` codegen build regenerating the Fluent bindings.

    interface McatToolsConfig {
        url: string;
        token: string;
    }

    interface QuizQuestion {
        id: string;
        stem: string;
        options: string[];
        answer_index: number;
        explanation: string;
    }

    interface PassageResponse {
        passage_id: string;
        source: string;
        title: string;
        text: string;
        url: string;
        quiz: QuizQuestion[];
    }

    interface ApiErrorEnvelope {
        error?: { code?: string; message?: string };
    }

    type ViewState =
        | "checking-config"
        | "not-configured"
        | "loading"
        | "error"
        | "success";

    let state: ViewState = "checking-config";
    let config: McatToolsConfig | null = null;
    let errorMessage = "";
    let passage: PassageResponse | null = null;

    // Inline config form - there's no separate settings dialog for this yet,
    // so this form is intentionally the only way to configure the sync
    // server URL/token right now.
    let formUrl = "";
    let formToken = "";
    let savingConfig = false;
    let configSaveError = "";

    // In-memory quiz state only - never persisted or sent to any
    // history/metrics endpoint, and reset whenever a new passage is fetched.
    let selected: (number | null)[] = [];
    let submitted = false;
    let submitting = false;

    onMount(() => {
        checkConfigAndLoad();
    });

    async function checkConfigAndLoad(): Promise<void> {
        state = "checking-config";
        try {
            const res = await fetch("/_anki/mcatToolsConfig");
            if (!res.ok) {
                throw new Error("config fetch failed");
            }
            const cfg = (await res.json()) as McatToolsConfig;
            config = cfg;
            if (!cfg.url || !cfg.token) {
                formUrl = cfg.url ?? "";
                formToken = cfg.token ?? "";
                state = "not-configured";
                return;
            }
            await loadPassage();
        } catch {
            // Mediasrv endpoint unreachable for some reason - fall back to
            // the not-configured state rather than a blank/frozen page.
            state = "not-configured";
        }
    }

    async function saveConfig(): Promise<void> {
        const url = formUrl.trim();
        const token = formToken.trim();
        if (!url || !token) {
            configSaveError = "Both a server URL and a token are required.";
            return;
        }
        configSaveError = "";
        savingConfig = true;
        try {
            await fetch("/_anki/setMcatToolsConfig", {
                method: "POST",
                // mediasrv's dynamic POST gate requires this literal content-type
                // for same-origin /_anki/ requests (see qt/aqt/mediasrv.py
                // _check_dynamic_request_permissions) -- the body is still JSON text.
                headers: { "Content-Type": "application/binary" },
                body: JSON.stringify({ url, token }),
            });
            config = { url, token };
            await loadPassage();
        } catch {
            configSaveError = "Couldn't save configuration. Please try again.";
        } finally {
            savingConfig = false;
        }
    }

    async function loadPassage(): Promise<void> {
        if (!config || !config.url || !config.token) {
            state = "not-configured";
            return;
        }
        state = "loading";
        passage = null;
        selected = [];
        submitted = false;
        try {
            const base = config.url.replace(/\/+$/, "");
            const res = await fetch(`${base}/read/passage`, {
                method: "GET",
                mode: "cors",
                headers: { "X-Mcat-Token": config.token },
            });
            if (!res.ok) {
                let message = `Couldn't reach the server (status ${res.status}).`;
                try {
                    const body = (await res.json()) as ApiErrorEnvelope;
                    if (body?.error?.message) {
                        message = body.error.message;
                    }
                } catch {
                    // Non-JSON error body - keep the generic message.
                }
                errorMessage = message;
                state = "error";
                return;
            }
            const data = (await res.json()) as PassageResponse;
            passage = data;
            selected = data.quiz.map(() => null);
            submitted = false;
            state = "success";
        } catch {
            errorMessage =
                "Couldn't reach the server. Check your connection and try again.";
            state = "error";
        }
    }

    function selectOption(questionIndex: number, optionIndex: number): void {
        if (submitted) {
            return;
        }
        selected[questionIndex] = optionIndex;
        selected = selected;
    }

    function submitQuiz(): void {
        if (submitting || submitted) {
            return;
        }
        // Disable immediately to prevent double-submit; there's no network
        // call here (answers are in-memory only), so this simply reveals
        // the results.
        submitting = true;
        submitted = true;
    }

    function newPassage(): void {
        loadPassage();
    }

    function optionLetter(index: number): string {
        return String.fromCharCode(65 + index);
    }
</script>

<div class="read-page">
    {#if state === "checking-config"}
        <div class="status-block">
            <div class="spinner" aria-hidden="true"></div>
            <p>Checking configuration…</p>
        </div>
    {:else if state === "not-configured"}
        <div class="empty-state">
            <h1>Read</h1>
            <p class="explain">
                The Read tab pulls a short passage and quiz from your sync server. To
                use it, set your sync server URL and MCAT tools token below.
            </p>
            <form class="config-form" on:submit|preventDefault={saveConfig}>
                <label>
                    <span>Server URL</span>
                    <input
                        type="text"
                        bind:value={formUrl}
                        placeholder="https://your-sync-server.example.com"
                        autocomplete="off"
                    />
                </label>
                <label>
                    <span>Token</span>
                    <input
                        type="password"
                        bind:value={formToken}
                        placeholder="MCAT tools token"
                        autocomplete="off"
                    />
                </label>
                {#if configSaveError}
                    <div class="inline-error">{configSaveError}</div>
                {/if}
                <button type="submit" class="btn-accent" disabled={savingConfig}>
                    {savingConfig ? "Saving…" : "Save"}
                </button>
            </form>
        </div>
    {:else if state === "loading"}
        <div class="status-block">
            <div class="spinner" aria-hidden="true"></div>
            <p>Fetching a new passage…</p>
        </div>
    {:else if state === "error"}
        <div class="error-banner" role="alert">
            <span class="icon" aria-hidden="true">⚠</span>
            <div class="error-text">
                <strong>Couldn't load a passage</strong>
                <p>{errorMessage}</p>
            </div>
            <button class="btn-accent" on:click={loadPassage}>Retry</button>
        </div>
    {:else if state === "success" && passage}
        <div class="toolbar">
            <button class="btn-accent" on:click={newPassage}>New passage</button>
        </div>

        <article class="passage-card">
            <h1>{passage.title}</h1>
            <div class="attribution">
                Source:
                <a href={passage.url} target="_blank" rel="noopener noreferrer">
                    {passage.source}
                </a>
            </div>
            <p class="passage-text">{passage.text}</p>
        </article>

        <section class="quiz">
            <h2 class="quiz-title">Quiz</h2>
            {#each passage.quiz as q, qi (q.id)}
                <div class="question-card">
                    <p class="stem">{qi + 1}. {q.stem}</p>
                    <div
                        class="options"
                        role="radiogroup"
                        aria-label={`Question ${qi + 1} options`}
                    >
                        {#each q.options as opt, oi}
                            <button
                                type="button"
                                class="option"
                                class:selected={selected[qi] === oi}
                                class:correct-answer={submitted &&
                                    oi === q.answer_index}
                                class:incorrect-pick={submitted &&
                                    selected[qi] === oi &&
                                    oi !== q.answer_index}
                                role="radio"
                                aria-checked={selected[qi] === oi}
                                disabled={submitted}
                                on:click={() => selectOption(qi, oi)}
                            >
                                <span class="opt-letter">{optionLetter(oi)}</span>
                                <span class="opt-text">{opt}</span>
                            </button>
                        {/each}
                    </div>
                    {#if submitted}
                        <div
                            class="result"
                            class:is-correct={selected[qi] === q.answer_index}
                            class:is-incorrect={selected[qi] !== q.answer_index}
                        >
                            <strong class="result-label">
                                {#if selected[qi] === q.answer_index}
                                    ✓ Correct
                                {:else if selected[qi] === null}
                                    — Not answered (correct answer: {optionLetter(
                                        q.answer_index,
                                    )})
                                {:else}
                                    ✗ Incorrect
                                {/if}
                            </strong>
                            <p class="explanation">{q.explanation}</p>
                        </div>
                    {/if}
                </div>
            {/each}

            {#if !submitted}
                <button
                    class="btn-accent submit-btn"
                    disabled={submitting}
                    on:click={submitQuiz}
                >
                    Submit
                </button>
            {/if}
        </section>
    {/if}
</div>

<style lang="scss">
    // Shared design tokens (accent colour, spacing scale) with the Practice
    // tab, so both stay visually cohesive. `sass/mcat-tools.scss` didn't
    // exist yet when this page was first written (it landed in parallel via
    // the sibling `practice-page` worker), and the dev-server's Vite
    // `fs.allow` list only covered `../out` at the time, so this import was
    // originally worked around with local hardcoded values. Both blockers
    // are now resolved (see domain round-1 reconciliation), so this now
    // consumes the shared module directly.
    @use "../../../sass/mcat-tools" as mcat;
    $accent: mcat.$mcat-accent;
    $accent-fg: mcat.$mcat-accent-fg;

    .read-page {
        max-width: 46em;
        margin: 0 auto;
        padding: 1em;
    }

    .status-block {
        display: flex;
        flex-direction: column;
        align-items: center;
        gap: 0.75em;
        padding: 3em 1em;
        color: var(--fg-subtle, #666);
    }

    .spinner {
        width: 2em;
        height: 2em;
        border-radius: 50%;
        border: 3px solid color-mix(in srgb, var(--fg, #000) 12%, transparent);
        border-top-color: $accent;
        animation: spin 800ms linear infinite;
    }

    @keyframes spin {
        to {
            transform: rotate(360deg);
        }
    }

    @media (prefers-reduced-motion: reduce) {
        .spinner {
            animation: none;
        }
    }

    .empty-state {
        max-width: 30em;
        margin: 2em auto;
        text-align: center;

        h1 {
            margin-bottom: 0.4em;
        }

        .explain {
            color: var(--fg-subtle, #666);
            margin-bottom: 1.25em;
        }
    }

    .config-form {
        display: flex;
        flex-direction: column;
        gap: 0.9em;
        text-align: start;
        padding: 1.25em;
        border: 1px solid var(--border, #8884);
        border-radius: 10px;
        background: var(--canvas-elevated, transparent);

        label {
            display: flex;
            flex-direction: column;
            gap: 0.3em;
            font-weight: 600;
            font-size: 0.9em;
        }

        input {
            font: inherit;
            padding: 0.5em 0.6em;
            border-radius: 6px;
            border: 1px solid var(--border, #8884);
            background: var(--canvas, transparent);
            color: var(--fg, inherit);

            &:focus-visible {
                outline: 2px solid $accent;
                outline-offset: 1px;
            }
        }
    }

    .inline-error {
        color: color-mix(in srgb, #c0392b 80%, var(--fg, #000));
        font-size: 0.9em;
    }

    .btn-accent {
        align-self: flex-start;
        padding: 0.55em 1.1em;
        border: none;
        border-radius: 8px;
        background: $accent;
        color: $accent-fg;
        font-weight: 600;
        cursor: pointer;
        transition: background 150ms ease-out;

        &:hover:not(:disabled) {
            background: color-mix(in srgb, $accent 85%, black);
        }

        &:disabled {
            opacity: 0.6;
            cursor: not-allowed;
        }

        &:focus-visible {
            outline: 2px solid $accent;
            outline-offset: 2px;
        }
    }

    .error-banner {
        display: flex;
        align-items: flex-start;
        gap: 0.75em;
        padding: 1em 1.1em;
        margin: 1.5em 0;
        border-radius: 10px;
        border: 1px solid color-mix(in srgb, #c9971f 55%, var(--border, #8884));
        background: color-mix(in srgb, #c9971f 12%, transparent);

        .icon {
            font-size: 1.3em;
            line-height: 1;
        }

        .error-text {
            flex: 1;

            strong {
                display: block;
                margin-bottom: 0.25em;
            }

            p {
                margin: 0;
                color: var(--fg-subtle, #666);
            }
        }

        .btn-accent {
            align-self: center;
        }
    }

    .toolbar {
        display: flex;
        justify-content: flex-end;
        margin-bottom: 1em;
    }

    .passage-card {
        padding: 1.25em 1.5em;
        border-radius: 12px;
        border: 1px solid var(--border, #8884);
        background: var(--canvas-elevated, transparent);
        box-shadow: 0 1px 3px color-mix(in srgb, var(--fg, #000) 8%, transparent);
        margin-bottom: 1.5em;

        h1 {
            margin: 0 0 0.3em;
            font-size: 1.4em;
        }

        .attribution {
            font-size: 0.85em;
            color: var(--fg-subtle, #666);
            margin-bottom: 0.9em;

            a {
                color: $accent;
            }
        }

        .passage-text {
            max-width: 42em;
            line-height: 1.65;
            font-size: 1.02em;
            white-space: pre-wrap;
        }
    }

    .quiz {
        padding-top: 1em;
        border-top: 1px solid var(--border, #8884);
    }

    .quiz-title {
        font-size: 1.1em;
        margin: 0 0 0.9em;
    }

    .question-card {
        padding: 1em 1.2em;
        margin-bottom: 1em;
        border-radius: 10px;
        border: 1px solid var(--border, #8884);
        background: var(--canvas-elevated, transparent);
    }

    .stem {
        font-weight: 600;
        margin: 0 0 0.75em;
    }

    .options {
        display: flex;
        flex-direction: column;
        gap: 0.5em;
    }

    .option {
        display: flex;
        align-items: center;
        gap: 0.65em;
        width: 100%;
        text-align: start;
        padding: 0.55em 0.8em;
        border-radius: 8px;
        border: 1px solid var(--border, #8884);
        background: transparent;
        color: var(--fg, inherit);
        font: inherit;
        cursor: pointer;
        transition:
            background 120ms ease-out,
            border-color 120ms ease-out;

        &:hover:not(:disabled) {
            background: color-mix(in srgb, var(--fg, #000) 5%, transparent);
        }

        &:focus-visible {
            outline: 2px solid $accent;
            outline-offset: 1px;
        }

        &.selected {
            border-color: $accent;
            background: color-mix(in srgb, $accent 12%, transparent);
        }

        &:disabled {
            cursor: default;
        }

        &.correct-answer {
            border-color: #2f8f57;
            background: color-mix(in srgb, #2f8f57 14%, transparent);
        }

        &.incorrect-pick {
            border-color: #c0392b;
            background: color-mix(in srgb, #c0392b 12%, transparent);
        }

        .opt-letter {
            flex-shrink: 0;
            display: inline-flex;
            align-items: center;
            justify-content: center;
            width: 1.6em;
            height: 1.6em;
            border-radius: 50%;
            background: color-mix(in srgb, var(--fg, #000) 10%, transparent);
            font-weight: 700;
            font-size: 0.85em;
        }

        .opt-text {
            flex: 1;
        }
    }

    .result {
        margin-top: 0.85em;
        padding-top: 0.75em;
        border-top: 1px solid var(--border, #8884);
        font-size: 0.92em;

        .result-label {
            display: block;
            margin-bottom: 0.3em;
        }

        &.is-correct .result-label {
            color: #2f8f57;
        }

        &.is-incorrect .result-label {
            color: #c0392b;
        }

        .explanation {
            margin: 0;
            color: var(--fg-subtle, #666);
            line-height: 1.5;
        }
    }

    .submit-btn {
        margin-top: 0.25em;
    }
</style>
