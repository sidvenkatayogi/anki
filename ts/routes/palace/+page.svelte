<!--
Copyright: Ankitects Pty Ltd and contributors
License: GNU AGPL, version 3 or later; http://www.gnu.org/licenses/agpl.html
-->
<script lang="ts">
    import { onMount, onDestroy } from "svelte";
    import {
        renderExistingCard,
        getSchedulingStates,
        answerCard,
    } from "@generated/backend";
    import { CardAnswer_Rating } from "@generated/anki/scheduler_pb";
    import type { SchedulingState } from "@generated/anki/scheduler_pb";
    import type { RenderedTemplateNode } from "@generated/anki/card_rendering_pb";

    // Plain hardcoded English strings are used throughout this page rather
    // than tr.*() Fluent calls - matching the documented deviation in
    // ts/routes/read/+page.svelte (see domains/frontend/plan.md's "i18n
    // decision"), to avoid a full `just` codegen build regenerating the
    // Fluent bindings.

    interface McatToolsConfig {
        url: string;
        token: string;
    }

    interface ApiErrorEnvelope {
        error?: { code?: string; message?: string };
    }

    // Types copied verbatim from contracts/data-model.md's "Desktop
    // TypeScript types" section.
    interface PalacePoint {
        x: number;
        y: number;
    }
    interface Locus {
        id: string;
        cardID: number;
        label: string;
        mnemonic: string;
        transform?: number[] | null;
        anchorID?: string | null;
        point: PalacePoint;
        learned: boolean;
    }
    interface Palace {
        id: string;
        name: string;
        createdAt: string;
        updatedAt: string;
        capacity: number;
        loci: Locus[];
        hasPhoto: boolean;
        hasWorldMap: boolean;
        photoVersion: number | null;
    }
    interface PalaceSummary {
        id: string;
        name: string;
        updatedAt: string;
        lociCount: number;
        hasPhoto: boolean;
        photoVersion: number | null;
    }

    type ViewState =
        | "checking-config"
        | "not-configured"
        | "loading"
        | "error"
        | "empty"
        | "success";

    let state: ViewState = "checking-config";
    let config: McatToolsConfig | null = null;
    let errorMessage = "";
    let palaces: PalaceSummary[] = [];

    // Inline config form - there's no separate settings dialog for this yet,
    // so this form is intentionally the only way to configure the sync
    // server URL/token right now. Copied from ts/routes/read/+page.svelte.
    let formUrl = "";
    let formToken = "";
    let savingConfig = false;
    let configSaveError = "";

    // Detail view state (selected palace + its photo object URL).
    let selectedPalace: Palace | null = null;
    let detailLoading = false;
    let detailError = "";
    let photoObjectUrl: string | null = null;

    // Cards that failed to render this session (deleted, etc.) - pins for
    // these are disabled rather than opening a broken study panel (AC12).
    let unavailableCardIds: Set<number> = new Set();

    // Study panel state, keyed to a single open locus at a time.
    interface StudyPanelState {
        locus: Locus;
        loading: boolean;
        error: string;
        questionHtml: string;
        answerHtml: string;
        css: string;
        revealed: boolean;
        revealedAtMillis: number | null;
        grading: boolean;
        gradeError: string;
        justGraded: boolean;
    }
    let studyPanel: StudyPanelState | null = null;

    onMount(() => {
        checkConfigAndLoad();
    });

    onDestroy(() => {
        revokePhotoUrl();
    });

    function revokePhotoUrl(): void {
        if (photoObjectUrl) {
            URL.revokeObjectURL(photoObjectUrl);
            photoObjectUrl = null;
        }
    }

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
            await loadPalaces();
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
            await loadPalaces();
        } catch {
            configSaveError = "Couldn't save configuration. Please try again.";
        } finally {
            savingConfig = false;
        }
    }

    async function extractErrorMessage(res: Response): Promise<string> {
        let message = `Couldn't reach the server (status ${res.status}).`;
        try {
            const body = (await res.json()) as ApiErrorEnvelope;
            if (body?.error?.message) {
                message = body.error.message;
            }
        } catch {
            // Non-JSON error body - keep the generic message.
        }
        return message;
    }

    async function loadPalaces(): Promise<void> {
        if (!config || !config.url || !config.token) {
            state = "not-configured";
            return;
        }
        state = "loading";
        selectedPalace = null;
        revokePhotoUrl();
        studyPanel = null;
        try {
            const base = config.url.replace(/\/+$/, "");
            const res = await fetch(`${base}/palaces`, {
                method: "GET",
                mode: "cors",
                headers: { "X-Mcat-Token": config.token },
            });
            if (!res.ok) {
                errorMessage = await extractErrorMessage(res);
                state = "error";
                return;
            }
            const data = (await res.json()) as { palaces: PalaceSummary[] };
            palaces = data.palaces ?? [];
            state = palaces.length === 0 ? "empty" : "success";
        } catch {
            errorMessage =
                "Couldn't reach the server. Check your connection and try again.";
            state = "error";
        }
    }

    async function openPalace(id: string): Promise<void> {
        if (!config || !config.url || !config.token) {
            state = "not-configured";
            return;
        }
        detailLoading = true;
        detailError = "";
        selectedPalace = null;
        revokePhotoUrl();
        studyPanel = null;
        unavailableCardIds = new Set();
        try {
            const base = config.url.replace(/\/+$/, "");
            const res = await fetch(`${base}/palaces/${id}`, {
                method: "GET",
                mode: "cors",
                headers: { "X-Mcat-Token": config.token },
            });
            if (!res.ok) {
                detailError = await extractErrorMessage(res);
                detailLoading = false;
                return;
            }
            const palace = (await res.json()) as Palace;
            selectedPalace = palace;

            if (palace.hasPhoto) {
                try {
                    const photoRes = await fetch(`${base}/palaces/${id}/photo`, {
                        method: "GET",
                        mode: "cors",
                        headers: { "X-Mcat-Token": config.token },
                    });
                    if (photoRes.ok) {
                        const blob = await photoRes.blob();
                        photoObjectUrl = URL.createObjectURL(blob);
                    }
                } catch {
                    // Photo fetch failed - fall back to the no-photo placeholder
                    // rather than blocking the whole detail view.
                }
            }
        } catch {
            detailError =
                "Couldn't reach the server. Check your connection and try again.";
        } finally {
            detailLoading = false;
        }
    }

    function closePalace(): void {
        selectedPalace = null;
        revokePhotoUrl();
        studyPanel = null;
        detailError = "";
    }

    // Svelte's own scoped style blocks can't be dynamic, and the backend's
    // card CSS blob has to be injected at runtime instead. We build the tag
    // through string concatenation (avoiding a literal opening/closing style
    // tag substring in this file's source) because svelte-preprocess scans
    // the raw file text for style-tag markers and will otherwise try to
    // parse this string as a real, static stylesheet, breaking
    // svelte-check/build.
    function cardStyleTag(css: string): string {
        const open = "<" + "style" + ">";
        const close = "<" + "/style" + ">";
        return open + css + close;
    }

    function nodesToHtml(nodes: RenderedTemplateNode[]): string {
        return nodes
            .map((node) => {
                const v = node.value;
                if (v.case === "text") {
                    return v.value;
                }
                if (v.case === "replacement") {
                    return v.value.currentText;
                }
                return "";
            })
            .join("");
    }

    async function openLocus(locus: Locus): Promise<void> {
        if (unavailableCardIds.has(locus.cardID)) {
            return;
        }
        studyPanel = {
            locus,
            loading: true,
            error: "",
            questionHtml: "",
            answerHtml: "",
            css: "",
            revealed: false,
            revealedAtMillis: null,
            grading: false,
            gradeError: "",
            justGraded: false,
        };
        try {
            const response = await renderExistingCard({
                cardId: BigInt(locus.cardID),
                browser: false,
                partialRender: false,
            });
            const questionHtml = nodesToHtml(response.questionNodes);
            const answerHtml = nodesToHtml(response.answerNodes);
            if (studyPanel && studyPanel.locus.id === locus.id) {
                studyPanel = {
                    ...studyPanel,
                    loading: false,
                    questionHtml,
                    answerHtml,
                    css: response.css,
                };
            }
        } catch {
            // Card no longer exists (deleted, etc.) - disable this pin for the
            // rest of the session instead of showing a broken study panel.
            unavailableCardIds = new Set(unavailableCardIds).add(locus.cardID);
            studyPanel = null;
        }
    }

    function closeStudyPanel(): void {
        studyPanel = null;
    }

    function revealAnswer(): void {
        if (!studyPanel) {
            return;
        }
        studyPanel = {
            ...studyPanel,
            revealed: true,
            revealedAtMillis: Date.now(),
        };
    }

    function ratingToState(
        states: {
            again?: SchedulingState;
            hard?: SchedulingState;
            good?: SchedulingState;
            easy?: SchedulingState;
        },
        rating: CardAnswer_Rating,
    ): SchedulingState | undefined {
        switch (rating) {
            case CardAnswer_Rating.AGAIN:
                return states.again;
            case CardAnswer_Rating.HARD:
                return states.hard;
            case CardAnswer_Rating.GOOD:
                return states.good;
            case CardAnswer_Rating.EASY:
                return states.easy;
            default:
                return undefined;
        }
    }

    async function grade(rating: CardAnswer_Rating): Promise<void> {
        if (!studyPanel || studyPanel.grading) {
            return;
        }
        const panel = studyPanel;
        const cardID = panel.locus.cardID;
        studyPanel = { ...panel, grading: true, gradeError: "" };
        try {
            const states = await getSchedulingStates({ cid: BigInt(cardID) });
            const newState = ratingToState(states, rating);
            if (!states.current || !newState) {
                throw new Error("missing scheduling state");
            }
            const elapsed = panel.revealedAtMillis
                ? Date.now() - panel.revealedAtMillis
                : 0;
            const millisecondsTaken = Math.max(
                0,
                Math.min(Math.round(elapsed), 0xffffffff),
            );
            await answerCard({
                cardId: BigInt(cardID),
                currentState: states.current,
                newState,
                rating,
                answeredAtMillis: BigInt(Date.now()),
                millisecondsTaken,
                skipQueue: true,
            });
            // Success - close the panel and return to the pin overlay.
            studyPanel = null;
        } catch {
            studyPanel = {
                ...panel,
                grading: false,
                gradeError: "Couldn't save that grade. Please try again.",
            };
        }
    }

    function formatUpdatedAt(iso: string): string {
        try {
            return new Date(iso).toLocaleString();
        } catch {
            return iso;
        }
    }
</script>

<div class="palace-page">
    {#if state === "checking-config"}
        <div class="status-block">
            <div class="spinner" aria-hidden="true"></div>
            <p>Checking configuration…</p>
        </div>
    {:else if state === "not-configured"}
        <div class="empty-state">
            <h1>Palace</h1>
            <p class="explain">
                The Palace tab shows memory palaces synced from your other
                devices. To use it, set your sync server URL and MCAT tools
                token below.
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
            <p>Loading palaces…</p>
        </div>
    {:else if state === "error"}
        <div class="error-banner" role="alert">
            <span class="icon" aria-hidden="true">⚠</span>
            <div class="error-text">
                <strong>Couldn't load palaces</strong>
                <p>{errorMessage}</p>
            </div>
            <button class="btn-accent" on:click={loadPalaces}>Retry</button>
        </div>
    {:else if state === "empty"}
        <div class="empty-state">
            <h1>Palace</h1>
            <p class="explain">
                No memory palaces have been synced yet. Build one in the iOS
                app and it will show up here.
            </p>
            <button class="btn-accent" on:click={loadPalaces}>Refresh</button>
        </div>
    {:else if state === "success"}
        {#if !selectedPalace}
            <div class="toolbar">
                <h1>Palace</h1>
                <button class="btn-accent" on:click={loadPalaces}>Refresh</button>
            </div>
            <ul class="palace-list">
                {#each palaces as p (p.id)}
                    <li>
                        <button
                            type="button"
                            class="palace-item"
                            on:click={() => openPalace(p.id)}
                        >
                            <span class="palace-name">{p.name}</span>
                            <span class="palace-meta">
                                {p.lociCount}
                                {p.lociCount === 1 ? "locus" : "loci"} · updated {formatUpdatedAt(
                                    p.updatedAt,
                                )}
                            </span>
                        </button>
                    </li>
                {/each}
            </ul>
        {:else}
            <div class="toolbar">
                <button class="btn-accent" on:click={closePalace}>
                    ← Back to palaces
                </button>
            </div>

            {#if detailLoading}
                <div class="status-block">
                    <div class="spinner" aria-hidden="true"></div>
                    <p>Loading palace…</p>
                </div>
            {:else if detailError}
                <div class="error-banner" role="alert">
                    <span class="icon" aria-hidden="true">⚠</span>
                    <div class="error-text">
                        <strong>Couldn't load this palace</strong>
                        <p>{detailError}</p>
                    </div>
                </div>
            {:else}
                <h2 class="palace-title">{selectedPalace.name}</h2>

                {#if photoObjectUrl}
                    <div class="photo-container">
                        <img src={photoObjectUrl} alt={selectedPalace.name} />
                        {#each selectedPalace.loci as locus, i (locus.id)}
                            <button
                                type="button"
                                class="pin"
                                class:pin-disabled={unavailableCardIds.has(
                                    locus.cardID,
                                )}
                                style={`left: ${locus.point.x * 100}%; top: ${
                                    locus.point.y * 100
                                }%`}
                                disabled={unavailableCardIds.has(locus.cardID)}
                                title={unavailableCardIds.has(locus.cardID)
                                    ? "Card unavailable"
                                    : locus.label}
                                on:click={() => openLocus(locus)}
                            >
                                {i + 1}
                            </button>
                        {/each}
                    </div>
                {:else}
                    <div class="no-photo-placeholder">
                        <p>No reference photo for this palace.</p>
                    </div>
                    <ul class="locus-list">
                        {#each selectedPalace.loci as locus, i (locus.id)}
                            <li>
                                <button
                                    type="button"
                                    class="locus-item"
                                    class:pin-disabled={unavailableCardIds.has(
                                        locus.cardID,
                                    )}
                                    disabled={unavailableCardIds.has(
                                        locus.cardID,
                                    )}
                                    title={unavailableCardIds.has(
                                        locus.cardID,
                                    )
                                        ? "Card unavailable"
                                        : undefined}
                                    on:click={() => openLocus(locus)}
                                >
                                    <span class="locus-number">{i + 1}</span>
                                    <span class="locus-label">{locus.label}</span>
                                </button>
                            </li>
                        {/each}
                    </ul>
                {/if}

                {#if studyPanel}
                    <div class="study-panel">
                        <div class="study-panel-header">
                            <strong>{studyPanel.locus.mnemonic || "Study"}</strong>
                            <button
                                type="button"
                                class="close-btn"
                                on:click={closeStudyPanel}
                                aria-label="Close study panel"
                            >
                                ✕
                            </button>
                        </div>

                        {#if studyPanel.loading}
                            <div class="status-block">
                                <div class="spinner" aria-hidden="true"></div>
                                <p>Loading card…</p>
                            </div>
                        {:else if studyPanel.error}
                            <div class="inline-error">{studyPanel.error}</div>
                        {:else}
                            <div class="card-render">
                                {@html cardStyleTag(studyPanel.css)}
                                {@html studyPanel.revealed
                                    ? studyPanel.answerHtml
                                    : studyPanel.questionHtml}
                            </div>

                            {#if !studyPanel.revealed}
                                <button
                                    type="button"
                                    class="btn-accent"
                                    on:click={revealAnswer}
                                >
                                    Reveal answer
                                </button>
                            {:else}
                                {#if studyPanel.gradeError}
                                    <div class="inline-error">
                                        {studyPanel.gradeError}
                                    </div>
                                {/if}
                                <div class="grade-row">
                                    <button
                                        type="button"
                                        class="grade-btn grade-again"
                                        disabled={studyPanel.grading}
                                        on:click={() =>
                                            grade(CardAnswer_Rating.AGAIN)}
                                    >
                                        Again
                                    </button>
                                    <button
                                        type="button"
                                        class="grade-btn grade-hard"
                                        disabled={studyPanel.grading}
                                        on:click={() =>
                                            grade(CardAnswer_Rating.HARD)}
                                    >
                                        Hard
                                    </button>
                                    <button
                                        type="button"
                                        class="grade-btn grade-good"
                                        disabled={studyPanel.grading}
                                        on:click={() =>
                                            grade(CardAnswer_Rating.GOOD)}
                                    >
                                        Good
                                    </button>
                                    <button
                                        type="button"
                                        class="grade-btn grade-easy"
                                        disabled={studyPanel.grading}
                                        on:click={() =>
                                            grade(CardAnswer_Rating.EASY)}
                                    >
                                        Easy
                                    </button>
                                </div>
                            {/if}
                        {/if}
                    </div>
                {/if}
            {/if}
        {/if}
    {/if}
</div>

<style lang="scss">
    // Shared design tokens (accent colour, spacing scale) with Read/Practice,
    // so all three tabs stay visually cohesive.
    @use "../../../sass/mcat-tools" as mcat;
    $accent: mcat.$mcat-accent;
    $accent-fg: mcat.$mcat-accent-fg;

    .palace-page {
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
        justify-content: space-between;
        align-items: center;
        margin-bottom: 1em;

        h1 {
            margin: 0;
        }
    }

    .palace-list {
        list-style: none;
        margin: 0;
        padding: 0;
        display: flex;
        flex-direction: column;
        gap: 0.6em;
    }

    .palace-item {
        width: 100%;
        text-align: start;
        display: flex;
        flex-direction: column;
        gap: 0.25em;
        padding: 0.9em 1.1em;
        border-radius: 10px;
        border: 1px solid var(--border, #8884);
        background: var(--canvas-elevated, transparent);
        color: var(--fg, inherit);
        font: inherit;
        cursor: pointer;
        transition: background 120ms ease-out;

        &:hover {
            background: color-mix(in srgb, var(--fg, #000) 5%, transparent);
        }

        &:focus-visible {
            outline: 2px solid $accent;
            outline-offset: 1px;
        }

        .palace-name {
            font-weight: 600;
        }

        .palace-meta {
            font-size: 0.85em;
            color: var(--fg-subtle, #666);
        }
    }

    .palace-title {
        margin: 0 0 0.75em;
    }

    .photo-container {
        position: relative;
        display: inline-block;
        max-width: 100%;
        margin-bottom: 1.25em;

        img {
            display: block;
            max-width: 100%;
            border-radius: 10px;
            border: 1px solid var(--border, #8884);
        }
    }

    .pin {
        position: absolute;
        transform: translate(-50%, -50%);
        width: 1.8em;
        height: 1.8em;
        border-radius: 50%;
        border: 2px solid $accent-fg;
        background: $accent;
        color: $accent-fg;
        font-weight: 700;
        font-size: 0.85em;
        display: flex;
        align-items: center;
        justify-content: center;
        cursor: pointer;
        box-shadow: 0 1px 4px color-mix(in srgb, #000 40%, transparent);

        &:hover:not(:disabled) {
            background: color-mix(in srgb, $accent 85%, black);
        }

        &:focus-visible {
            outline: 2px solid $accent-fg;
            outline-offset: 2px;
        }

        &.pin-disabled {
            opacity: 0.45;
            cursor: not-allowed;
            background: var(--fg-subtle, #888);
        }
    }

    .no-photo-placeholder {
        padding: 2.5em 1em;
        margin-bottom: 1.25em;
        text-align: center;
        border-radius: 10px;
        border: 1px dashed var(--border, #8884);
        background: color-mix(in srgb, var(--fg, #000) 4%, transparent);
        color: var(--fg-subtle, #666);
    }

    .locus-list {
        list-style: none;
        margin: 0 0 1.25em;
        padding: 0;
        display: flex;
        flex-direction: column;
        gap: 0.5em;
    }

    .locus-item {
        width: 100%;
        display: flex;
        align-items: center;
        gap: 0.75em;
        text-align: start;
        padding: 0.6em 0.9em;
        border-radius: 8px;
        border: 1px solid var(--border, #8884);
        background: var(--canvas-elevated, transparent);
        color: var(--fg, inherit);
        font: inherit;
        cursor: pointer;

        &:hover:not(:disabled) {
            background: color-mix(in srgb, var(--fg, #000) 5%, transparent);
        }

        &.pin-disabled {
            opacity: 0.5;
            cursor: not-allowed;
        }

        .locus-number {
            flex-shrink: 0;
            display: inline-flex;
            align-items: center;
            justify-content: center;
            width: 1.6em;
            height: 1.6em;
            border-radius: 50%;
            background: $accent;
            color: $accent-fg;
            font-weight: 700;
            font-size: 0.85em;
        }

        .locus-label {
            flex: 1;
        }
    }

    .study-panel {
        margin-top: 1em;
        padding: 1em 1.2em;
        border-radius: 10px;
        border: 1px solid var(--border, #8884);
        background: var(--canvas-elevated, transparent);
    }

    .study-panel-header {
        display: flex;
        justify-content: space-between;
        align-items: center;
        margin-bottom: 0.75em;

        .close-btn {
            border: none;
            background: transparent;
            color: var(--fg-subtle, #666);
            cursor: pointer;
            font-size: 1.1em;
            line-height: 1;

            &:hover {
                color: var(--fg, #000);
            }
        }
    }

    .card-render {
        min-height: 4em;
        margin-bottom: 1em;
    }

    .grade-row {
        display: flex;
        gap: 0.5em;
        flex-wrap: wrap;
    }

    .grade-btn {
        flex: 1;
        min-width: 5em;
        padding: 0.55em 0.8em;
        border: none;
        border-radius: 8px;
        font-weight: 600;
        cursor: pointer;
        color: #fff;

        &:disabled {
            opacity: 0.6;
            cursor: not-allowed;
        }
    }

    .grade-again {
        background: #c0392b;
    }

    .grade-hard {
        background: #c9971f;
    }

    .grade-good {
        background: #2f8f57;
    }

    .grade-easy {
        background: #2a7ac9;
    }
</style>
